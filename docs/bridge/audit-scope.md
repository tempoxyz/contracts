# Audit scope

What an audit of Tempo's Bridge integration covers, what it can take as given, and where to look
hardest. The design is in [`design.md`](design.md) and Bridge's side in
[`bridge-integration.md`](bridge-integration.md). Paths are relative to `bridge/`.

## In scope

| File                                                                                                                                               | Lines | What it does                                                                                                                                                                                                                                                                                              |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/SpenderTempoSpend.sol`                                                                                                                        | 208   | Bridge spender handler `TS`. Runs by delegatecall in each program's clone and settles a `Spend` from stablecoin, Earn shares, or both.                                                                                                                                                                    |
| `../zone-router/src/settlers/BridgeSettler.sol`, `../zone-router/src/settlers/bridge/IBridgeSpender.sol`                                           | 158   | One settler per program. The router's Spend settler: takes the `maxInput` the router sent, settles the spend through the clone, checks the destination was paid, and hands unused input back. The interface file holds the `Spend` struct the handler imports and the two Bridge calls the settler makes. |
| `../zone-router/src/ZoneRouter.sol`                                                                                                                | 501   | One per mode, from the factory. In Spend mode it takes the Zone withdrawal callback from one Zone, transfers `maxInput` to a listed settler, and returns unused input to the Zone encrypted.                                                                                                              |
| `../zone-router/src/ZoneRouterFactory.sol`, `../zone-router/src/interfaces/ISpendSettler.sol`, `../zone-router/src/interfaces/IZonePortalFees.sol` | 61    | Ownerless CREATE2 deployer that fixes each router's mode, the settler interface, and the portal deposit-fee read the router caps.                                                                                                                                                                         |
| `src/interfaces/*`                                                                                                                                 |       | The subsets of Bridge's factory and clone and Tempo Earn's vault the handler and scripts call, and the Zone outbox calls Bridge makes.                                                                                                                                                                    |
| `script/deploy/*`                                                                                                                                  | 884   | Deploy the handler and a program's settler and router, write the role-gated factory calls as calldata, and check a program before it goes live (Solidity; `release.sh` drives the handler's CI release).                                                                                                  |

## Out of scope, taken as given

Bridge's contracts and the Zone contracts are vendored at the commits in
[`vendor/VENDORED.md`](../../bridge/vendor/VENDORED.md), unchanged except for import paths. Tempo Earn is the
code in [`earn/src/`](../../earn/src/), audited separately:

- **Bridge's spender contracts:** `SpenderFactory`, `SpenderDelegator`, `SpenderBase` and the EA, EP,
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
- **TIP-20 tokens** revert on failure and need no return-value quirks beyond what the handler's
  `SafeTransferLib` and the settler's own call check (a revert, or a return other than `true` or
  nothing) handle.

## Invariants to check

1. **A spend only pays a program destination.** `destination` must be authorized for
   `spenderId`, and `spenderId` must be the ID `createSpender` deployed this clone for. Another ID
   registered on the same clone cannot spend. Only governance allows Earn vaults, since a vault's
   `withdrawExact` decides where redeemed value goes.
2. **The destination is credited exactly `amount`.** The handler checks the destination's balance
   before and after, so fee-on-transfer or rebasing tokens revert the spend.
3. **Share cost is bounded.** A spend from Earn burns no more than `maxShares` when it is set, and
   unused shares return to the payer.
4. **The router and settler hold nothing after a callback.** Each one's balance of the input token
   after the callback equals its balance before the input arrived (`ResidualBalance`), the router
   never approves the settler. The settler's approval to the clone, the router's to its portal and
   the clone's to an allowed vault stay standing at the maximum, so no spend creates their slots
   (TIP-1000); each holder keeps nothing between spends for them to take.
5. **Only the right Zone can call the router.** The caller is the Zone messenger, the source Zone is
   the router's `allowedZoneId`, the source portal is the Zone factory's portal for that Zone, and
   Spend uses only the settlers fixed in the router's mode (`UnknownSettler`).
6. **No cardholder address or `senderTag` reaches Tempo from these contracts.** `Spent`,
   `SpendSettled` and the handler's `TempoSpendExecuted` (whose payer is the settler) carry only the
   settler, the program destination, Bridge's `ref`, tokens, amounts and the portal's deposit hash.
   Returns go back as encrypted deposits.
7. **The handler's storage cannot collide with the clone's.** `allowedVaults` lives at an ERC-7201
   slot (`tempo.spend.SpenderTempoSpend`).
8. **Bridge's pull pipeline is off for `TS`.** `transferToDestination` and its strict variant
   revert, so no standing allowance can be pulled.
9. **The settler takes at most `maxInput`.** `maxInput` cannot exceed the withdrawal
   (`InvalidMaxInput`), the router transfers exactly `maxInput` and grants no allowance, and it
   reverts `InvalidSettlement` if the settler handed back more than it was sent. The cardholder's Zone transaction sets it, so a replaced handler can take
   at most the spend, never the change.
10. **A callback that moves nothing does not settle.** If the clone consumed none of the input, or
    handed back more than it was given, the settler reverts `NothingSettled` (and the router
    `InvalidSettlement`), so the spend bounces instead of emitting `Spent`.
11. **A private spend settles only if the destination was paid.** The settler reads the
    destination's balance of `Spend.token` before and after the clone call and reverts
    `DestinationNotPaid` unless it rose by exactly `amount`.
12. **The portal keeps no more than the return allows.** The router reverts `DepositFeeTooHigh`
    when the portal's deposit fee is above `SpendReturn.maxDepositFee`.
13. **A settler serves one program.** `BridgeSettler` rejects a `Spend` for another `spenderId`
    (`WrongProgram`) and an input other than the spend's token or its vault's EarnShare
    (`WrongInputToken`).

## Where to look hardest

- **Arbitrary callers of the router's Spend path.** Any Zone user can withdraw to the router with
  any `callbackData`. It must only ever pay a program destination through a listed settler, out of
  that user's own funds.
- **The Earn path:** rounding in `previewWithdraw` and `withdrawExact`, the `maxShares` check, and
  returning unused shares through the settler to the router, which deposits them back to the Zone.
- **Closed-loop and Earn change.** Any callback that deposits back must deposit at least the
  portal's deposit and bounce-back fees, or the portal reverts `DepositTooSmall` and the spend
  bounces after Bridge approved it. Bridge adds that change, but the contracts do not enforce it.
- **Reentrancy** through tokens or the vault during `onWithdrawalReceived` and `settle`. Both are
  guarded (`ReentrantCall`, `Reentrancy`).
- **Standing approvals** in the handler, the settler and the router: the clone's EarnShare approval
  to an allowed vault (set by governance's `UV`, cleared when it disallows, restored by a spend after
  another handler such as TF clears it), the settler's to its clone and the router's to its portal.
  Check that nothing those spenders can reach is left in the clone, settler or router between spends,
  and that `maxInput` still bounds a spend. The cardholder's own approvals on the public path stay
  exact and cleared.
- **Tokens sent to the settler outside a callback.** The settler takes its balance less
  `maxInput` as what it held before the router's input, so that input is accounted for, but tokens
  sent to it directly are not: any later `settle` caller can spend them through the program's clone, only to
  a destination the program authorizes, and gets back the part the spend did not use. Nothing
  rescues them.

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
  reconciles by the transactions it sent and by the `senderTag` in the portal's
  `WithdrawalProcessed`, never by `ref` alone.
- **No sweep.** Neither the router nor the settler has an owner. Tokens sent to the router outside a
  callback stay there; tokens sent to the settler stay until a `settle` caller spends them to a
  program destination, as above.
- **The withdrawer chooses where change goes.** The `SpendReturn` comes from callback data, so a
  leaked Zone key also picks the recipient of any change.
- **`availableBalance` values shares with the vault's redeem preview.** A vault that cannot report
  its asset, share or redemption value reports the stablecoin alone. The deploy scripts refuse a vault without exact
  withdrawals or redeem previews.

## Test evidence

| Suite                                                                                                       | What it covers                                                                                                                                                                                             |
| ----------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test/unit/SpenderTempoSpend.t.sol`, `BridgeSettler.t.sol`, `PrivateSpend.t.sol`, `PrivateEarnChange.t.sol` | Handler, settler and router Spend behavior, every revert, events without the `senderTag`, approval hygiene, hostile callback data, Earn change under portal fees, and fuzzed spends                        |
| `../zone-router/test/ZoneRouter.t.sol`                                                                      | Router modes and the Spend op: callback authentication, settler list, `maxInput` cap, deposit fee cap, reentry, and a fuzzed cap                                                                           |
| `../zone-router/test/BridgeSettler.t.sol`                                                                   | The settler's own checks against a mock factory and clone: wrong program, wrong input token, insufficient input, destination not paid, nothing settled, residual balance, and the unused input handed back |
| `test/unit/Roles.t.sol`                                                                                     | Every factory role against wrong callers, pause recovery, handler status                                                                                                                                   |
| `test/unit/AccessKeySecurity.t.sol`                                                                         | What a leaked public or Zone key can and cannot do                                                                                                                                                         |
| `test/unit/DeployScripts.t.sol`                                                                             | The deploy scripts and the calls they write                                                                                                                                                                |
| `test/e2e/Matrix.t.sol`                                                                                     | 35 card scenarios against 11 setups ([`matrix.md`](matrix.md))                                                                                                                                             |
| `../e2e/bridge`                                                                                             | A real L1 and Zone, locally and on Moderato, including an Earn spend                                                                                                                                       |
