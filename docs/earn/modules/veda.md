# Veda engine

This page owns the `veda` engine kind: `VedaEngine`, `VedaPeripheryRegistry`, and
`VedaForwardingSolver`, their valuation, immediate and queued exits, periphery rotation, request
data, deployment, authorities, and tests. The shared engine contract is in
[yield engines](../integrations/engines.md). The three contracts are in the Sigma Prime PropAMM &
Earn review and unchanged since ([audits](../audit/README.md)).

`VedaEngine` ([source](../../../earn/src/engines/veda/VedaEngine.sol)) holds BoringVault shares for one
EarnVault and drives the Teller, optional Queue, and Accountant that the BoringVault owner publishes.
Veda is an `IEarnEngine` backend, not a separate Earn deployment type: the Veda side delivers a
reviewed, unbound `VedaEngine`, and the profile lifecycle deploys the standard core around it. No
Earn deployment script deploys or administers BoringVault, Teller, Queue, Accountant,
RolesAuthority, or a Veda solver; only test fixtures stand in for them ([test stacks](#test-stacks)).
Veda source is externally owned and is not vendored here.

## Contracts

### VedaEngine

The BoringVault (`vault()`), periphery registry, and base asset are immutable; the EarnVault binding
is set once; `maxRateAge` is nonzero. Construction validates the registry's current tuple and emits
`VedaEngineInitialized`; rotations and freshness-policy changes emit `VedaPeripheryUpdated` and
`MaxRateAgeUpdated`.

The engine advertises `IEarnEngineRedeem`, `IEarnEngineExactWithdraw`, and
`IEarnEngineFeeValuation`, plus `IEarnEngineAsyncRedeem` only while its active Queue is nonzero. It
has no in-kind entry, so the EarnVault rejects a queued request before burning EarnShare when the
engine is immediate-only.

Its `Ownable2Step` owner can:

- activate the registry's latest tuple while EarnVault deposits are paused and the safe rate is
  within caller-supplied bounds (`syncVedaPeriphery`);
- change the nonzero `maxRateAge` while deposits are paused (`setMaxRateAge`);
- authorize or revoke forwarders (`setAuthorizedForwarder`);
- credit a tracked payout that another authorized Veda solver delivered directly, after verifying the
  Queue's solve event (`recoverExternalSettlement`); and
- sweep only unearmarked tokens (`sweepDust`): never BoringVault shares, never the base asset while
  any claim is unresolved, and never funds earmarked in `settled`.

A forwarder cannot redirect a payout, because every payout goes to the receiver the EarnVault stored
at request time, but an owner-authorized forwarder can credit `settled` from inert balance and
decouple payout from a real solve. The engine owner must therefore be a timelock or multisig, held
together with the EarnVault operator, the forwarding solver owner, and the Veda RolesAuthority admin.

### VedaPeripheryRegistry

[`VedaPeripheryRegistry`](../../../earn/src/engines/veda/VedaPeripheryRegistry.sol) is ownerless and
immutable to one BoringVault and base asset. Only the current `BoringVault.owner()` may publish a
Teller, optional Queue, and Accountant tuple (`setVedaPeriphery`) and bind the registry exactly once
to one engine (`bindEngine`). Teller and Accountant are required; a zero Queue selects
immediate-only operation. Publication checks that each module has code, the Teller reports the
BoringVault and proposed Accountant, a nonzero Queue reports the same two, and the Accountant
reports the BoringVault and base asset. It increments `version` without activating the tuple in the
engine, and may precede binding so the engine constructor can validate the initial tuple. Binding
requires an engine that points back to this registry, BoringVault, and base asset. The engine
cannot bind its EarnVault until the registry points back to it, and the binding cannot change.

### VedaForwardingSolver

[`VedaForwardingSolver`](../../../earn/src/engines/veda/VedaForwardingSolver.sol) combines the stock Veda
solve with Earn finalization. It is immutable to one stock solver, tracking Queue, Teller, and
engine. `solveAndForward(requestIds, coverDeficit)` is restricted to owner-authorized solvers
(`setAuthorizedSolver`). It reads each request from its Queue by ID, checks the engine recorded that
Queue for the ID, requires one output asset, measures the engine's balance across the stock solve,
and passes the IDs and measured delta to `forwardSolved`, which reverts `SolveUnderfunded` unless
the delta covers every request in the batch.

With `coverDeficit` true, the caller's whole base-asset allowance to the forwarder is the funding
bound for that solve: it is pulled, approved to the stock solver (which records the forwarder as
`solverOrigin`), and the unused part is refunded after the approval is cleared.
`DeficitFundingSettled` reports funded, used, and refunded amounts. With `coverDeficit` false the
caller's funds are not touched. Favorable solve surplus and any pre-existing forwarder balance stay
in the forwarder, and the owner's `rescue` sends them only to the owner-set `treasury`. The
forwarder must hold the stock solver's Veda permission itself; replacing the Queue, Teller, or stock
solver needs a new forwarder.

### Invariants

1. Veda settled assets remain earmarked and cannot be swept as dust.
2. Each registry is bound once to exactly one engine, and that engine cannot bind its EarnVault until
   the reciprocal binding is in place.

## Valuation and freshness

Valuation and exact withdrawals use the BoringVault's own `10 ** decimals()` share scale, which
`shareScale()` exposes so an empty EarnVault normalizes its first mint even when BoringVault and
EarnShare decimals differ. The Accountant rate is denominated in the base asset; do not assume a
fixed six-decimal share scale.

All valuation uses `getRateInQuoteSafe(baseAsset)`, and both immediate and queued exits pay only the
base asset. The first deposit, immediate exit, queued request, or cancellation in a transaction
checkpoints the safe rate in transient storage; a later operation in that transaction reverts
`RateChangedWithinTransaction` if the rate changed. Requests and cancellations also recheck the rate
after the Queue call, because moving existing BoringVault shares between the engine and the Queue
must not reprice the Accountant. The checkpoint clears at the end of the transaction, so an
unrelated transaction in the same block may use a newly posted rate.

Deposits and immediate exits use the Teller's permissioned `bulkDeposit` and `bulkWithdraw`, never
its public lock-enforcing paths. The bulk paths skip the Teller's per-holder `shareLockPeriod`, so
one user's deposit cannot freeze exits for every holder behind the shared engine address. The
transaction checkpoint replaces only the atomic-rate guard: it does not stop a user from entering
before a predictable Accountant update. A deployment without Veda's share lock accepts that
cross-transaction timing exposure and must govern or pause around discretionary rate updates.

New deposits require the Accountant's latest report to be no older than `maxRateAge`. The engine
reads `lastStrategistUpdateTimestamp()` (YieldStreaming Accountant) or, failing that,
`accountantState()`'s update timestamp (step-accounting `AccountantWithRateProviders`), exposes the
result as `accountantRateUpdatedAt()`, and fails closed before assets move on a missing, future,
expired, or unsupported timestamp (`InvalidRateTimestamp`, `StaleAccountantRate`,
`UnsupportedAccountantFreshness`). Activating a rotated Accountant applies the same check.
Contributions inherit it through `engine.deposit`; staleness never blocks
exits.

`isFeeValuationFresh()` applies the same timestamp and age, so an expired report defers fee
crystallization without blocking redemption, request, finalization, or cancellation
([accrual checkpoints](../architecture/fees.md#accrual-checkpoints)).

Choose `maxRateAge` from Veda's committed reporting cadence and maximum vesting duration. Too short
halts new deposits until Veda reports; too long weakens the stale-NAV protection.

## Immediate exits

Immediate redemption forwards the user's `minAssets` to the Teller, verifies the exact
BoringVault-share decrease, and returns the receiver's measured base-asset increase rather than the
Teller's return value. Exact withdrawal also verifies the engine's measured Teller delivery and the
receiver's exact increase. A dishonest return value, redirected payout, or fee-on-transfer
underdelivery reverts. Immediate exits fail when the Veda liquidity buffer is dry; offer a queued
request when the engine advertises it.

## Queued exits

Only a `BoringOnChainQueueWithTracking` with onchain tracking enabled is accepted; construction and
activation reject an untracked Queue (`QueueTrackingDisabled`). The generic request, finalization,
and cancellation sequence is in [flows](../architecture/flows.md#async-redemption). Veda adds:

1. **Request.** `engineData` is an ABI-encoded `VedaRedeemRequest`: `assetOut` (must be the base
   asset), `discountBps`, `secondsToDeadline`, and a nonzero absolute payout floor
   `minQueuedAssets`. The engine verifies its BoringVault shares decreased by exactly the request,
   reads the request back with `getOnChainWithdraw(requestId)`, checks its ID and engine-owned
   fields, requires the fixed `amountOfAssets` to meet `minQueuedAssets`, and stores the share and
   asset amounts. Any failure rolls back the whole request, including the EarnShare burn.
2. **Solve.** An authorized solver submits request IDs to `VedaForwardingSolver`; the stock solve,
   measured engine credit, and finalization to each stored receiver happen in one transaction. If a
   receiver cannot accept the payout, that request becomes claimable and stays earmarked until anyone
   calls `claimRedeem` successfully. An unsolved request cannot draw on another request's funds.
3. **Cancel.** The engine calls the originating Queue's `cancelOnChainWithdrawUsingRequestId`.
   Returned shares re-enter at the current price under the snapshotted fee configuration.

Each claim records its originating Queue, so a later rotation or Queue removal cannot strand its
cancellation or settlement, and the engine rejects any reused request ID (`DuplicateRequest`),
because Queue nonces are deployment-local.

Veda solver authority is account-scoped, so another authorized Veda solver can call the stock solver
directly and have the Queue pay the engine without `forwardSolved`. `unresolvedClaimCount` counts
open and claimable requests; while it is nonzero the base asset cannot be swept. After verifying the
Queue's solve event, the owner calls `recoverExternalSettlement` with the affected IDs; the engine
derives their fixed payout total, bounds the credit by its real balance, and finalizes normally.
This recovery does not relax the deployment requirement that every solver operator call
`VedaForwardingSolver` and that no other principal keep direct stock-solver authority.

### Build a queued request

Quote the EarnShare-to-engine-share conversion, call the active Queue's `previewAssetsOut`, and
apply the user's tolerated quote drift to derive `minQueuedAssets`. `viem/tempo` has no high-level
actions for the queued pair, so build both calls against `Abis.earnVault`:

```ts
import { encodeAbiParameters, encodeFunctionData, parseAbiParameters, parseEventLogs } from 'viem'
import { sendTransaction, waitForTransactionReceipt } from 'viem/actions'
import { Abis } from 'viem/tempo'
import { vedaBoringQueueAbi } from '@tempoxyz/earn/abis'

const shareAmount = 50_000_000n
const engineShares = await client.readContract({
  abi: Abis.earnVault,
  address: earnVault,
  args: [shareAmount],
  functionName: 'convertToEngineShares',
})
const discountBps = 10
const quotedAssets = await client.readContract({
  abi: vedaBoringQueueAbi,
  address: vedaQueue,
  args: [vault.assetToken, engineShares, discountBps],
  functionName: 'previewAssetsOut',
})
const minQueuedAssets = (quotedAssets * 9_950n) / 10_000n // example: tolerate 50 bps quote drift

// VedaEngine request data: output asset, Queue discount, deadline, and absolute payout floor.
const engineData = encodeAbiParameters(
  parseAbiParameters(
    '(address assetOut, uint16 discountBps, uint24 secondsToDeadline, uint128 minQueuedAssets)',
  ),
  [{ assetOut: vault.assetToken, discountBps, secondsToDeadline: 259_200, minQueuedAssets }],
)

const hash = await sendTransaction(client, {
  calls: [
    {
      data: encodeFunctionData({
        abi: Abis.tip20,
        args: [earnVault, shareAmount],
        functionName: 'approve',
      }),
      to: vault.shareToken,
    },
    {
      data: encodeFunctionData({
        abi: Abis.earnVault,
        args: [shareAmount, engineData, account.address],
        functionName: 'requestRedeem',
      }),
      to: earnVault,
    },
  ],
})
const receipt = await waitForTransactionReceipt(client, { hash })
if (receipt.status !== 'success') throw new Error(`Transaction ${hash} reverted`)
const [request] = parseEventLogs({
  abi: Abis.earnVault,
  eventName: 'RedeemRequested',
  logs: receipt.logs,
})
// request.args.requestId identifies the claim from here on.
```

- `QueueUnavailable`: no Queue is active. Existing requests stay attached to their Queue.
- `ZeroMinimumQueuedAssets`: the request omitted the payout floor.
- `QueuedAssetsBelowMinimum`: the Queue fixed a payout below the floor; refresh the quote and ask the
  user to authorize a new request.
- `InvalidAsset`, malformed `engineData`, and Queue deadline or discount failures need corrected
  request data.

## Periphery rotation

The engine owner cannot choose addresses; it can only activate the registry's latest published
version while EarnVault deposits are paused. Immediate exits and existing queued claims stay
available throughout.

1. The current BoringVault owner publishes a Teller, optional Queue, and Accountant tuple.
2. The EarnVault operator pauses deposits.
3. The engine owner calls `syncVedaPeriphery(minRate, maxRate)`. The engine checks the wiring, Queue
   tracking when nonzero, base asset, report freshness, and that the safe rate lies within the bounds
   before activating the version.
4. New deposits, immediate exits, valuation, and requests use the new modules; a nonzero Queue
   enables new requests and a zero Queue disables them, and ERC-165 discovery follows.
5. Verify Accountant freshness, the new rate, and exits before resuming deposits.
6. Keep each old Queue and its solver path live until `openClaimsByQueue(queue)` reaches zero.

An immediate-only stack can add queued exits this way without replacing the registry, engine,
EarnVault, or EarnShare: Veda deploys a tracking Queue wired to the same BoringVault and Accountant,
grants the engine Queue request and ID-based cancellation, configures the stock solver and a
forwarder, and publishes the existing Teller with the new Queue.

Rotation changes periphery around the same BoringVault; it does not move EarnShare supply or engine
custody. Its checks catch mixed wiring and unexpected rate jumps;
they cannot show that implementation bytecode is benign, permissions sufficient, or future reports
honest. Those remain deployment-review responsibilities.

## Deployment

Pin the supported Veda release (commit or artifact hashes), compiler settings, and complete ABIs
before deployment; a compatible local fixture does not prove release compatibility. Stop at any
missing Veda key or approval.

1. Deploy the registry for the BoringVault and base asset.
2. The current BoringVault owner publishes the initial Teller, optional Queue, and Accountant.
3. Deploy the engine against the registry with its owner, `maxRateAge`, and nonempty metadata.
4. The BoringVault owner calls `bindEngine(engine)`.
5. Write a profile whose `engine` is `{ "kind": "veda", "address": "0x..." }`
   ([profile schema](../../../profiles/README.md#schema)) and run `pnpm earn deploy`. The lifecycle runs
   `deploy-core` and `bind-core` ([deployment](../../deployment/deployment.md)); `bind-core` calls
   `initializeEarnVault(earnVault, finalOwner)`, which reverts until the registry points back to the
   engine. When `DEPLOYER_PRIVATE_KEY` owns the unbound engine the lifecycle binds and transfers it
   atomically; otherwise it emits the engine-owner handoff.

Veda grants these capabilities through its RolesAuthority; Earn never broadcasts them:

| Principal            | Capability                                                                 | Checked by tooling    |
| -------------------- | -------------------------------------------------------------------------- | --------------------- |
| VedaEngine           | Teller `bulkDeposit` and `bulkWithdraw`                                    | Yes                   |
| VedaEngine           | Queue `requestOnChainWithdraw` and ID-based cancellation (queued mode)     | Yes                   |
| VedaForwardingSolver | Stock solver `boringRedeemSolve` for the exact tracked Queue (queued mode) | No; prove it with E2E |

Engine inspection ([`veda-inspection.ts`](../../../deployments/modules/earn/engines/veda-inspection.ts))
reads everything from the engine alone. `inspectVedaPeriphery` requires registry and engine to agree
on one tuple at the published version and point at each other, the Accountant to price the
BoringVault in the engine's asset, and the Teller capabilities above. `inspectVedaEngine` adds, in
queued mode, a tracking Queue and its capabilities, and in `ready` mode a fresh, nonzero rate and a
Teller accepting the base asset. `pnpm earn deploy` preflight and E2E acceptance run it in `ready`
mode; `pnpm earn verify` runs the bindings checks only. The hosted stack built from a Veda record reads the Teller, optional
Queue, Accountant, registry, and RolesAuthority into `contracts.periphery`, so
[rechecking a deployed profile](../../deployment/deployment.md#rechecking-deployed-profiles) fails on
broken wiring, a missing capability, an untracked Queue, or a stale report. Before enabling writes,
the app runs `inspectVedaPeriphery` and compares the periphery the engine reports with its catalog.

For queued mode, stop unless the reviewed release satisfies all of the following; do not accept an
event-only or untracked Queue:

```text
Queue is BoringOnChainQueueWithTracking
Queue.trackWithdrawsOnChain() == true
Queue.getOnChainWithdraw(requestId) returns the exact stored request
Queue.previewAssetsOut(assetOut, shares, discount) quotes the request-time fixed payout
Queue.cancelOnChainWithdrawUsingRequestId(requestId) is authorized for VedaEngine
VedaForwardingSolver is immutable to the exact Queue, Teller, stock solver, and VedaEngine
stock solver boringRedeemSolve accepts the supported request tuple, Teller, and coverDeficit flag
```

For each deficit-covering solve, the authorized solver approves an exact base-asset amount to the
forwarder immediately before `solveAndForward(requestIds, true)`; never leave a standing allowance.
Verify the refund and that both allowances return to zero.

Before committing the generated `deployment.json`, which does not replace the Veda release record,
confirm the engine is bound only to the new EarnVault, the registry and periphery are the reviewed
ones, the report is fresh, and the queued E2E case passes. For a queued release also confirm that
`openRedeemRequestCount()`, `unresolvedClaimCount()`, `openClaimsByQueue(queue)`, and
`settled(baseAsset)` return to zero after final delivery.

## Tests

- Foundry, under [`test/engines/veda/`](../../../earn/test/engines/veda/): accounting, async request,
  cancellation and settlement, fee freshness, periphery rotation, the forwarding solver, and an
  invariant suite. Rate mutation, periphery rotation, deficit funding, and external-solver recovery
  are covered only here.
- E2E: the `veda` local variant (`pnpm e2e:local -- --variant veda`) runs every shared case that the
  engine's capabilities allow, and [`veda-async-redeem`](../../../e2e/modules/veda/module.ts) (group
  `veda`, requires `asyncRedeem`) proves a below-floor rejection, cancellation, and a tracked
  solve-and-finalize through the forwarder.
- Unit: [`veda-inspection.test.ts`](../../../deployments/modules/earn/engines/veda-inspection.test.ts).

### Test stacks

Tempo-owned test stacks run over Veda-compatible fixtures
([`LocalVeda.sol`](../../../earn/script/local/contracts/LocalVeda.sol)); they prove nothing about release
compatibility and never stand in for a production venue. The fixture BoringVault doubles as a
RolesAuthority that allows every call, the test deployer owns the BoringVault (and so controls the
ownerless registry), the `VedaEngine`, the `VedaForwardingSolver`, and every fixture, and a hosted
fixture's base asset is PATHUSD. Which stacks exist and which the app lists is in
[hosted environments](../../deployment/hosted-environments.md).

The [test fixture bootstrap](../../../profiles/README.md#acceptance-and-test-fixtures) provisions the
fixtures with localnet's Veda steps and writes the engine into the profile; `pnpm earn deploy` then
deploys and binds the core. The fixture Accountant never reports, so a persistent fixture's engine
accepts a ten-year-old rate (one day on a disposable localnet). Hosted runs cover the shared public
cases and `veda-async-redeem`; their credentials are in
[E2E environments](../../deployment/e2e-environments.md#hosted-configuration).

## Stale reports

`StaleAccountantRate(updatedAt, currentTime, maxAge)` (`0x323a44c7`) blocks new deposits until a
fresh report lands; compare `accountantRateUpdatedAt()` with `maxRateAge()` to tell stale reporting
from wrong periphery bindings. A plain `updateExchangeRate()` call on a YieldStreaming Accountant
may not refresh the strategist timestamp; check it after the authorized reporting operation. Do not
fabricate a NAV report or relax the age threshold as a workaround; hand off to the Veda reporting
operator. Exits are not blocked by this guard but can still fail for venue reasons.
