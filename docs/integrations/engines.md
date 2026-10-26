# Yield engines

A yield engine is the contract that holds an Earn deployment's position in one venue. This page is for
integrators choosing an engine and for contributors adding one. It owns the shared engine contract,
installation checks, and the recipe for a new engine kind. Each kind is a module with its own page:

| Kind      | Engine          | Venue              | Provisioning                    | In-kind entry | Queued exits           | Page                                     |
| --------- | --------------- | ------------------ | ------------------------------- | ------------- | ---------------------- | ---------------------------------------- |
| `erc4626` | `ERC4626Engine` | ERC-4626 vault     | Factory from venue, or existing | Yes           | No                     | [ERC-4626](../modules/erc4626-engine.md) |
| `veda`    | `VedaEngine`    | BoringVault        | Existing engine                 | No            | When a Queue is active | [Veda](../modules/veda.md)               |
| `propamm` | `PropAMMEngine` | DirectPropAMM pool | Existing engine                 | No            | No                     | [PropAMM](../modules/propamm.md)         |

Every kind supports immediate redemption and exact withdrawal. Tooling, localnet, E2E, and the app
read each kind's properties from the shared
[engine registry](../../deployments/modules/engines/index.ts) instead of branching on the kind.

## Engine contract

[`IEarnEngine`](../../src/interfaces/engines/IEarnEngine.sol) defines single-client custody and
valuation:

- `asset` and the `earnVault` binding;
- `name` and `symbol`;
- `shareScale`, the nonzero raw unit of one whole venue share;
- `deposit(assets)`;
- `totalShares`, the raw venue-share custody, and `totalAssets`, its value; and
- `valueOf(engineShares)`.

Every engine serves exactly one EarnVault with the same immutable base asset, and:

- pulls base assets from the EarnVault and deposits them into its venue;
- holds the resulting venue shares itself;
- sends redeemed assets directly to the receiver the EarnVault selects; and
- never mints or burns EarnShare.

Its setup owner calls `initializeEarnVault(earnVault)` once, or
`initializeEarnVault(earnVault, finalOwner)` to bind and transfer ownership to the final owner in
one call. After binding, every mutating capability call is EarnVault-only, and the engine cannot
serve a second EarnVault. These calls and `Ownable2Step` ownership (`owner`, `pendingOwner`,
`transferOwnership`, `acceptOwnership`) are not in `IEarnEngine`, but deployment tooling calls them
on every engine through `earnEngineBindingAbi`. ABI generation fails when a `*Engine` contract does
not expose them with the same selectors, return types, and mutability.

Optional behavior is advertised through ERC-165:

| Interface                                                                               | Capability                           |
| --------------------------------------------------------------------------------------- | ------------------------------------ |
| [`IEarnEngineRedeem`](../../src/interfaces/engines/IEarnEngineRedeem.sol)               | Immediate preview and redemption     |
| [`IEarnEngineExactWithdraw`](../../src/interfaces/engines/IEarnEngineExactWithdraw.sol) | Immediate exact-asset withdrawal     |
| [`IEarnEngineAsyncRedeem`](../../src/interfaces/engines/IEarnEngineAsyncRedeem.sol)     | Request and cancel queued redemption |
| [`IEarnEngineInKindDeposit`](../../src/interfaces/engines/IEarnEngineInKindDeposit.sol) | Current venue-share entry            |
| [`IEarnEngineFeeValuation`](../../src/interfaces/engines/IEarnEngineFeeValuation.sol)   | Expiring fee valuation               |

Every installed engine must advertise `IEarnEngine` and at least one of `IEarnEngineRedeem`,
`IEarnEngineExactWithdraw`, or `IEarnEngineAsyncRedeem`. `EarnVault.initialize`
enforces this exit invariant: an engine that only accepts deposits, or adds only in-kind entry, would
leave holders no discoverable path to recover backing. An engine without the fee-valuation
capability is treated as never stale, so an engine backed by timestamped reports must advertise it.

