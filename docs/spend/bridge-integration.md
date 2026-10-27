# Bridge backend integration

How Bridge's card backend (monorail) uses Tempo spend: enrollment, the authorization path for
public and private spend, settlement tracking, refunds and retries. The contracts are in
[`design.md`](design.md) and deploying them is in [`deploy.md`](deploy.md).

## How it fits today's pull path

Today a just-in-time card pull runs:

1. `StripeRpcController` (`packs/cards/app/controllers/stripe_rpc_controller.rb:67`).
2. `ProcessStripeAuthorizationRpc`, then `ApplyStripeAuthHold`, then `DebitCustomerWallet`.
3. `SynchronousNoncustodialJitManager#submit_using_crypto_pulls!`
   (`packs/cards/.../synchronous_noncustodial_jit_manager.rb:167`).
4. `CryptoPulls::Api#pull!` (`packs/crypto_pulls/app/public/api.rb:253`), then `AdvancePull`.
5. `Chains::Evm::TransferToDestination`, where the card-controllers hot wallet sends the debitor's
   `transferToDestination`.

The card is approved once the pull is `Submitted`, and a failure after that is a double spend
Bridge absorbs.

Tempo spend keeps steps 1 to 4 and replaces step 5 with a new mechanism, `TS`. The transaction is
signed by a Bridge-held **access key on the cardholder's account**, not by the debitor, and it
calls the program clone's `publicCall`, not `transferToDestination`, which `TS` reverts.

|                         | Today (`EA`, `P2`, `TF`)              | `TS`, public                                 | `TS`, private                                  |
| ----------------------- | ------------------------------------- | -------------------------------------------- | ---------------------------------------------- |
| Signer                  | Card-controllers hot wallet (debitor) | Bridge access key, as the cardholder         | Bridge Zone access key, as the cardholder      |
| Sent to                 | Tempo L1                              | Tempo L1                                     | The Zone RPC                                   |
| Call                    | `transferToDestination`               | `approve` + `publicCall "PS"` + `approve(0)` | `approve(outbox)` + `requestWithdrawal`        |
| Bridge approves on      | Submission                            | The L1 receipt                               | The Zone receipt                               |
| Can fail after approval | Yes (double spend)                    | No: the receipt is the settlement            | Yes: the callback can revert, the reserve pays |

## Enrollment

The cardholder authorizes Bridge's key once per account, in the wallet that holds the key's root.
The authorization is a keychain `authorizeKey` with:

- **Public:** a limit on each token the card spends, `approve` scoped to the clone as recipient,
  and the clone's `publicCall`. See `TempoAccessKeyRail._railEnroll` in `test/rails/TempoRails.sol`.
- **Private:** a limit on the Zone token, `approve` scoped to the Zone outbox, and the outbox's
  `requestWithdrawal`. See `e2e/spend/src/run.ts` step 6.
- An expiry. A key is good until it expires or the cardholder revokes it.

Bridge uses **one access key per program**: every cardholder of a program authorizes the same
Bridge key. Bridge keeps per cardholder the limits and expiry they authorized, and for private
cards the Zone ID. A leaked key therefore reaches every cardholder of its program, up to each one's
limit, which tight limits and short expiries bound.

- **Limits count gross debits.** Every approval counts against the key's periodic limit, and
  nothing that comes back (change, a bounce, a released hold) restores it. Size limits above card
  spend with that in mind.
- **Rotation re-enrolls everyone.** A key cannot revoke itself, and the L1 and Zone keychains are
  separate, so replacing a program's key needs every cardholder to authorize the new one on each.

## Authorization

### Preflight

Before signing, decline if any of these fail. Each is a read:

- **Program pause:** `SpenderFactory.paused()` on the L1. A private spend reverts on the L1 after
  approval if the program is paused, so check it first.
- **Handler:** `getSpenderHandlerWithCheckedPermissions("TS", clone)` does not revert, so the
  handler is enabled, or gated with the program allowed.
- **Destination:** `isAuthorizedDestination(spenderId, destination)`.
- **Balance:** the cardholder's token balance, plus share value for Earn. On the L1 that is
  `availableBalance` on the clone. In a Zone it is `balanceOf` through an authenticated Zone RPC,
  for the one token the spend withdraws.
