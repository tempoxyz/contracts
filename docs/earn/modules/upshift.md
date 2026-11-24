# Upshift engine

This page owns `UpshiftEngine` and `UpshiftRedeemReceiver`: their valuation, immediate and queued
exits, authorities, failure modes, deployment, and tests. The shared engine contract is in
[yield engines](../integrations/engines.md). Neither contract is covered by a completed audit
([audits](../../audits.md#coverage)), and the engine has no registry kind, so the lifecycle,
localnet, and E2E cannot deploy it.

`UpshiftEngine` ([source](../../../src/earn/engines/upshift/UpshiftEngine.sol)) holds the receipt
tokens of one Upshift (August) tokenized vault for one EarnVault. The vault is not ERC-4626: it
issues a separate receipt token, prices it from a NAV its operator reports, pays an instant
redemption from idle cash, and queues a lagged redemption by claim date and receiver. The vault's
source is externally owned and is not vendored here; the engine calls it through
[`IUpshiftVault`](../../../src/interfaces/external/upshift/IUpshiftVault.sol).

## Contracts

### UpshiftEngine

The vault (`vault()`), its receipt token (`shareToken()`), the base asset (the vault's `asset()`), and
the receiver implementation are immutable; the EarnVault binding is set once; `maxNavAge` is nonzero.
One engine share is one raw receipt token.

The engine advertises `IEarnEngineRedeem`, `IEarnEngineAsyncRedeem`, `IEarnEngineFeeValuation`, and
`IEarnEngineHeldDeposit`. It does not advertise `IEarnEngineExactWithdraw` or
`IEarnEngineInKindDeposit`, so the EarnVault's exact-asset withdrawal and in-kind entry revert on
this engine.

Its `Ownable2Step` owner can only change the nonzero `maxNavAge`, and once the engine is bound only
while EarnVault deposits are paused (`setMaxNavAge`). No engine role can move receipt tokens or the
base asset, and there is no sweep.

### UpshiftRedeemReceiver

[`UpshiftRedeemReceiver`](../../../src/earn/engines/upshift/UpshiftRedeemReceiver.sol) is the address
one queued redemption is paid to. The engine deploys the implementation in its constructor and one
minimal proxy of it per request. `sweep(token, to)` sends the receiver's whole balance of `token`
to `to`, and only the engine that deployed the implementation can call it, for every proxy.

## Valuation and freshness

| Read                | Value                                                                                  |
| ------------------- | -------------------------------------------------------------------------------------- |
| `totalShares()`     | Receipt tokens the engine holds. Queued shares are excluded: the vault has taken them. |
| `valueOf(s)`        | `previewRedemption(s, false)` after the vault's lagged withdrawal fee                  |
| `totalAssets()`     | `valueOf(totalShares())`                                                               |
| `previewRedeem(s)`  | `previewRedemption(s, true)` after the vault's instant redemption fee                  |
| `assetsUpdatedOn()` | Read from the vault: when its NAV report was last updated                              |

Active NAV is therefore the lagged redemption value, and an immediate redemption pays less than
`valueOf` whenever the instant fee is above the withdrawal fee.

`deposit` and `depositHeld` require a NAV report that is set, not in the future
(`InvalidNavTimestamp`), and no older than `maxNavAge` (`StaleNav`). `isFeeValuationFresh` returns
false under the same conditions. Exits have no age check, so a late report cannot freeze them.

A deposit approves the vault for exactly `assets`, credits the measured increase in the engine's
receipt tokens, and reverts unless that increase is nonzero (`NoVenueSharesReceived`) and the vault
used the whole approval (`UnexpectedAllowance`).

## Immediate exits

`redeem` calls the vault's `instantRedeem` with the EarnVault's receiver. It requires the engine's
receipt tokens to fall by exactly the requested shares (`UnexpectedVenueSharesBurned`), reports the
receiver's measured base-asset increase, and reverts below the caller's minimum
(`InsufficientAssetsReceived`). The vault reverts an instant redemption it cannot pay in full from
idle cash; there is no partial fill.

## Queued exits

The vault adds a queued redemption to a total for its claim date and receiver. It returns no request
ID and has no way to return queued shares. The engine therefore gives every request its own
receiver:

1. `requestRedeem(engineShares, requestData)` requires empty `requestData`
   (`UnexpectedRequestData`) and nonzero shares that fit 128 bits (`InvalidEngineShares`).
2. It deploys a new `UpshiftRedeemReceiver` proxy. The request ID is that address, left-padded to 32
   bytes.
3. It approves the vault for exactly the shares and calls the vault's `requestRedeem` with the new
   receiver. The engine's receipt tokens must fall by exactly the shares, the approval must be used
   in full, and the vault's queued total for that date and receiver must equal the shares
   (`UnexpectedQueuedShares`).
4. It stores the claim as `Open` with the vault's claim date and emits
   `RedeemRequested(requestId, engineShares, claimableEpoch)`.

`getClaim(requestId)` returns the status, receiver, queued shares, and claim date.

### Settlement

The vault prices a queued redemption when it is claimed, not when it is requested, so the holder
carries the vault's gains, losses, and withdrawal fee until the claim.

`settleRedeem(requestId)` is permissionless, because the payout can only reach the receiver the
EarnVault stored at request time. For an `Open` claim (`ClaimNotOpen` otherwise) it:

1. calls the vault's `claim` for the stored date and receiver when the vault still shows queued
   shares for them, and requires none to remain; when the vault's operator has already paid the
   receiver, this step is skipped;
2. marks the claim `Settled`;
3. sweeps the receiver's whole base-asset balance to the EarnVault and measures the EarnVault's
   increase; and
4. calls `EarnVault.finalizeRedeem` with that measured amount, which may be zero.

If any step reverts, the call reverts and the claim stays `Open`. The vault refuses a claim before
its claim date and while its withdrawals are paused. Nothing settles a request by itself: an
offchain caller must call `settleRedeem` once the claim date passes.

### No cancellation

`cancelRedeem` always reverts with `CancelUnsupported`. On an EarnVault using this engine:

- `EarnVault.cancelRedeem` reverts for the requester and for the async janitor;
- a request closes only through `settleRedeem`; and
- `migrateEngine` is unavailable while any request is open, so a migration waits for every open
  request's claim date and settlement.

## Authorities

The engine is only as safe as its vault. The vault's owner and operator report its NAV, set its
fees and redemption lag, pause deposits and withdrawals, deploy its capital, and maintain its
sender whitelist; none of these are bounded by the engine. Engine ownership carries only
`setMaxNavAge`.

When the vault enforces a sender whitelist, the engine must be on it: the vault's deposit, instant
redemption, redemption request, and claim all check their caller. Receivers are not callers and
need no entry.

## Failure modes

| Condition                                                                 | Effect                                                                                                                                       |
| ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| NAV report older than `maxNavAge`                                         | Deposits revert and fee valuation is stale; exits are unaffected.                                                                            |
| Vault holds too little idle cash                                          | Immediate redemptions revert. New queued requests are unaffected.                                                                            |
| Vault withdrawals paused                                                  | Immediate redemptions, new requests, and claims revert. Open requests stay open and cannot be cancelled.                                     |
| Vault has no redemption lag, or the request is above its withdrawal limit | New requests revert in the vault.                                                                                                            |
| Engine removed from the vault's sender whitelist                          | Deposits, immediate redemptions, new requests, and claims revert. An open request settles only after the vault's operator pays its receiver. |
| Stored EarnVault receiver cannot receive the payout                       | `settleRedeem` reverts and the claim stays `Open`; nothing can redirect it.                                                                  |
| Base asset sent to the engine                                             | Not recoverable: no function moves it.                                                                                                       |
| Base asset sent to a receiver                                             | Before settlement it is paid to that request. After settlement it is not recoverable.                                                        |
| Third party queues shares for a request's receiver                        | For the request's claim date they are claimed with it and paid to that request. For another date the engine never claims them.               |
| Receipt tokens sent to the engine                                         | Raw surplus the EarnVault quarantines ([accounting anchors](../architecture/system.md#accounting-anchors)).                                  |

## Deployment

The engine has no factory. Deploy it unbound with the vault, a setup owner, `maxNavAge`, a name, and
a symbol; deploy the EarnVault with it as an existing engine; then the setup owner calls
`initializeEarnVault(earnVault, finalOwner)`, which requires the EarnVault's asset to equal the
vault's. Add the engine to the vault's sender whitelist before opening deposits when the vault
enforces one. Set `maxNavAge` above the vault's NAV reporting interval, or deposits stop between
reports.

## Tests

Foundry, in
[`UpshiftEngine.t.sol`](../../../test/earn/engines/upshift/UpshiftEngine.t.sol): capabilities,
binding, access, deposit custody, valuation net of fees, NAV freshness, whitelist gating, immediate
redemption, the queued request, settlement at the claim-time price after a gain and after a loss,
settlement after the vault's operator already paid, blocked receivers, paused withdrawals,
third-party top-ups, and a custody-conservation fuzz test against a real EarnVault.

The suite runs against
[`MockUpshiftVault`](../../../test/earn/helpers/UpshiftEngineMocks.sol), a fixture that follows the
vault's queue, fee, pause, and whitelist rules. It is not the vault's bytecode and proves nothing
about release compatibility.