The EarnVault measures engine-share deltas rather than trusting return values, and uses
`valueOf(engineShares())` for active managed NAV. The EarnVault, not the engine, tracks which part
of raw `totalShares` is managed backing, so raw shares transferred directly to an engine stay
quarantined from fees and conversion
([accounting anchors](../architecture/system.md#accounting-anchors)). Immediate engines treat
observed custody as authoritative. A redemption derives its asset result from the receiver's
measured balance increase and verifies the requested venue-share decrease. An exact withdrawal
verifies the receiver's exact increase and reports the measured venue-share decrease that sets the
EarnShare burn.

Fee-enabled deployments rely on the engine's NAV views to crystallize irreversible fee shares.
Production valuations must be fresh, manipulation-resistant, and consistent with realistically
redeemable value; a bad or reverting valuation stops fee-enabled actions rather than reusing stale
data. An engine is only as safe as its venue: pause controls, fee behavior, illiquidity, share
inflation, oracle manipulation, report staleness, and insolvency can affect deposits, exits,
and fee calculation.

## Installation

A profile names either an existing engine `address` or, for a kind whose definition has a
`factory`, a `venue` from which the lifecycle provisions an engine
([ERC-4626 factory](../modules/erc4626-engine.md#factory)). Before any broadcast the
[deployment lifecycle](../operations/deployment.md) checks an existing engine for runtime code, a
nonzero asset, and the kind's own `inspectBindings`. An engine that is already bound must be bound
to this profile's EarnVault and owned by an accepted owner. `bind-core` then calls
`initializeEarnVault(earnVault, owner)` when the deployer key holds the engine, or emits a handoff
for the current engine owner.

Customer ownership handoffs are two-step and leave the profile and record unchanged: the nominee
accepts the EarnVault operator role and engine ownership separately. Reconciliation, `verify`, and
inspection therefore accept a bound engine owned either by the profile owner or by the EarnVault's
current operator.

## Adding an engine

Before writing a new engine, establish:

1. the exact asset and share units;
2. who holds venue shares at every point;
3. whether exits execute immediately, asynchronously, or both;
4. how the EarnVault can independently measure deposits and exits;
5. how partial liquidity, blocked receivers, and cancellation behave;
6. how EarnVault contributions are deposited and reflected in redeemable NAV;
7. which roles can move backing or change venue configuration; and
8. how active and queued positions are valued in the base asset, including freshness and
   manipulation bounds.

A new engine should not require changes to EarnVault, EarnShare, or the Earn router. If it does,
the proposed interface is probably leaking venue behavior into the persistent layers.

### Recipe

A new kind `<kind>` (for example `propamm`) with engine contract `<Name>Engine` adds seven files,
registers itself in four existing files with an import, list entry, or table row, and regenerates
the ABI module. Every other workspace reads the new kind from those registrations.

New files:

| File                                              | Contents                                                                                                                                         |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `src/engines/<kind>/<Name>Engine.sol`             | The engine and any periphery contracts                                                                                                           |
| `test/engines/<kind>/*.t.sol`                     | Foundry tests ([test guide](../../test/AGENTS.md))                                                                                               |
| `deployments/modules/engines/<kind>.ts`           | One `defineEngine` ([fields](#definition-fields))                                                                                                |
| `localnet/src/engines/<kind>.ts`                  | Its `LocalEngine` ([fields](#localnet-and-e2e))                                                                                                  |
| `localnet/foundry/script/DeployLocal<Kind>.s.sol` | Contract `DeployLocal<Kind>Script is FixtureScript`, one `broadcast` function per fixture; local fixture contracts go in `localnet/foundry/src/` |
| `e2e/engines/<kind>/engine.ts`                    | `export const engine: E2eEngine` ([fields](#localnet-and-e2e))                                                                                   |
| `docs/modules/<kind>.md`                          | The kind's one owning page                                                                                                                       |

Registrations:

| File                                                                                 | Change                                                                                                                       |
| ------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| [`deployments/modules/engines/index.ts`](../../deployments/modules/engines/index.ts) | Import the definition and add it to `registry`                                                                               |
| [`localnet/src/engines/index.ts`](../../localnet/src/engines/index.ts)               | Import the `LocalEngine` and add it to `localEngines`, typed `Record<EngineKind, LocalEngine>`, so type checking requires it |
| [`.github/workflows/local-zone.yml`](../../.github/workflows/local-zone.yml)         | Add `<kind>` to `matrix.variant`; `e2e/harness/modules.test.ts` requires the list to equal `engineKinds`                     |
| This page                                                                            | Add a row to the [engine table](#yield-engines)                                                                              |
| [`deployments/abis/generated.ts`](../../deployments/abis/generated.ts)               | Regenerate: `forge build src script test localnet/foundry`, then `pnpm --filter @tempoxyz/earn abis`                         |

[ABI generation](../../deployments/abis/generate.ts) exports every deployable contract under `src/`
as `<name>Abi` (`PropAMMEngine` becomes `propAMMEngineAbi`) and every `script/deploy/` and
`localnet/foundry/script/` script's state-changing entry points as `<name>ScriptAbi`, so a new
contract needs no entry there. Add a venue built in another repository to
[`deployments/abis/external.ts`](../../deployments/abis/external.ts). Export an engine's helpers from
[`deployments/index.ts`](../../deployments/index.ts) only when its localnet or E2E module imports
them, as `quotePropAMMRoute` is.

A kind whose engines the lifecycle provisions from a venue also adds:

- the factory contract under `src/engines/` and its tests;
- a `script/deploy/` script whose `run(Input)` deploys an engine and whose
  `<releaseKey>Factory(uint256 expectedChainId)` deploys the ownerless factory, encoded by the
  definition's `deployInput` and `releaseInput`
  ([`DeployERC4626Engine.s.sol`](../../script/deploy/DeployERC4626Engine.s.sol)); and
- the `releaseKey` in each hosted network's `canonicalReleases.<network>.factories` in
  [`releases.ts`](../../deployments/core/releases.ts) (`mainnet` and `moderato`), with the
  reviewed factory address or `null` until it is released there. The entry is typed
  `Record<EngineFactoryKey, Address | null>`, so type checking fails until every network has the
  key ([shared factory releases](../operations/deployment.md#shared-factory-releases)).

The app needs no change: it lists kinds from `engineKinds` and labels them from the definition. Add
an `engineVerification` entry in [`app/src/earn/Verification.ts`](../../app/src/earn/Verification.ts)
only for browser checks that the shared stack inspection lacks, as Veda does.

### Definition fields

A definition requires `label`, `engineContract`, `engineSource` (its Solidity path), `venueLabel`,
the app topology's one-line `venueDetail`, `periphery`, `capabilities`, `readVenue`, and
`quoteDeposit`. `exitSolver`, `readPeriphery`, `inspectBindings`, and `factory` are optional.

- `capabilities` declares in-kind deposit and each exit (`redeem`, `boundedRedeem`,
  `exactWithdraw`, `asyncRedeem`). A stack's advertised capabilities are these plus `deposit`,
  which every stack offers, and any capability module adds.
- `quoteDeposit` returns the engine shares a deposit mints at the current state;
  `quoteEarnDeposit` converts them to EarnShare.
- `inspectBindings` checks engine-specific bindings beyond the shared stack checks and throws on a
  mismatch. It returns the kind's live deposit readiness (`EngineReadiness`) when it has one, and in
  `ready` mode it also throws unless deposits are ready.
- `factory` makes the kind provisionable from `engine.venue`: its `contract` and `source`,
  `releaseKey`, `deployScript` (`path:Contract`), `deployInput`, `releaseInput`, `predictEngine`,
  `engineConstructorArgs` for source verification, and `venueAsset`.
- `periphery` names the contracts an engine relies on beside itself and its venue
  ([`veda.ts`](../../deployments/modules/engines/veda.ts)). A stack records them in
  `contracts.periphery` under those names, `readPeriphery` reads them from a deployed engine, catalog
  parsing accepts exactly that set, and only the engine's own modules read a typed view
  (`vedaPeriphery`).

The registry derives `EngineKind`, `engineKinds`, `FactoryEngineKind`, the profile and catalog
parsers' accepted kinds, the local variants, and the literals that
[`boundary.test.ts`](../../deployments/modules/engines/boundary.test.ts) rejects in generic code:
outside test files, no file under `deployments/core`, `deployments/chain`, `e2e/harness`,
`e2e/fixtures`, `e2e/modules`, `localnet/src` (except `localnet/src/engines`), `app/src`, or
`app/worker` may quote a kind name.

### Localnet and E2E

A `LocalEngine` has:

- `provision`, which deploys the venue fixtures, and the engine too when the profile binds an
  existing one (use `deployAsEngineOwner` so the run exercises the `bind-core` handoff);
- an optional `validate` of the provisioned fixtures beyond the shared stack inspection;
- `profileEngine(target)`, the profile `engine` for the venue or engine;
- the EarnShare and venue token `metadata`; and
- `hostedFixture`: `false` for a local-only kind, or `{ overPathUsd, engineConstructorArgs? }` for
  the hosted fixture bootstrap (`pnpm e2e:fixture`).

Test fixtures are not periphery. `provision` returns them by name as `engineFixtures`, a hosted test
profile records them in its `fixture.json`, and E2E reads them through
`engineFixtures(context, names)`.

`e2e/engines/index.ts` imports every `e2e/engines/<kind>/engine.ts` and fails unless the folders
match `engineKinds`. An `E2eEngine` supplies `quoteRedeem`, the exact assets an immediate
redemption pays, and optional hooks such as `morphoFeeWrapper`. Cases never select by kind: they
declare `requiredCapabilities` or `requiredEngineHooks`, so they run on every engine that supports
them. CI runs `pnpm e2e:local -- --variant <kind> --all` for each kind.

### Related pages

Per-holder moves into and between stacks are in
[existing vault migration](../modules/migration.md). Venue review and launch checks are in the
[production readiness checklist](../architecture/security-and-privacy.md#production-readiness-checklist).