- **Key headroom:** the spend fits the key's remaining periodic limit.
- **Zone health, private only**, read on the L1:
  - the portal is not paused and `areDepositsActive(token)` is true;
  - the router still has its Zone role, and the refund recipient and program wallet are still
    admitted;
  - `calculateDepositFee() + calculateBouncebackFee()` is within the change Bridge adds;
  - batches are still posting, and Bridge's oldest unsettled withdrawal is younger than its
    threshold, so a request will settle.

### Public spend

One Tempo transaction from the cardholder's account, signed by Bridge's access key, with Bridge as
fee payer:

```text
token.approve(clone, fromStable)
earnShare.approve(clone, maxShares)       only when spending from Earn
clone.publicCall("TS" "PS" abi.encode(Spend))
token.approve(clone, 0)
earnShare.approve(clone, 0)               only when spending from Earn
```

`Spend` is `spenderId, token, amount, destination, vault, fromVault, maxShares, ref`:

- `ref` is Bridge's own reference. Use the crypto pull's ID.
- `fromVault` is how much of `amount` comes from Earn.
- `maxShares` is the live `previewWithdraw(fromVault)` plus a tolerance. The harness uses 0.5%.
  Always set it: it sizes the share approval, and zero would approve no shares.

Approve the card on the receipt. A revert means nothing moved: decline.

### Private spend

One Zone transaction from the cardholder's Zone account, signed by Bridge's Zone key:

```text
inputToken.approve(outbox, input)
outbox.requestWithdrawal(inputToken, router, input, memo, callbackGas,
                         fallbackRecipient = cardholder, callbackData, revealTo = "")
```

`router` is the program's Spend-mode `ZoneRouter` for that Zone (see [`deploy.md`](deploy.md)).

Bridge sponsors the transaction, and the outbox then takes the withdrawal fee from Bridge's fee
payer in the input token: stablecoin, or EarnShare for an Earn spend. The fee payer holds and
approves those tokens. Unsponsored, the cardholder approves `input + withdrawalFee` and pays it.

- `inputToken` is the stablecoin, or EarnShare for an Earn spend. A withdrawal carries one token,
  so a private spend is all stablecoin (`fromVault = 0`) or all Earn (`fromVault = amount`), never
  split as a public spend can be. Its preflight balance is that one token's. Use Earn shares if
  they cover the spend, otherwise the stablecoin, otherwise decline.
- An Earn spend settles in the vault's asset.
- `input` is `maxInput` plus change. `maxInput` is the amount, or `maxShares` for Earn: the
  settler uses no more, and the router returns the rest to the cardholder. A callback that deposits anything
  back must deposit at least the portal's fees, or the portal rejects it and the spend bounces. So
  add at least `calculateDepositFee() + calculateBouncebackFee() + 1` whenever something comes back:
  on an access-enforced portal, which requires a return, and on every Earn spend, which returns its
  unused shares. Add a margin too, since a fee that rises before the batch bounces the spend. A
  stablecoin spend on an open portal adds nothing.
