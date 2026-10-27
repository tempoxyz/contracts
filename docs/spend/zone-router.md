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
| One program's approval can never be used by another                          | Each `BridgeSettler` is bound to one spender ID; a router pays only through settlers fixed at deployment                                      |
| Funds only reach a secure Stripe wallet                                      | `TS` checks the program's allowlist and the settler checks the destination was paid; unused input only returns to the Zone                    |
| Program setup: vault allowlist, 1:1 conversion route, a receiver per Zone    | Governance's `"UV"` allows funding sources, including Earn with par conversion; one settler per program, listed on its Zone's router          |
| Access keys only; exact approval, cleared after each debit                   | Unchanged for public spend. In the Zone, the router approves at most `maxInput` to the settler and resets it                                  |
| Debit from stablecoin, Earn shares, or both, converting 1:1                  | Public: `TS` splits a spend between `token` and a source. Private: one balance, or both as two withdrawals (decision 15, see below)           |
| Approve once the Zone accepts the withdrawal; change returns encrypted       | Unchanged: Bridge approves on the Zone receipt; `Spend` returns change by encrypted deposit with a fee cap                                    |
| A spend blocked after approval must not land back in the cardholder's wallet | Bridge sets the withdrawal's `zoneFallbackRecipient` to the program's Stripe-owned Zone account                                               |
| Refunds through Bridge's orchestration                                       | `refund()` is the on-chain leg, callable only by a program destination                                                                        |
| 2 s authorization budget, 3M callback gas, 1,024-byte callback data          | No new wait before approval; one more token hop in the callback; the largest callback (`WithdrawExact`) is 960 bytes                          |

## Two layers

| Layer          | Lives in | Contracts                                                              | Lifetime                 |
| -------------- | -------- | ---------------------------------------------------------------------- | ------------------------ |
| Tempo-owned    | `earn/`  | `ZoneRouter`, `ISpendSettler`, Earn funding source with par conversion | Permanent                |
| Bridge adapter | `spend/` | `TS` handler (funding through sources), `BridgeSettler`                | Until Tempo-native spend |

Earn depends only on `ISpendSettler` and stays integrator-agnostic. Everything that knows Bridge's
factory stays in `spend/`.

## `ZoneRouter`

`SingleZoneEarnRouter`, renamed, with deployment modes, settlers, an optional EarnVault and three more ops. It keeps
everything the router has today:

- one Zone, an optional EarnVault and private asset, and an optional par pool;
- authentication through the Zone Messenger, the Zone ID and the Factory-registered Portal;
- no owner, measured balances around every step, and no balances or approvals left behind.

Its configuration is fixed at deployment, with no setters; a different mode means a new router:

- **`enabledOps`**, a bitmask of Deposit, Redeem, Spend and WithdrawExact. A disabled op reverts
  `OpDisabled`.
- **`settlers`**, the set of `ISpendSettler` contracts `Spend` and `refund` may use, including the send settlers, written once by the
  constructor into an `isSettler` mapping. Required for any spend other than a same-Zone send.
- **`earnVault`, `privateAsset`, `pool`, `customerId`**, as today. Required when an Earn op (Deposit,
  Redeem or WithdrawExact) is enabled, and all zero otherwise.

The constructor rejects inconsistent combinations, so a router cannot be deployed with an op it
cannot serve. Deployment profiles name presets:

| Mode                       | Ops                                   | Settlers                     | Vault |
| -------------------------- | ------------------------------------- | ---------------------------- | ----- |
| Earn (today's router)      | Deposit, Redeem                       | —                            | Yes   |
| Card, closed loop          | Spend                                 | `BridgeSettler`              | —     |
| Card and Earn, closed loop | Deposit, Redeem, Spend, WithdrawExact | `BridgeSettler`              | Yes   |
| Open wallet                | All                                   | Any, including send settlers | Any   |

The Earn preset is exactly today's router, so its tests carry over unchanged as the regression suite.
One router per Zone can serve several programs or integrators by listing each one's settler.

### `ZoneRouterFactory`

Routers are deployed through a factory, so a new customer or mode is one call, not a deployment
project:

- **Ownerless and permissionless.** `deploy(mode)` creates the router with CREATE2, salted by the mode's
  hash. The same mode always gives the same address, and deploying it again returns the existing
  router. `predict(mode)` gives the address in advance, so a profile, Bridge and the Zone admin agree on
  it before anything is deployed.
- **Provenance.** `isRouter(address)` and `RouterDeployed(router, modeHash, mode)` let a Zone admin check
  that a gateway came from this factory, with the mode they expect, before admitting it.
- **One factory per router version.** A new router version ships as a new factory. Routers already
  deployed keep working, and each customer moves to the new version when ready, by deploying its mode
  there and having its Zone admit the new address. The factory is a shared release, so it is reviewed
  and its address recorded like Earn's other factory releases.
- **Size.** If the router's creation code is too large to embed in the factory, the factory deploys
  minimal clones that read the mode as immutable arguments instead. Measure the router before choosing.

The mode struct is deliberately the shape of a route in a single shared router.

### Toward one shared router

Once the modes settle, one ownerless router can replace the per-mode routers:

- Each mode becomes a **route**, registered permissionlessly, identified by its hash, and immutable.
  Every callback names its `routeId`.
- A Zone admits the one router once, so a Zone's Portal admin approves the routes its Zone accepts
  (`approveRoute(zoneId, routeId)`). Without that, admitting the shared router would let anyone's route,
  such as one with public sends, move funds out of a closed-loop Zone.
- Authentication, measured balances and par conversion are unchanged; the reentrancy lock covers the
  whole contract, and route settings are read from storage instead of immutables.
- `routeId` adds 32 bytes per callback: `Spend` becomes 896 bytes and `WithdrawExact` 992, still under
  1,024.
- The cost is concentration: a bug reaches every Zone, and an ownerless contract is fixed by
  deploying a new one and moving every Zone. So the move waits until a few customers have run on
  factory-deployed routers.

Settlers, `ISpendSettler`, the callback fields other than `routeId`, and events stay the same, so
moving only changes the address Bridge and clients target.

### Ops

The router already reads the first callback word before decoding, so ops 0 and 1 keep their exact
layout and `viem/tempo`'s `earnRouterCallbackData` keeps working.

| Op                  | Input                                       | What the router does                                                                    | Back to the Zone                 |
| ------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------- |
| 0 Deposit           | Private asset                               | Unchanged                                                                               | EarnShare                        |
| 1 Redeem            | EarnShare                                   | Unchanged                                                                               | Private asset                    |
| 2 Spend             | Any token the source Portal enables         | Approves at most `maxInput` to the named settler, calls `settle`, measures what it used | Unused input                     |
| 3 WithdrawExact     | EarnShare                                   | Withdraws exactly `assets` from the vault, burning at most the input, converting at par | The assets and the unused shares |
| `refund()` (public) | Stablecoin from a payer the settler accepts | Deposits it into the Zone for the encrypted recipient                                   | The refund                       |

Every return to a Zone is an encrypted deposit with its own `ZoneReturn` (key index, encrypted
recipient, refund recipient and `maxDepositFee`), and reverts if that Portal's deposit fee is above
the cap. Every op requires the return token to be enabled with deposits active on the Portal it goes
to. Any revert bounces the whole input to the withdrawal's `zoneFallbackRecipient` in the source
Zone.

Callback data sizes, with a 64-byte ciphertext, against the outbox's 1,024 bytes:

| Op            | Bytes | Fields                                                                                |
| ------------- | ----- | ------------------------------------------------------------------------------------- |
| Spend         | 864   | `op`, `settler`, `maxInput`, `settlerData` (Bridge's `Spend` struct), `ZoneReturn`    |
| WithdrawExact | 960   | `op`, `assets`, `minOutput`, `ZoneReturn` for the assets, `ZoneReturn` for the shares |

### `Spend`

One op covers card spend and sends: the router hands at most `maxInput` to a settler from its set,
and everything unused returns to the source Zone.

1. Authenticates exactly as ops 0 and 1, and requires the named settler to be in `settlers`.
2. Approves `maxInput` (never more than the withdrawn amount) to the settler and calls
   `settle(token, maxInput, settlerData)`, then resets the approval.
3. Requires `0 < used <= maxInput`, measured from its own balance.
4. Returns `amount - used` to the source Zone.
5. Emits `Spent(settler, token, used, change, zoneDepositHash)`, with no `senderTag`, no action ID and
   no cardholder address. The settler emits its own detail.

With `maxInput = 0` and no settler, the whole input returns to the source Zone for the recipient its
`ZoneReturn` encrypts: a send inside the same Zone. Zone transfers are disabled while Zones are
permissioned (decision 8), so this is how one Zone account pays another.

The router accepts any enabled token and leaves it to the settler to refuse one it cannot use.
`BridgeSettler` requires the token to be its `Spend` struct's input, and `TS` checks it against the
spend.

`maxInput` is what closes the Cyclops finding. It is set in the cardholder's Zone transaction, not
by the settler or the handler, so a replaced handler can take at most the spend itself. Bridge sets
it to the spend amount for a stablecoin spend and to `maxShares` for an Earn spend, and withdraws
the change on top.

#### Send settlers

Tempo owns two small settlers for sends out of the source Zone:

- **`ZoneSendSettler`:** an encrypted deposit into the Factory-registered Portal of another Zone, for
  a recipient encrypted to that Zone's key.
- **`PublicSendSettler`:** a transfer to a public address, which its event names, since the transfer
  already does.

Which sends a router allows is just which of these it lists in `settlers`. A closed-loop Zone, whose
Portal trusts its gateway to keep funds in the Zone, lists neither, so one rule covers every way funds
leave. Since they move funds out of a Zone, they get the same review as the router.

### `WithdrawExact`

Redeems EarnShares for an exact amount of the private asset, such as a known payment, rather than
an exact number of shares. The router calls `withdrawExact(assets, router, input)` on the vault,
converts the vault asset to the private asset at par when they differ (the same pool, checks and
1:1 measured output as op 1, with `keccak256` of the assets' encrypted payload as the pool trade ID,
unique per action and unlinkable to the sender), and requires at least `minOutput`. It returns the assets and the
unused shares as two deposits, each with its own `ZoneReturn`, so they need no shared payload. When
nothing is left over it skips the shares deposit.

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

`refund(settler, token, amount, zoneReturn)` pulls `amount` from the caller and deposits it into the Zone,
after `checkRefunder(msg.sender, token)` on the settler it names, which must be in `settlers`. It is the router's only public entry point that
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
in the same transaction as `Spent`, carries `senderTag`, `to`, `token`, `amount` and
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
| Purchase, ATM, fees, force capture, a tip beyond the hold, incremental authorization | Spend: public `TS` call, or `Spend` from the Zone           |
| Reversal, hold expiry, partial-capture remainder, merchant refund, dispute won       | Refund: public transfer, or `refund()` into the Zone        |
| Over-capture without funds, a callback that fails after approval                     | Reserve, off chain; the input goes to Stripe's Zone account |

A closed-loop Zone still needs change on every callback, so Bridge withdraws the input plus change of
at least `depositFee + bouncebackFee + 1`, and `maxInput` leaves that change outside the settler's
reach.

## Decisions this changes

- **Decision 5** (no conversion) gives way to par conversion through the Earn source, which the
  requirements' program setup asks for.
- **Decision 3** stays: `Spend` carries no action ID.
- **Decision 6** changes: one settler per program, and one router per Zone listing every program's
  settler.
- **Decision 15** changes: a private spend uses Earn shares if they cover it, otherwise stablecoin,
  otherwise both, otherwise Bridge declines. One withdrawal carries one token, so "both" is two
  withdrawals in the cardholder's same Zone transaction, each a `Spend` op with its own Bridge `Spend` struct for its
  part of the amount. The contracts need no change for this. The two callbacks are independent: if
  one bounces after approval, the reserve covers its part, as for any failed callback. A split pays
  two withdrawal fees and two change returns, uses about 3M callback gas in total, and gives Bridge
  two `senderTag`s to match to one authorization.
- **Earn's router rules** in [earn/src/AGENTS.md](../../earn/src/AGENTS.md) and router invariant 2 in
  [zone-router.md](../earn/modules/zone-router.md#router-contract): "every successful callback returns
  its complete output through that Portal" and "no caller-selected destinations" become "or pays
  through a settler fixed at deployment, using at most the callback's `maxInput`". Sends out of the
  source Zone are settlers too, so the settler set fixed at deployment bounds every destination.

## Phases

| Phase         | Public spend                                                            | Private spend                                       | Bridge changes                                 |
| ------------- | ----------------------------------------------------------------------- | --------------------------------------------------- | ---------------------------------------------- |
| Today         | `TS` with Earn built in                                                 | `ZoneSpendReceiver` → `TS`                          | —                                              |
| Bridge phase  | `TS` → funding sources                                                  | `ZoneRouter` `Spend` → `BridgeSettler` → `TS`       | Router address, `Spend` wrapper, event parsing |
| TIP-1120 live | `requireFunds` with the same sources, then a stablecoin-only `TS` spend | Unchanged                                           | The key gets a single dollar limit             |
| Tempo-native  | A key-scoped transfer to the settlement wallet                          | `ZoneRouter` `Spend` → a direct settler in `spend/` | Retire `TS` and `BridgeSettler`                |

The router, its callback format, the funding sources, Bridge's settlement wallet as payee and the
cardholder's access keys stay the same through every phase.

## Rollout

1. **Earn:** `ZoneRouter` and `ZoneRouterFactory`, with ops 0 and 1 byte-identical and their tests carried over, plus `WithdrawExact`, the send settlers and stablecoin-only routers. The rename
   lands with its consumers: tempoxyz/tempo (which builds `earn/src/` and reads the router outputs),
   `viem/tempo`, and the zone-router deployment module.
2. **Spend:** `BridgeSettler`, a "ZoneRouter" setup in the 35-scenario matrix, and `e2e/zone` on the
   new path, with callback gas measured against today's 2.02M (Earn) and 0.98M (DLUSD) and Bridge's
   3M limit.
3. **Spend:** `TS` funding through sources, including par conversion.
4. **Cutover:** each Zone admits the program's router as its gateway and Bridge switches its callback
   data, `to` address, fallback recipient and event parsing. Old receivers stay deployed so in-flight
   spends finish or bounce.
