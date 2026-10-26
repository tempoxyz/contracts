# Audit scope

What an audit of Tempo spend covers, what it can take as given, and where to look hardest. The
design is in [`design.md`](design.md) and Bridge's side in [`bridge-integration.md`](bridge-integration.md).

## In scope

| File                        | Lines | What it does                                                                                                                                                                     |
| --------------------------- | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/SpenderTempoSpend.sol` | 247   | Bridge spender handler `TS`. Runs by delegatecall in each program's clone and settles a `Spend` from stablecoin, Earn shares, or both.                                           |
| `src/ZoneSpendReceiver.sol` | 174   | One per program and Zone. Takes the Zone withdrawal callback, settles the spend through the clone, and returns unused input to the Zone encrypted. Also credits private refunds. |
| `src/interfaces/*`          |       | The subsets of Bridge's factory, Tempo Earn's vault and the Zone outbox the two contracts call.                                                                                  |
| `script/deploy/*`           | 788   | Deploy the handler and a receiver, write the role-gated factory calls as calldata, and check a program before it goes live.                                                      |

## Out of scope, taken as given

Bridge's contracts and the Zone contracts are vendored at the commits in
[`vendor/VENDORED.md`](../../spend/vendor/VENDORED.md), unchanged except for import paths. Tempo Earn is the
code in [`earn/src/`](../../earn/src/), audited separately:

- **Bridge's spender contracts:** `SpenderFactory`, `SpenderDelegator`, `SpenderBase` and the EA,
  P2 and TF handlers, plus the EV handler from Bridge's unmerged PR #14.
- **Tempo Earn:** `EarnVault` and its engines.
- **Tempo Zones:** `ZonePortal`, `ZoneMessenger` and `Verifier`. The Zone outbox is a Zone-side
  precompile, so `src/interfaces/IZoneOutbox.sol` describes only the calls Bridge makes.

What the in-scope code relies on from them:

- **The factory** authorizes destinations per program, pauses every clone, and routes `publicCall`
  to the handler by its 2-byte prefix.
- **The Zone messenger** is the only caller of `onWithdrawalReceived`, and it passes the true source
  Zone and portal.
- **`EarnVault.withdrawExact`** burns at most `maxEarnShares` and sends exactly `assets`.
- **TIP-20 tokens** revert on failure and need no return-value quirks beyond what `SafeTransferLib`
  handles.

## Invariants to check

1. **A spend only pays a program destination.** `destination` must be authorized for
   `spenderId`, and `spenderId` must be the ID `createSpender` deployed this clone for. Another ID
   registered on the same clone cannot spend. Only governance allows Earn vaults, since a vault's
   `withdrawExact` decides where redeemed value goes.
2. **The destination is credited exactly `amount`.** The handler checks the destination's balance
   before and after, so fee-on-transfer or rebasing tokens revert the spend.
3. **Share cost is bounded.** A spend from Earn burns no more than `maxShares` when it is set, and
   unused shares return to the payer.
4. **The receiver holds nothing after a callback.** Its balance of the input token after the callback
   equals its balance before (`ResidualBalance`), and approvals to the clone and portal are cleared.
5. **Only the right Zone can call the receiver.** The caller is the Zone messenger, the source Zone is
   `ZONE_ID`, and the source portal is the Zone factory's portal for that Zone.
6. **No cardholder address reaches Tempo.** `PrivateSpendSettled` and `PrivateRefundCredited`
   carry only `senderTag`, Bridge's `ref`, tokens and amounts. Returns go back as encrypted
   deposits.
7. **The handler's storage cannot collide with the clone's.** `allowedVaults` lives at an ERC-7201
   slot (`tempo.spend.SpenderTempoSpend`).
8. **Bridge's pull pipeline is off for `TS`.** `transferToDestination` and its strict variant
   revert, so no standing allowance can be pulled.
9. **Only a program destination can credit a private refund, and not while the factory is
   paused.** The receiver can be a closed-loop Zone's callback gateway, so `refundPrivate` must not
   let others deposit through it.
10. **A callback that moves nothing does not settle.** If the clone consumed none of the input, or
    handed back more than it was given, the receiver reverts `NothingSettled`, so the spend bounces
    instead of emitting `PrivateSpendSettled`.
11. **A private spend settles only if the destination was paid.** The receiver reads the
    destination's balance of `Spend.token` before and after the clone call and reverts
    `DestinationNotPaid` unless it rose by exactly `amount`.
12. **The portal keeps no more than the return allows.** `_depositToZone` reverts
    `DepositFeeTooHigh` when the portal's deposit fee is above `ZoneReturn.maxDepositFee`.

## Where to look hardest

- **Arbitrary callers of the receiver's path.** Any Zone user can withdraw to the receiver with any
  `callbackData`. It must only ever pay a program destination, out of that user's own funds.
- **The Earn path:** rounding in `previewWithdraw` and `withdrawExact`, the `maxShares` check, and
  returning unused shares to a receiver that then deposits them back to the Zone.
- **Closed-loop and Earn change.** Any callback that deposits back must deposit at least the
  portal's deposit and bounce-back fees, or the portal reverts `DepositTooSmall` and the spend
  bounces after Bridge approved it. Bridge adds that change, but the contracts do not enforce it.
- **Reentrancy** through tokens or the vault during `onWithdrawalReceived` and `refundPrivate`.
  Both are `nonReentrant`.
- **Approval hygiene** in the handler and the receiver: exact approvals, cleared after use.

## Accepted risks and decisions

- **A leaked Zone key can withdraw outside the program.** Bridge's Zone access key is scoped to
  the outbox, which cannot pin a withdrawal's recipient. A leaked key can withdraw a cardholder's
  Zone balance, up to the key's limit, to any address (open Zone) or admitted account (closed
  loop). Bridge uses one key per program, so one leak reaches every cardholder of that program.
- **A public key reaches every handler the program can use.** Its scope names the clone's
  `publicCall`, which routes by prefix, so it can call other handlers' public actions as the
  cardholder, such as a Tempo Earn handler's vault preference. None moves funds. Gating a handler closes it.
- **No on-chain idempotency.** Bridge dedupes retried spends off chain by its pull ID.
- **Failures after approval.** A private spend that bounces after Bridge approved the card is
  covered by Bridge's reserve, off chain.
- **Spend events are not proof of payment.** Anyone can call `publicCall "PS"` with a token they
  control and Bridge's `ref`, and any Zone user can put any `ref` in callback data. Bridge
  reconciles by the transactions it sent and by `senderTag`, never by `ref` alone.
- **No sweep.** Tokens sent to a receiver outside a callback stay there: it has no owner and moves
  only the current call's input.
- **The withdrawer chooses where change goes.** The `ZoneReturn` comes from callback data, so a
  leaked Zone key also picks the recipient of any change.
- **`availableBalance` values shares with the vault's redeem preview.** A vault that cannot report
  its asset, share or redemption value reports the stablecoin alone. The deploy scripts refuse a vault without exact
  withdrawals or redeem previews.

## Test evidence

| Suite                                                                                                           | What it covers                                                                                                                                 |
| --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `test/unit/SpenderTempoSpend.t.sol`, `ZoneSpendReceiver.t.sol`, `PrivateSpend.t.sol`, `PrivateEarnChange.t.sol` | Handler and receiver behavior, every revert, events, approval hygiene, hostile callback data, Earn change under portal fees, and fuzzed spends |
| `test/unit/Roles.t.sol`                                                                                         | Every factory role against wrong callers, pause recovery, handler status                                                                       |
| `test/unit/AccessKeySecurity.t.sol`                                                                             | What a leaked public or Zone key can and cannot do                                                                                             |
| `test/unit/DeployScripts.t.sol`                                                                                 | The deploy scripts and the calls they write                                                                                                    |
| `test/e2e/Matrix.t.sol`                                                                                         | 35 card scenarios against 11 setups ([`matrix.md`](matrix.md))                                                                                 |
| `e2e/zone`                                                                                                      | A real L1 and Zone, locally and on Moderato, including an Earn spend                                                                           |
