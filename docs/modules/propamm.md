# PropAMM engine

This page owns the `propamm` engine kind: `PropAMMEngine`, its pricing and freshness rules,
deployment, authorities, failure modes, tests, and the pinned DirectPropAMM fixture that both this
engine's tests and the [Zone router](zone-router.md)'s par conversion use. The shared engine
contract is in [yield engines](../integrations/engines.md).

`PropAMMEngine` is experimental: it is outside the completed [audits](../audit/README.md)
([review scope](#review-scope)), and no hosted PropAMM profile exists.

## Contract

[`PropAMMEngine`](../../src/engines/propamm/PropAMMEngine.sol) puts one fixed Tempo DirectPropAMM
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
re-reads the oracle afterwards and reverts `QuoteMismatch` if either changed.

### Freshness

For deposits and contributions, the EarnVault checkpoints fees before calling the engine. The engine
then validates the pinned oracle and price and reverts `InvalidOracle` when the report is older than
its own `maxOracleAge` (exactly the maximum age is accepted), before pulling assets or approving the
pool; the whole transaction, including the fee checkpoint, rolls back. Migration into this engine
uses the same check. The pool may accept older reports; its longer window never permits stale entry
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

1. Deploy and source-verify `src/engines/propamm/PropAMMEngine.sol:PropAMMEngine` from the current
   repository. An existing deployment does not gain new behavior when the repository changes;
   replace it rather than editing a record.
2. Write a profile whose engine is `{ "kind": "propamm", "address": "0x…" }`
   ([profile schema](../../profiles/README.md#schema)) with explicit fees, migration mode, owner, and
   any protected access, and review `pnpm earn plan`.
3. Have the pool administrators admit the engine as taker and recipient with recipient resolution
   back to itself, refresh the oracle, and fund inventory for the intended flows.
4. Run `pnpm earn deploy`, then `pnpm earn verify` ([lifecycle](../operations/deployment.md)). The
   plan is `deploy-core` then `bind-core`; when another account owns the engine, `bind-core` emits
   the engine-owner handoff (`initializeEarnVault(earnVault, finalOwner)`), after which the same
   command resumes.

Inspection ([`propamm.ts`](../../deployments/modules/engines/propamm.ts)) checks the token and
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
| Earn controls, fees, and permitted migration                  | EarnVault operator                    |
| Protected EarnShare membership                                | Existing TIP-403 policy administrator |
| Private token enablement (with a Zone)                        | Zone administrator                    |

## Failure modes

| Signal or error                                                                               | Response                                                                                                                      |
| --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Fee valuation stale; deposit reverts `InvalidOracle`                                          | Restore oracle publication; deposits and contributions stay blocked until then                                                |
| Pool paused, admission revoked, or recipient redirected (`InvalidConfiguration` on any trade) | Confirm administrator intent before restoring access; exits are blocked too                                                   |
| Low base-token inventory                                                                      | Replenish before deposits                                                                                                     |
| Low quote-token inventory                                                                     | Replenish before exits; previews are not liquidity guarantees                                                                 |
| Pool oracle changed or its decimals changed (`InvalidOracle` on every path)                   | Restore the pinned oracle; migration away needs a working exit, so prepare a replacement engine while the old one still exits |
| TIP-403 transfer denied                                                                       | Repair the denied path with its policy administrator                                                                          |
| Source or runtime verification changed                                                        | Stop release promotion and investigate provenance                                                                             |

Choose inventory thresholds from expected deposit and redemption sizes, and monitor both freshness
windows. Earn's guardian pause cannot unpause the pool, change its permissions, or create exit
liquidity, and there is no async fallback or privileged sweep. Never bypass user output bounds to
force an exit.

## Tests

```bash
forge test --match-path 'test/engines/propamm/*'
pnpm --filter @tempoxyz/earn abis:check
pnpm e2e:local -- --variant propamm --all
```

Foundry (`PropAMMEngine.t.sol`, and `PropAMMIntegration.t.sol` against the pinned pool) covers
future and zero prices, oracle replacement, fee-on-transfer tokens, reentrancy and mid-trade reads,
decimal configurations, the two freshness windows, rounding credit, donations and quarantined
surplus, migration and its rollback, illiquidity, revoked admission, pause and recipient blocks,
price-anchor discontinuity, and repeated tiny round trips.

The `propamm` local variant runs every shared E2E case its capabilities allow over the pinned pool,
a disposable 6-decimal base token, an always-fresh oracle, and a recipient registry
([localnet PropAMM fixtures](../development/localnet.md#propamm-fixtures)). Its engine
(`maxOracleAge` one day, route identifier `1`) belongs to a separate setup owner, so every local
PropAMM stack exercises the `bind-core` handoff and resumes unchanged. The always-fresh oracle does
not exercise stale-rate economics, which stay in Foundry. Unit tests cover interrupted-broadcast
recovery and the handoff record check
([`reconcile.test.ts`](../../deployments/core/reconcile.test.ts)) and paused-pool readiness
([`propamm.test.ts`](../../deployments/modules/engines/propamm.test.ts)).

`viem/tempo` has no PropAMM provisioning or route-aware quotes; E2E and the app's deposit preview
read them through the engine definition and the generated ABIs in `@tempoxyz/earn/abis`
([deposit previews](../development/app-browser.md#public-transaction-preparation)).

### Pinned DirectPropAMM fixture

Contract tests and localnet deploy `DirectPropAMM` from the committed
[`test/fixtures/propamm/DirectPropAMM.json`](../../test/fixtures/propamm/DirectPropAMM.json), which
holds only its ABI, creation bytecode, and runtime bytecode from an unmodified solc `0.8.30` build.
Building and testing Earn never needs the private PropAMM source repository.
[`source.json`](../../test/fixtures/propamm/source.json) records the repository, full commit,
contract, and compiler of that build.

To move the pin, change `commit` in `source.json` and regenerate the fixture with
[`update.sh`](../../test/fixtures/propamm/update.sh), which needs Git, Foundry, `jq`, and read
access to the private repository:

```bash
test/fixtures/propamm/update.sh                       # clone the pinned commit with your Git credentials
test/fixtures/propamm/update.sh ../propAMM            # or build a clean checkout already at that commit
test/fixtures/propamm/update.sh --check [../propAMM]  # fail on any difference, rewriting nothing
```

The `PropAMM fixture` job in the Verify workflow runs the `--check` form for same-repository pull
requests and `main`. A fork pull request that leaves `test/fixtures/propamm/` unchanged skips the
rebuild; one that changes it fails until a maintainer re-verifies it from a branch in this
repository ([CI](../development.md#continuous-integration)).

## Review scope

`PropAMMEngine` has engineering review and automated coverage, not an independent audit or
production approval. Review it together with the pinned DirectPropAMM execution behavior, oracle,
recipient registry, and the actual token implementations; production configuration and
independent sign-off are outside local CI.

Preserve one-vault custody, exact balance-delta accounting, zero residual pool allowances, pinned
oracle and scale consistency, same-price settlement checks, reentrancy guards (including
`ReadDuringSettlement` for valuation reads mid-trade), and the absence of a privileged sweep.

External administrators can stop execution by pausing, revoking admission, redirecting recipients,
changing the oracle, or removing inventory. Freshness says nothing about economic price correctness
or asset redeemability, and a source match establishes code identity, not economic safety. Inspect
the oracle's publication and authorization model, the pool's price-deviation settings, token
transfer behavior, and the chain's live policy, and record the reviewed external release,
configuration, outstanding findings, and approver in the deployment's operational evidence.
