# ZoneRouter and private card spend (proposal)

**Status: proposed, not implemented.** This page is the target for the ZoneRouter work. Until that
lands, [design.md](design.md) and [Earn's zone router](../earn/modules/zone-router.md) describe
what is deployed. When the code merges, each part of this page moves to the page that owns it and
this page is deleted.

## Why

Private card spend runs through [`ZoneSpendReceiver`](../../spend/src/ZoneSpendReceiver.sol), a
second Zone callback contract next to Earn's
[`SingleZoneEarnRouter`](../../earn/src/router/SingleZoneEarnRouter.sol). That costs us:

- **Duplicated Zone code.** Messenger and Portal authentication, encrypted change returns and the
  deposit fee cap exist twice, and a program's Zone users need two gateways for Earn and card.
- **A privacy exception.** The receiver emits the callback `senderTag`, which Earn's
  [privacy model](../earn/architecture/security-and-privacy.md#privacy-model) forbids elsewhere.
- **An unbounded pull (Cyclops, Low).** The receiver approves the whole withdrawal to the clone. A
  replaced handler can pay the destination exactly and keep the change, and every check still
  passes.

## Requirements

From [Stripe Issuing Smart Contracts on Tempo](https://docs.google.com/document/d/1g9Z-Gr2PzOnm12jgbDm6z4XsqlNiyLlWdvzok0CT00M/edit):

| Requirement                                                                  | How this design meets it                                                                                                                      |
| ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Extend Bridge's contract; change it only at the handler level                | Every debit is still `publicCall "PS"` on the program's clone. Only `TS` changes; the router and settler are Tempo contracts outside Bridge's |
| Customer funds are never co-mingled                                          | Router and settler hold a withdrawal only inside its callback and end every transaction with no balance or approval                           |
| One program's approval can never be used by another                          | Each `BridgeSettler` is bound to one spender ID, and each router to one settler                                                               |
| Funds only reach a secure Stripe wallet                                      | `TS` checks the program's allowlist and the settler checks the destination was paid; unused input only returns to the Zone                    |
| Program setup: vault allowlist, 1:1 conversion route, a receiver per Zone    | Governance's `"UV"` allows funding sources, including Earn with par conversion; one router and settler per program and Zone                   |
| Access keys only; exact approval, cleared after each debit                   | Unchanged for public spend. In the Zone, the router approves at most `maxInput` to the settler and resets it                                  |
| Debit from stablecoin, Earn shares, or both, converting 1:1                  | Public: `TS` splits a spend between `token` and a source. Private: one balance, or both as two withdrawals (decision 15, see below)           |
| Approve once the Zone accepts the withdrawal; change returns encrypted       | Unchanged: Bridge approves on the Zone receipt; `Pay` returns change by encrypted deposit with a fee cap                                      |
| A spend blocked after approval must not land back in the cardholder's wallet | Bridge sets the withdrawal's `zoneFallbackRecipient` to the program's Stripe-owned Zone account                                               |
| Refunds through Bridge's orchestration                                       | `refund()` is the on-chain leg, callable only by a program destination                                                                        |
| 2 s authorization budget, 3M callback gas, 1,024-byte callback data          | No new wait before approval; one more token hop in the callback; `Pay` data is 832 bytes                                                      |

## Two layers

| Layer          | Lives in | Contracts                                                              | Lifetime                 |
| -------------- | -------- | ---------------------------------------------------------------------- | ------------------------ |
| Tempo-owned    | `earn/`  | `ZoneRouter`, `ISpendSettler`, Earn funding source with par conversion | Permanent                |
| Bridge adapter | `spend/` | `TS` handler (funding through sources), `BridgeSettler`                | Until Tempo-native spend |

Earn depends only on `ISpendSettler` and stays integrator-agnostic. Everything that knows Bridge's
factory stays in `spend/`.

## `ZoneRouter`

`SingleZoneEarnRouter`, renamed, with one more immutable and one more op. It keeps everything the
router has today:

- one Zone, one EarnVault, one private asset, and an optional par pool;
- authentication through the Zone Messenger, the Zone ID and the Factory-registered Portal;
- no owner, measured balances around every step, and no balances or approvals left behind.

The new immutable is `settler`, an `ISpendSettler` fixed at deployment. Zero turns `Pay` and
`refund` off, which gives today's router exactly. A router with a settler belongs to that settler's
program: a program has one router per Zone and private asset, as many gateways as it has receivers
today.

### Ops

The router already reads the first callback word before decoding, so ops 0 and 1 keep their exact
layout and `viem/tempo`'s `earnRouterCallbackData` keeps working.

| Op                  | Input                                       | What the router does                                                              | Back to the Zone        |
| ------------------- | ------------------------------------------- | --------------------------------------------------------------------------------- | ----------------------- |
| 0 Deposit           | Private asset                               | Unchanged                                                                         | EarnShare               |
| 1 Redeem            | EarnShare                                   | Unchanged                                                                         | Private asset           |
| 2 Pay               | Private asset or EarnShare                  | Approves at most `maxInput` to the settler, calls `settle`, measures what it used | Unused input, encrypted |
| `refund()` (public) | Stablecoin from a payer the settler accepts | Deposits it into the Zone for the encrypted recipient                             | The refund              |

`Pay` callback data, 832 bytes with a 64-byte ciphertext (today's receiver data is 672):

```text
PayData {
    uint8 op               // 2
    uint128 maxInput       // the most input the settler may use
    bytes settlerData      // opaque to the router; Bridge's Spend
    PayReturn zoneReturn   // keyIndex, encrypted, refundRecipient, maxDepositFee
}
```

A `Pay` callback:

1. authenticates exactly as ops 0 and 1, and requires the input to be the private asset or the
   EarnShare;
2. approves `maxInput` (never more than the withdrawn amount) to the settler and calls
   `settle(token, maxInput, settlerData)`, then resets the approval;
3. requires `0 < used <= maxInput`, measured from its own balance;
4. returns `amount - used` to the source Portal as an encrypted deposit, reverting if the Portal's
   deposit fee is above `maxDepositFee`;
5. emits `Paid(settler, token, used, change, zoneDepositHash)`, with no `senderTag`, no action ID and
   no cardholder address.

Any revert bounces the whole input to the withdrawal's `zoneFallbackRecipient` in the Zone.

`maxInput` is what closes the Cyclops finding. It is set in the cardholder's Zone transaction, not
by the settler or the handler, so a replaced handler can take at most the spend itself. Bridge sets
it to the spend amount for a stablecoin spend and to `maxShares` for an Earn spend, and withdraws
the change on top.

### `ISpendSettler`

```text
interface ISpendSettler {
    // Pays from the router's approved token, using at most maxInput. Reverts unless the
    // payment it makes is complete. Returns all unused input to the router.
    function settle(address token, uint256 maxInput, bytes calldata data) external;

    // Reverts unless payer may credit a refund into the Zone.
    function checkRefunder(address payer, address token) external view;
}
```

### `refund()`

`refund(token, amount, zoneReturn)` pulls `amount` from the caller and deposits it into the Zone,
after `settler.checkRefunder(msg.sender, token)`. It is the router's only public entry point that
deposits, and only payers the settler accepts can use it, so it cannot bypass a closed-loop Zone's
admission.

## Bridge adapter (`spend/`)

### `BridgeSettler`

`ZoneSpendReceiver` without its Zone code: ownerless, bound to Bridge's factory and one spender ID,
one per program and Zone router. `settle`:

- decodes the `Spend`, requires its `spenderId` to be the bound one and `token` to be its input, and
  pulls `maxInput` from the router;
- approves it to the program's clone and calls `publicCall "PS"`, then resets the approval;
- requires the destination received exactly `spend.amount` and that the handler used something;
- sends the unused input back to the router.

`checkRefunder` makes `refundPrivate`'s checks today: the factory is not paused and the payer is an
authorized destination of the program.

Neither the router nor the settler emits `senderTag`. The Portal's own `WithdrawalProcessed` event,
in the same transaction as `Paid`, carries `senderTag`, `to`, `token`, `amount` and
`callbackSuccess`, which is all Bridge needs to match a spend. So the `senderTag` exception in
[spend/AGENTS.md](../../spend/AGENTS.md) goes away.

### `TS` funding sources

`TS` keeps its `Spend` ABI. Two fields widen in meaning, not type:

- `vault` becomes `source`: any funding source governance allows through the existing `"UV"` call;
- `maxShares` becomes `maxInput`.

`amount - fromVault` is still paid in `token`. For `fromVault`, `TS` pulls at most `maxInput` from the
payer, calls `source.fund(destination, fromVault)`, returns unused input, and checks the destination
was credited exactly. Sources share the shape of [TIP-1120](https://tips.sh/1120)'s
`IFundingSource`, so the same contracts serve TIP-1120's funder later. The Earn source calls
`withdrawExact`, today's logic moved out of the handler, and optionally converts the vault asset at
par through a DirectPropAMM pool, the same route and checks the router uses. So an OUSD vault can
back a DLUSD card, as the program setup requires.

## Card flows

Bridge pulls at authorization, so every card event is a spend, a refund or a reserve draw off chain.

| Event                                                                                | On chain                                                    |
| ------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| Purchase, ATM, fees, force capture, a tip beyond the hold, incremental authorization | Spend: public `TS` call, or `Pay` from the Zone             |
| Reversal, hold expiry, partial-capture remainder, merchant refund, dispute won       | Refund: public transfer, or `refund()` into the Zone        |
| Over-capture without funds, a callback that fails after approval                     | Reserve, off chain; the input goes to Stripe's Zone account |

A closed-loop Zone still needs change on every callback, so Bridge withdraws the input plus change of
at least `depositFee + bouncebackFee + 1`, and `maxInput` leaves that change outside the settler's
reach.

## Decisions this changes

- **Decision 5** (no conversion) gives way to par conversion through the Earn source, which the
  requirements' program setup asks for.
- **Decision 3** stays: `Pay` carries no action ID.
- **Decision 6** stays: one router and settler per program and Zone.
- **Decision 15** changes: a private spend uses Earn shares if they cover it, otherwise stablecoin,
  otherwise both, otherwise Bridge declines. One withdrawal carries one token, so "both" is two
  withdrawals in the cardholder's same Zone transaction, each a `Pay` with its own `Spend` for its
  part of the amount. The contracts need no change for this. The two callbacks are independent: if
  one bounces after approval, the reserve covers its part, as for any failed callback. A split pays
  two withdrawal fees and two change returns, uses about 3M callback gas in total, and gives Bridge
  two `senderTag`s to match to one authorization.
- **Earn's router rules** in [earn/src/AGENTS.md](../../earn/src/AGENTS.md) and router invariant 2 in
  [zone-router.md](../earn/modules/zone-router.md#router-contract): "every successful callback returns
  its complete output through that Portal" and "no caller-selected destinations" become "or pays
  through the deploy-bound settler, using at most the callback's `maxInput`".

## Phases

| Phase         | Public spend                                                            | Private spend                                     | Bridge changes                               |
| ------------- | ----------------------------------------------------------------------- | ------------------------------------------------- | -------------------------------------------- |
| Today         | `TS` with Earn built in                                                 | `ZoneSpendReceiver` → `TS`                        | —                                            |
| Bridge phase  | `TS` → funding sources                                                  | `ZoneRouter` `Pay` → `BridgeSettler` → `TS`       | Router address, `Pay` wrapper, event parsing |
| TIP-1120 live | `requireFunds` with the same sources, then a stablecoin-only `TS` spend | Unchanged                                         | The key gets a single dollar limit           |
| Tempo-native  | A key-scoped transfer to the settlement wallet                          | `ZoneRouter` `Pay` → a direct settler in `spend/` | Retire `TS` and `BridgeSettler`              |

The router, its callback format, the funding sources, Bridge's settlement wallet as payee and the
cardholder's access keys stay the same through every phase.

## Rollout

1. **Earn:** `ZoneRouter` with ops 0 and 1 byte-identical and their tests carried over. The rename
   lands with its consumers: tempoxyz/tempo (which builds `earn/src/` and reads the router outputs),
   `viem/tempo`, and the zone-router deployment module.
2. **Spend:** `BridgeSettler`, a "ZoneRouter" setup in the 35-scenario matrix, and `e2e/zone` on the
   new path, with callback gas measured against today's 2.02M (Earn) and 0.98M (DLUSD) and Bridge's
   3M limit.
3. **Spend:** `TS` funding through sources, including par conversion.
4. **Cutover:** each Zone admits the program's router as its gateway and Bridge switches its callback
   data, `to` address, fallback recipient and event parsing. Old receivers stay deployed so in-flight
   spends finish or bounce.

## Open questions

- **Input tokens.** `Pay` accepts the router's private asset and EarnShare, and a router needs an
  EarnVault even for a stablecoin-only program. A program with several card stablecoins on one Zone
  needs a router for each.
- **More ops.** Sends and asset-denominated Earn withdrawals fit the same op table but are not needed
  for card spend.
