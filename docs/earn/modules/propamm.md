# PropAMM engine

This page owns the `propamm` engine kind: `PropAMMEngine`, its pricing and freshness rules,
deployment, authorities, failure modes, tests, and the pinned DirectPropAMM fixture that both this
engine's tests and the [Zone router](zone-router.md)'s par conversion use. It also owns
`ManagedPropAMMEngine`, the same engine over one pair of a [managed pool](#managed-pools), which is
not deployed. The shared engine
contract is in [yield engines](../integrations/engines.md).

`PropAMMEngine` is experimental and outside the completed [audits](../audit/README.md#scope).

## Contract

[`PropAMMEngine`](../../../src/earn/engines/propamm/PropAMMEngine.sol) puts one fixed Tempo DirectPropAMM
pool behind the persistent EarnVault and EarnShare. The engine holds the pool's base token directly
(not LP shares); its `asset` is the pool's quote token. Deposits buy the base token, redemptions sell
an exact base quantity, and exact withdrawals sell enough base to deliver the requested quote
amount. Exits follow the normal measured-balance
[sequence](../architecture/flows.md#direct-public-redemption-and-exact-withdrawal).

The constructor `PropAMMEngine(pool, owner, maxOracleAge, customerId)` reads the base token, quote
token, and oracle from the pool and fixes them with `maxOracleAge` and `customerId` (the pool route
that carries the engine's rounding credit). It reverts `InvalidConfiguration` unless the pool, both
tokens, and the oracle have code, the tokens differ, `maxOracleAge` and `customerId` are nonzero,
and the base-token decimals and the price-scale exponent `baseDecimals + oracleDecimals -
quoteDecimals` each fit in 0–77. Engine shares use the base token's decimals (`shareScale`), and
valuation divides by `priceScale = 10 ** exponent`. The oracle address and its decimals are pinned;
a pool oracle change is never adopted.

Beyond the shared engine contract it exposes `baseToken`, `pool`, `priceOracle`, `maxOracleAge`,
`priceScale`, `customerId`, `oracleObservationTime`, and `liquidityStatus()`, which returns
`(paused, admitted, idleCash, venueCash, venueBase)`: the pool pause flag, whether the pool admits
the engine as taker and recipient and resolves it to itself, and the quote balance held by the
engine and the quote and base inventory held by the pool. Onchain metadata is `PropAMM Engine` /
`propAMM-engine`, so EarnFactory names the EarnShare `PropAMM Engine (Earn)` / `propAMM-engineE`. A
stack's `contracts.venue` is the base token; `engine.pool()` is the pool.

Capabilities: immediate redeem with a bound, exact withdrawal, and fee valuation. There is no in-kind
entry or async redemption, the engine has no setters for its venue bindings, and it has no dust
sweep. Binding (`initializeEarnVault`) also requires the EarnVault's asset to be the quote token.

### Pricing and rounding credit

`totalAssets`, `valueOf`, and `previewRedeem` value base tokens at the oracle price rounded down.
The pool keeps a rounding credit per taker, recipient, and route; each trade adds its unpaid
remainder and pays whole units once they accrue. Those valuations omit the credit, so a redemption
can pay a few quote units more than its preview, depending on earlier trades on the engine's route.
`previewWithdraw` and the pool's route quotes (`quoteExactInputFor`, `quoteExactOutputFor`) include
it. Every trade is executed at the price and observation time read at its start, and the engine
re-reads the oracle afterwards and reverts `QuoteMismatch` if either changed. Each trade's pool trade
ID is the block number above a count of the engine's trades in that transaction, so IDs label the
pool's `TradeExecuted` events and are distinct within a transaction, not across transactions.

### Freshness

For deposits and contributions, the EarnVault checkpoints fees before calling the engine. The engine
then validates the pinned oracle and price and reverts `InvalidOracle` when the report is older than
its own `maxOracleAge` (exactly the maximum age is accepted), before pulling assets or approving the
pool; the whole transaction, including the fee checkpoint, rolls back.
The pool may accept older reports; its longer window never permits stale entry
through the engine, which keeps a new depositor from paying for pre-entry yield after a fresh report.
`isFeeValuationFresh()` applies the same age.

The engine's age check does not apply to exits. Redemption and exact withdrawal remain subject to the
pinned-oracle and price validity checks and to the pool's own freshness, pause, inventory,
admission, and token policy.

## Deployment

No PropAMM engine factory exists, and the lifecycle does not provision the token, oracle, or pool.
Before any hosted transaction, record the chain, quote asset, base token, pool, oracle, setup owner,
final engine owner, EarnVault operator, maximum oracle age, and route identifier. Confirm the token
and oracle decimals are supported and that the pool's base and quote direction matches them, and
review the pool's token policy and recipient registry, not just its address.

1. Deploy and source-verify `src/earn/engines/propamm/PropAMMEngine.sol:PropAMMEngine` from the current
   repository. An existing deployment does not gain new behavior when the repository changes;
   replace it rather than editing a record.
2. Write a profile whose engine is `{ "kind": "propamm", "address": "0x…" }`
   ([profile schema](../../../profiles/README.md#schema)) with explicit fees, owner, and
   any protected access, and review `pnpm earn plan`.
3. Have the pool administrators admit the engine as taker and recipient with recipient resolution
   back to itself, refresh the oracle, and fund inventory for the intended flows.
4. Run `pnpm earn deploy`, then `pnpm earn verify` ([lifecycle](../../deployment/deployment.md)). The
   plan is `deploy-core` then `bind-core`; when another account owns the engine, `bind-core` emits
   the engine-owner handoff (`initializeEarnVault(earnVault, finalOwner)`), after which the same
   command resumes.

Inspection ([`propamm.ts`](../../../deployments/modules/earn/engines/propamm.ts)) checks the token and
oracle bindings against the live pool, runtime code, decimals and scales, nonzero oracle windows and
route identifier, and the required ERC-165 interfaces. `pnpm earn deploy` preflight additionally
requires an unpaused pool, taker and recipient admission, unredirected recipient resolution, and
fresh fee valuation; `verify` reports the same as deposit `readiness` without failing, so a pause
or stale report does not invalidate a correctly deployed stack, and it warns when the pool's
freshness window differs from the engine's. Readiness is not a trade simulation: a shorter pool
window, the pool's deviation guard, inventory, or token policy can still prevent execution, so
simulate each complete transaction before signing.

| Responsibility                                                | Authority                             |
| ------------------------------------------------------------- | ------------------------------------- |
| Oracle publication and cadence                                | External oracle administrator         |
| Pool admission, pause, inventory, and execution configuration | External pool administrators          |
| Engine binding and final-owner transfer                       | Engine setup owner                    |
| Earn controls and fees                                        | EarnVault operator                    |
| Protected EarnShare membership                                | Existing TIP-403 policy administrator |
| Private token enablement (with a Zone)                        | Zone administrator                    |

## Failure modes

| Signal or error                                                                                                                                                   | Response                                                                       |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Fee valuation stale; deposit reverts `InvalidOracle`                                                                                                              | Restore oracle publication; deposits and contributions stay blocked until then |
| Pool paused or admission revoked (the pool's `Paused`, `TakerNotAllowed`, or `RecipientNotAllowed` on any trade); recipient redirected (a measured-balance check) | Confirm administrator intent before restoring access; exits are blocked too    |
| Low base-token inventory                                                                                                                                          | Replenish before deposits                                                      |
| Low quote-token inventory                                                                                                                                         | Replenish before exits; previews are not liquidity guarantees                  |
| Pool oracle changed or its decimals changed (`InvalidOracle` on every path)                                                                                       | Restore the pinned oracle                                                      |
| TIP-403 transfer denied                                                                                                                                           | Repair the denied path with its policy administrator                           |
| Source or runtime verification changed                                                                                                                            | Stop release promotion and investigate provenance                              |

Choose inventory thresholds from expected deposit and redemption sizes, and monitor both freshness
windows. Earn's guardian pause cannot unpause the pool, change its permissions, or create exit
liquidity, and there is no async fallback or privileged sweep. Never bypass user output bounds to
force an exit.

## Managed pools

[`ManagedPropAMMEngine`](../../../src/earn/engines/propamm/ManagedPropAMMEngine.sol) is the counterpart of
`PropAMMEngine` for a `ManagedDirectPropAMM`, one pool that holds many pairs. It is **not deployed**:
it has no reviewed release, no profile and no registered engine kind, and localnet and E2E do not
provision it. It is experimental and outside the completed [audits](../audit/README.md#scope).

Everything on this page about `PropAMMEngine` holds for it (custody, accounting, rounding,
[pricing](#pricing-and-rounding-credit), [freshness](#freshness), capabilities, events, errors, and
the absence of setters and of a sweep) except where the pool differs:

| `PropAMMEngine`                                                  | `ManagedPropAMMEngine`                                                                 |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Bound to one pool, which is one pair                             | Bound to one pool and one of its pairs: immutable `pairIndex`                          |
| Reads its tokens and oracle from the pool                        | Takes its tokens as arguments and requires the pair to trade exactly them              |
| Trades under the pool's one taker list                           | Trades under an immutable `sponsorId`: 0 for the pair's home list, or a sponsor's list |
| Names itself as the swap recipient                               | Names no recipient: the pool pays a swap's output to its caller, the engine            |
| Route credit keyed by taker, recipient, and route                | Route credit keyed by pair, taker, and route                                           |
| Admitted when taker and recipient are allowed and not redirected | Admitted when the pair's access check passes for the engine and the pair has no hook   |
| Onchain metadata `PropAMM Engine` / `propAMM-engine`             | `Managed PropAMM Engine` / `managed-propAMM-engine`                                    |

The constructor is
`ManagedPropAMMEngine(pool, pairIndex, sponsorId, asset, baseToken, owner, maxOracleAge, customerId)`.
It reads `pool.pair(pairIndex)` and reverts `InvalidConfiguration` unless that pair's base is
`baseToken` and its quote is `asset`. An unknown or removed pair reads all zero, so it matches no
token; the pool never reuses a pair's index or changes a pair's tokens. On top of the single-pair
engine's checks, the pair's recorded decimals and price scale must equal the ones the tokens and
the oracle report, and the pair must have no hook. `sponsorId` is not validated at construction:
access is checked on every trade.

A pair's access mode is `Closed` (nobody trades), `Listed` (the accounts on a list the pair admits)
or `Open` (every account the pool does not deny). Before any trade the engine requires the pool to
be unpaused and `takerAllowed(pairIndex, engine, sponsorId)`, and reverts `InvalidConfiguration`
otherwise, so a closed pair, a denied engine, the pool-wide pause and, on a `Listed` pair, an
unlisted engine or a disabled, unregistered or unadmitted sponsor each revert the whole deposit,
redemption or exact withdrawal with nothing moved. An `Open` pair reads no list, so there the
sponsor's state stops nothing: only the pause, closing the pair and the deny list do. Valuation does
not depend on access. After a pair is removed its oracle reads zero,
so valuation and deposits revert `InvalidOracle` and exits revert `InvalidConfiguration`.

Every swap is checked by the engine's own measured balances, as in the single-pair engine: the
input token falls by exactly the amount sold, and the output the engine reports is its measured
increase. A pool that paid another account would fail those checks and revert.

**Hooks.** A managed pair can carry a hook that charges an input-token fee of up to 10% on quotes
and swaps. The engine values its base tokens at the oracle price, so a fee would make
`totalAssets` and `previewRedeem` overstate what an exit pays. The engine therefore takes no
deposit through a pair with a hook: construction and every deposit revert `InvalidConfiguration`,
and `liquidityStatus().admitted` is false while one is installed. The pool operator can install a
hook only while the pair is `Closed`.

The hook rule is a deposit admission check and never an exit restriction. If a hook is installed
after holders entered, redemptions and exact withdrawals still run once the pair reopens, at the
pool's fee-inclusive price: a redemption pays less than `previewRedeem` and reverts below the
caller's `minAssets`, and an exact withdrawal burns more shares than the oracle price implies,
within `previewWithdraw`'s quote and the vault's share limit. While the hook stays, `totalAssets`
and `previewRedeem` overstate exit proceeds by the fee, so `isFeeValuationFresh` is false and the
vault accrues no fee on that valuation, and a vault on a hooked pair should be wound down or the
hook removed. The vault refuses an exact withdrawal that burns all backing for less than its
valuation (`ResidualBacking`), which a hook's fee makes the last one do: the last holder leaves by
redemption. A hook's swap callbacks run inside the engine's settlement, under
the engine's and the vault's reentrancy guards and the same measured-balance checks.

`liquidityStatus()` returns the same tuple; `venueCash` and `venueBase` are the pool's whole
balances, which every pair trading that token shares, so another pair's trades change them.

The pool operator has more ways to stop execution than a single-pair pool's administrators: the
pool-wide pause, the pair's access mode, the home list, the deny list, the sponsor's registration,
admission to the pair and its list (a sponsor's own admin manages that list), a hook, the pair's
oracle, and the pair's removal. None can move the engine's holdings or change which tokens it
trades.

Removal is the one that cannot be undone. The pool never reuses a pair index and the engine's
`pairIndex` is immutable, so once its pair is removed the engine can never sell its base tokens:
every exit reverts, and so does `migrateEngine`, which redeems from the old engine first. The engine
has no sweep and no way to name another pair, so its holdings are stranded for good. Closing the
pair stops trading and can be reversed; the pool operator must never remove a pair an engine holds
base tokens on.

Deployment follows the [steps above](#deployment) by hand, with the pair index, sponsor id and both
token addresses added to the recorded inputs, and the pool operator admitting the engine on the
pair under that sponsor. No profile can name the engine until its kind is registered: the
[engine definition](../../../deployments/modules/earn/engines/managed-propamm.ts) and its inspection
(pair tokens, oracle, decimals and scales, hook, and the access outcome as deposit readiness) exist
beside the registry, not in it ([adding an engine](../integrations/engines.md#recipe) lists what
registration needs). Until then tooling refuses a vault whose engine is a managed one: the
single-pair kind recognizes only an engine whose pool names its own base token, which a managed pool
does not, so the engine resolves to no kind rather than to the single-pair adapter.

## Tests

```bash
forge test --match-path 'test/earn/engines/propamm/*'
pnpm --filter @tempoxyz/contracts abis:check
pnpm e2e:local -- --variant propamm --all
```

Foundry (`PropAMMEngine.t.sol`, and `PropAMMIntegration.t.sol` against the pinned pool) covers
future and zero prices, oracle replacement, fee-on-transfer tokens, reentrancy and mid-trade reads,
decimal configurations, the two freshness windows, rounding credit, donations and quarantined
surplus, illiquidity, revoked admission, pause and recipient blocks,
price-anchor discontinuity, and repeated tiny round trips.

`ManagedPropAMMEngine.t.sol` and `ManagedPropAMMIntegration.t.sol`, the second against the pinned
managed pool, repeat those cases and add the constructor's pair checks (unknown, removed, other
tokens, reversed tokens, differing decimals, a hook), swaps naming the engine's pair and sponsor on
a pool with other pairs, an output paid to another account, and each refusal reverting every flow
with nothing moved: a closed pair, an unlisted or denied engine, sponsor refusals, the pool pause,
and a removed pair. A hook installed later blocks deposits only: against the pinned pool with a 1%
fee hook, an exact withdrawal and a redemption settle at the pool's fee-inclusive quotes, a
redemption demanding the oracle value reverts, fee valuation reads stale, and an exact withdrawal
of all backing reverts `ResidualBacking` while the redemption exits.
[`managed-propamm.test.ts`](../../../deployments/modules/earn/engines/managed-propamm.test.ts) covers
the inspection. No local variant or E2E case runs the managed engine.

The `propamm` local variant runs every shared E2E case its capabilities allow over the pinned pool,
a disposable 6-decimal base token, an always-fresh oracle, and a recipient registry
([localnet PropAMM fixtures](../../development/localnet.md#propamm-fixtures)). Its engine
(`maxOracleAge` one day, route identifier `1`) belongs to a separate setup owner, so every local
PropAMM stack exercises the `bind-core` handoff and resumes unchanged. The always-fresh oracle does
not exercise stale-rate economics, which stay in Foundry. Unit tests cover interrupted-broadcast
recovery and the handoff record check
([`reconcile.test.ts`](../../../deployments/core/reconcile.test.ts)) and paused-pool readiness
([`propamm.test.ts`](../../../deployments/modules/earn/engines/propamm.test.ts)).

`viem/tempo` has no PropAMM provisioning or route-aware quotes; E2E reads
them through the engine definition and the generated ABIs in `@tempoxyz/contracts/abis`.

### Pinned DirectPropAMM fixture

Contract tests and localnet deploy `DirectPropAMM` from the committed
[`test/earn/fixtures/propamm/DirectPropAMM.json`](../../../test/earn/fixtures/propamm/DirectPropAMM.json), which
holds only its ABI, creation bytecode, and runtime bytecode from a solc `0.8.30` build of the
unmodified source, the compiler the deployed pool was built with: `update.sh` passes that version to
Forge in place of the source repository's default compiler.
Building and testing Earn never needs the PropAMM source repository.
[`source.json`](../../../test/earn/fixtures/propamm/source.json) records the repository, full commit,
contract, and compiler of that build.

The managed engine's tests deploy `ManagedDirectPropAMM` the same way, from
[`ManagedDirectPropAMM.json`](../../../test/earn/fixtures/propamm/ManagedDirectPropAMM.json), built from
the commit [`managed.source.json`](../../../test/earn/fixtures/propamm/managed.source.json) records. The
two pins move independently; pass `--source managed.source.json` to `update.sh` to rebuild or check
that one. `update.sh` fixes each source file's contract by the file's name, so a source file cannot
be edited to rebuild and compare the other fixture.

To move the pin, change `commit` in `source.json` and regenerate the fixture with
[`update.sh`](../../../test/earn/fixtures/propamm/update.sh), which needs Git, Foundry, and `jq`; the source
repository is public, so no GitHub credentials are needed:

```bash
test/earn/fixtures/propamm/update.sh                             # fetch the pinned commit anonymously over HTTPS
test/earn/fixtures/propamm/update.sh ../tempo-propamm            # or build a clean checkout already at that commit
test/earn/fixtures/propamm/update.sh --check [../tempo-propamm]  # fail on any difference, rewriting nothing
test/earn/fixtures/propamm/update.sh --source managed.source.json [--check] [../tempo-propamm]
```

The `PropAMM fixture` job in the Verify workflow runs the `--check` form of both, without a token, for every
pull request, including those from forks, and `main`
([CI](../../development/README.md#continuous-integration)).

## Review

Review `PropAMMEngine` together with the pinned DirectPropAMM execution behavior, oracle,
recipient registry, and the actual token implementations; production configuration and
independent sign-off are outside local CI. Review `ManagedPropAMMEngine` the same way against the
pinned ManagedDirectPropAMM, with the pair's access configuration, its sponsor and the hook rule in
place of the recipient registry.

Preserve one-vault custody, exact balance-delta accounting, at most one unit of standing pool allowance, pinned
oracle and scale consistency, same-price settlement checks, reentrancy guards (including
`ReadDuringSettlement` for valuation reads mid-trade), and the absence of a privileged sweep.

External administrators can stop execution by pausing, revoking admission, redirecting recipients,
changing the oracle, or removing inventory. Freshness says nothing about economic price correctness
or asset redeemability, and a source match establishes code identity, not economic safety. Inspect
the oracle's publication and authorization model, the pool's price-deviation settings, token
transfer behavior, and the chain's live policy, and record the reviewed external release,
configuration, outstanding findings, and approver in the deployment's operational evidence.
