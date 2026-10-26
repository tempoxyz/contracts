# ZoneRouter and private card spend (proposal)

**Status: proposed, not implemented.** This page is the target for the ZoneRouter work. Until that
lands, [design.md](design.md) and [Earn's zone router](../earn/modules/zone-router.md) describe
what is deployed. When the code merges, each part of this page moves to the page that owns it and
this page is deleted.

## Why

Private card spend runs through [`ZoneSpendReceiver`](../../spend/src/ZoneSpendReceiver.sol), a
second Zone callback contract next to Earn's [`SingleZoneEarnRouter`](../../earn/src/router/SingleZoneEarnRouter.sol).
That costs us:

- **Two gateways per Zone.** A closed-loop Zone admits each callback gateway, and the receiver is
  one per program and Zone (decision 6).
- **Duplicated Zone code.** Messenger and Portal authentication, encrypted change returns and the
  deposit fee cap exist twice.
- **A privacy exception.** The receiver emits the callback `senderTag`, which Earn's
  [privacy model](../earn/architecture/security-and-privacy.md#privacy-model) forbids elsewhere.
- **An unbounded pull (Cyclops, Low).** The receiver approves the whole withdrawal to the clone. A
  replaced handler can pay the destination exactly and keep the change, and every check still
  passes.

The fix has to keep Bridge's contracts unchanged except at the handler level: every debit pays
through the program's clone, and destinations come from Bridge's allowlist. It should also leave a
path to Tempo-native spend that retires Bridge's adapter without redoing Tempo's contracts or the
cardholder's setup.

## Two layers

| Layer          | Lives in | Contracts                                                              | Lifetime                 |
| -------------- | -------- | ---------------------------------------------------------------------- | ------------------------ |
| Tempo-owned    | `earn/`  | `ZoneRouter`, `ISpendSettler`, Earn and par-conversion funding sources | Permanent                |
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
`refund` off, which gives today's router exactly.

### Ops

The router already reads the first callback word before decoding, so ops 0 and 1 keep their exact
layout and `viem/tempo`'s `earnRouterCallbackData` keeps working.

| Op                  | Input                                       | What the router does                                                              | Back to the Zone        |
| ------------------- | ------------------------------------------- | --------------------------------------------------------------------------------- | ----------------------- |
| 0 Deposit           | Private asset                               | Unchanged                                                                         | EarnShare               |
| 1 Redeem            | EarnShare                                   | Unchanged                                                                         | Private asset           |
| 2 Pay               | Private asset or EarnShare                  | Approves at most `maxInput` to the settler, calls `settle`, measures what it used | Unused input, encrypted |
| `refund()` (public) | Stablecoin from a payer the settler accepts | Deposits it into the Zone for the encrypted recipient                             | The refund              |

`Pay` callback data:

```solidity
struct PayData {
uint8 op; // 2
uint128 maxInput; // the most input the settler may use, signed by the cardholder in the Zone
bytes32 actionId; // random per spend; never Bridge's pull ID
bytes settlerData; // opaque to the router; Bridge's `Spend`
PayReturn zoneReturn; // keyIndex, encrypted, refundRecipient, maxDepositFee
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
5. emits `Paid(actionId, settler, token, used, change, zoneDepositHash)`, with no `senderTag` and no
   cardholder address.

Any revert bounces the whole input back into the Zone.

`maxInput` is what closes the Cyclops finding. It comes from the cardholder's own Zone transaction,
not from the settler or the handler, so a replaced handler can take at most what the cardholder
agreed to spend. Bridge sets it to the spend amount for a stablecoin spend and to `maxShares` for an
Earn spend.

### `ISpendSettler`

```solidity
interface ISpendSettler {
/// Pays from the router's approved `token`, using at most `maxInput`. Reverts unless the
/// payment it makes is complete. Must not leave the router's input with itself.
function settle(address token, uint256 maxInput, bytes calldata data) external;

    /// Reverts unless `payer` may credit a refund into the Zone for `data`'s program.
    function checkRefunder(address payer, address token, bytes calldata data) external view;

}
```

### `refund()`

`refund(token, amount, settlerData, zoneReturn)` pulls `amount` from the caller and deposits it
into the Zone, after `settler.checkRefunder(msg.sender, token, settlerData)`. It is the router's only
public entry point that deposits, and only payers the settler accepts can use it, so it cannot
bypass a closed-loop Zone's admission.

## Bridge adapter (`spend/`)

### `BridgeSettler`

`ZoneSpendReceiver` without its Zone code. One per Zone router serves every program on that Zone,
since `TS` already checks the spender ID and destination. Ownerless; its only immutable is Bridge's
factory. `settle`:

- decodes the `Spend`, requires `token` to be its input, and pulls `maxInput` from the router;
- approves it to the clone for `spend.spenderId` and calls `publicCall "PS"`, then resets the
  approval;
- requires the destination received exactly `spend.amount` and that the handler used something;
- sends the unused input back to the router.

`checkRefunder` makes `refundPrivate`'s checks today: the factory is not paused and the payer is an
authorized destination of the program.

`BridgeSettler` emits nothing with `senderTag`. Bridge matches a private spend by the Portal's own
withdrawal event in the same transaction, so the `senderTag` exception in
[spend/AGENTS.md](../../spend/AGENTS.md) goes away.

### `TS` funding sources

`TS` keeps its `Spend` ABI. Two fields widen in meaning, not type:

- `vault` becomes `source`: any funding source governance allows through the existing `"UV"` call;
- `maxShares` becomes `maxInput`.

`TS` pulls at most `maxInput` from the payer, calls `source.fund(destination, amount)`, returns
unused input, and checks the destination was credited exactly. Sources share the shape of
[TIP-1120](https://tips.sh/1120)'s `IFundingSource`, so the same contracts serve TIP-1120's funder
later:

- **Earn:** `withdrawExact`, today's logic moved out of the handler;
- **Par conversion:** the 1:1 pool route, so an OUSD vault can back a DLUSD card.

## Card flows

Bridge pulls at authorization, so every card event is a spend, a refund or a reserve draw off chain.

| Event                                                                                | On chain                                             |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------- |
| Purchase, ATM, fees, force capture, a tip beyond the hold, incremental authorization | Spend: public `TS` call, or `Pay` from the Zone      |
| Reversal, hold expiry, partial-capture remainder, merchant refund, dispute won       | Refund: public transfer, or `refund()` into the Zone |
| Over-capture without funds, a bounce after approval                                  | Reserve, off chain                                   |

Decisions 4, 5, 13, 14 and 15 in [design.md](design.md#decisions) stay as they are. A closed-loop
Zone still needs change on every callback, so Bridge withdraws the input plus change of at least
`depositFee + bouncebackFee + 1`, and `maxInput` leaves that change outside the settler's reach.

## Rules this changes

- Earn's router rules in [earn/src/AGENTS.md](../../earn/src/AGENTS.md) and router invariant 2 in
  [zone-router.md](../earn/modules/zone-router.md#router-contract): "every successful callback returns
  its complete output through that Portal" and "no caller-selected destinations" become "or pays
  through the deploy-bound settler, using at most the cardholder's `maxInput`".
- Decision 6 becomes one settler per Zone router, serving every program.

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
   new path, with callback gas measured against today's 2.02M (Earn) and 0.98M (DLUSD).
3. **Spend:** `TS` funding through sources.
4. **Cutover:** the Zone admits the router as its gateway and Bridge switches its callback data,
   `to` address and event parsing. Old receivers stay deployed so in-flight spends finish or bounce.

## Open questions

- **Spend matching.** Does the Portal's withdrawal event carry everything Bridge needs to match a spend
  without the settler emitting `senderTag`? Confirm with Bridge and the Zones team before step 2.
- **Input tokens.** `Pay` accepts the router's private asset and EarnShare. A Zone with more card
  stablecoins needs a router per stablecoin, or `Pay` taking any Portal-enabled token.
- **More ops.** Sends (to the same Zone, another Zone or a public address) and asset-denominated
  Earn withdrawals fit the same op table but are not needed for card spend.
- **Gas.** Dropping the receiver's approval round trip should lower callback gas; step 2 measures it.