- `withdrawalFee` is the outbox's `calculateWithdrawalFee(callbackGas)`. Use 3M callback gas (see
  [`design.md`](design.md#callback-gas)).
- `callbackData` is `abi.encode(SpendData)`: `op = 2` (Spend), `settler` (the program's
  `BridgeSettler`), `maxInput`, `settlerData = abi.encode(Spend)` and `zoneReturn`. That
  `SpendReturn` is the encrypted deposit (`keyIndex`, `encrypted`) that sends unused input back to
  the cardholder, a public `refundRecipient` for when the Zone rejects
  it, and `maxDepositFee`, the most the portal may keep, which is the fee the change covers. Build a
  fresh encrypted deposit for each spend, so no two returns match on the L1. Encrypt it to the portal's sequencer key, as `prepareRecipient` does in the E2E.
  monorail builds encrypted Zone deposits in `packs/hot_wallet/.../tempo_zone/encrypt_deposit_payload.rb`.
- `refundRecipient` appears on the L1 with every return, so it is never the cardholder. It is one
  dedicated Bridge-controlled account per program, admitted on the Zone.

Approve the card on the Zone receipt. Settlement on the L1 follows once the Zone posts its batch
(see [`design.md`](design.md#latency)).

## After approval: private settlement

A private spend ends in one of three ways:

| Outcome | What Bridge sees                                                                                                                                                                                                                                                                                                                     | Bridge records                                                                                       |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- |
| Settled | The portal's `WithdrawalProcessed(to = router, senderTag, token, amount, callbackSuccess = true)`, and in the same transaction the router's `Spent(settler, token, used, change, zoneDepositHash)` and the settler's `SpendSettled(ref, inputToken, inputConsumed, inputReturned)`. The settler has checked the destination was paid | Pull `Completed`                                                                                     |
| Bounced | The portal's `WithdrawalProcessed` for the router and `senderTag` with `callbackSuccess = false`, and no `Spent` or `SpendSettled`                                                                                                                                                                                                   | Failed after approval: draw the reserve, record cardholder debt, as the double-spend path does today |
| Pending | Neither, past Bridge's timeout: the portal is paused, the Zone stopped posting batches, or the Zone dropped the receipt                                                                                                                                                                                                              | Unresolved: hold the authorization's exposure and escalate to the Zone operator                      |

- Match both outcomes by the `senderTag` in the portal's `WithdrawalProcessed`:
  `keccak256(abi.encodePacked(sender, txHash, fallbackNonce))`, where `fallbackNonce` is in the
  outbox's withdrawal event in Bridge's own Zone receipt. Neither the router nor the settler emits
  it, so read `Spent` and `SpendSettled` from the same transaction. Trust only events emitted by the
  program's portal, router and settler. `ref` and the `Spend`
  fields come from callback data anyone can write, so never match on `ref` alone.
- A spend can bounce after approval for:
  - **The program:** a paused factory, a disabled or un-allowlisted `TS` handler, a destination
    removed while the spend was in flight (add the new one before removing the old), or a vault
    governance disallowed.
  - **The Zone admin:** paused deposits of the token, a deposit or bounce-back fee raised above the
    change or `maxDepositFee`, the router's gateway role removed, the refund recipient
    de-admitted, or an encryption key expired during a stall.
  - **Token and vault admins:** a TIP-403 policy change that blocks the router, settler, clone, vault,
    portal, messenger, Zone admin (which receives the deposit fee), settlement wallet or refund
    recipient, or an Earn engine or venue that stops withdrawals.
  - **Earn spends:** a price move past `maxShares`, or an illiquid venue.
- On a bounce, the full input goes back to the cardholder's Zone balance through the fallback. The
  withdrawal fee is not returned.
- A bounce carries no reason. The messenger replaces every callback revert with `CallbackRejected()`,
  so the errors under [Events and errors](#events-and-errors) reach Bridge only by simulating the
  callback or tracing the settlement transaction.
- A cardholder can revoke Bridge's key or spend the returned input after a bounce, so the debt may
  not be collectable on chain.

## Refunds

Refunds are stablecoin, as today's crypto-return trips are:

- **Public:** a transfer from the program wallet to the cardholder's account.
- **Private:** the program wallet, admitted on the Zone, approves the portal and calls its own
  `depositEncrypted(token, amount, keyIndex, encrypted, refundRecipient)` with a fresh deposit
  encrypted to the cardholder and the program's `refundRecipient`. No contract of this project is
  involved, and nothing on the L1 names the cardholder. The cardholder receives `amount` less the
  portal's deposit fee, and the portal reverts `DepositTooSmall` for an amount below the deposit and
  bounce-back fees.
- **Returns the Zone rejects:** a change return or refund the Zone side rejects comes back to the
  program's `refundRecipient`, with no deposit ID. Bridge matches it by token, amount and time, and
  pays the cardholder again. `amount` is net of the bounce-back fee. It arrives one of two ways:
  - paid, as the portal's `DepositBounceBack(tempoRefundRecipient, token, amount, bouncebackFee)`;
  - parked in the portal, as `DepositBounceBackPending` with the same fields, when the portal cannot
    pay the refund recipient (it lost its Zone role, or a policy blocks it). Restore what blocked
    it, then the refund recipient calls the portal's `claimRefund(token)`, which emits
    `RefundClaimed(recipient, token, amount)`.
- **Programs with two tokens:** a stablecoin spend settles in that stablecoin and an Earn spend in
  the vault's asset, which can differ (DLUSD and OUSD). The settlement and program wallets then
  hold both, and refunds go in the token the spend settled in.

## Retries

`TS` has no on-chain idempotency. Bridge dedupes by pull ID, as `AdvancePull` already does by
`external_id`, and must not resubmit a spend whose first attempt may have landed:

- **Public:** look up the transaction hash.
- **Private:** look up the Zone receipt, or the `senderTag` in the portal's `WithdrawalProcessed`
  on the L1. Set `validBefore` on the Zone
  request, so a request Bridge gave up on cannot land after the card was declined.

## Events and errors

Events Bridge reads:

- `TempoSpendExecuted(ref, from, destination, token, amount, fromStable, fromVault, sharesBurned)`
  from the clone, on every spend. `from` is the cardholder for a public spend and the settler for a
  private one. Anyone can call `publicCall "PS"` with any token, so reconcile public spends by the
  transaction hash Bridge sent, never by this event alone.
- `Spent(settler, token, used, change, zoneDepositHash)` from the router and
  `SpendSettled(ref, inputToken, inputConsumed, inputReturned)` from the settler, on every settled
  private spend. Neither carries the `senderTag` or a cardholder address.
- `SpendVaultUpdated(vault, allowed)` from the clone, on governance's `"UV"` call.
- From the program's portal: `WithdrawalProcessed(to, senderTag, token, amount, callbackSuccess)`
  for every settlement, which carries the `senderTag` Bridge matches, `DepositBounceBack` and `DepositBounceBackPending` for rejected returns, and
  `RefundClaimed` when a parked return is claimed.

Reverts a spend can hit. A public spend reverts with them in Bridge's transaction. A private spend
only bounces, so they show up when Bridge simulates the callback or traces the settlement:

- **The factory and clone:** `FactoryPaused`, `SpenderHandlerDisabled`, `SpenderHandlerNotAllowed`
  and `PrefixUnknown`.
- **The handler:** `WrongProgram`, `DestinationNotAuthorized`, `DestinationNotCredited`,
  `InvalidAmount`, `VaultNotAllowed`, `IncorrectAssetForVault`, `ShareCostExceeded`, and
  `PipelineDisabled` on the pull path.
- **The router:** `NotZoneMessenger`, `WrongSourceZone`, `InvalidSourcePortal`, `OpDisabled`,
  `UnknownSettler`, `InvalidMaxInput`, `InvalidSettlement`, `InvalidReturnToken`,
  `DepositFeeTooHigh`, `ResidualBalance`, `ReentrantCall` and `ZeroAddress` (no refund recipient).
- **The settler:** `WrongProgram`, `WrongInputToken`, `InvalidAmount`, `NothingSettled`,
  `DestinationNotPaid`, `ResidualBalance` and `Reentrancy`.
- **The portal, on the return deposit:** `DepositTooSmall` when change does not cover its fees,
  and on an access-enforced portal `CallbackDidNotReturnToZone` when nothing comes back.
- **The keychain, on a public spend:** `SpendingLimitExceeded` and `CallNotAllowed`.
- **The Zone outbox, before approval:** a callback gas limit above 10M reverts the Zone request,
  so the card is declined rather than bounced.

Reads:

- `availableBalance("TS" from token [vault])`: `from`'s balance of `token`, plus the value of its
  shares in `vault` when the vault is allowed and holds `token`. Otherwise the vault is ignored.
- `publicGetCall("TS" "GV" vault)`: whether the program allows `vault`.

## Accepted behavior

- Tokens sent to the router or settler outside a callback stay there. Neither has an owner, and
  each moves only the current call's input.
- The withdrawer writes the `SpendReturn`, so whoever sends a withdrawal to the router chooses
  where its change goes.
