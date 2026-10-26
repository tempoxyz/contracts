# ERC-4626 engine

This page owns the `erc4626` engine kind: `ERC4626Engine`, its venue requirements, the
`ERC4626EngineFactory` that provisions it, deployment, failure modes, and tests. The shared engine
contract, capabilities, and installation checks are in [yield engines](../integrations/engines.md).
Audit coverage is in [audits](../audit/README.md#scope).

## Contract

[`ERC4626Engine`](../../src/engines/ERC4626Engine.sol) wraps one ERC-4626 vault (`vault()`) and is
the default engine for venues that execute immediately. It deposits the base asset and measures the
venue shares it receives, accepts the vault's own shares through `depositInKind`, values its custody
with the vault's `previewRedeem`, and advertises redeem, exact-withdraw, and in-kind entry. It does
not advertise fee valuation, so its valuation never expires. Approvals are reset to zero before each
change, for USDT-style tokens.

The constructor `ERC4626Engine(vault, owner, nameOverride, symbolOverride)` takes the base asset and
share decimals from the vault and reverts `EmptyMetadata` when the effective name or symbol (the
override, or else the vault's own) is empty.

Venue requirements:

- `vault.asset()` must equal `EarnVault.asset()`;
- deposits, redemptions, and exact withdrawals must complete atomically;
- `previewWithdraw` must be suitable for enforcing a caller-supplied maximum share burn;
- `previewRedeem` and `totalAssets` must reflect the vault's current redeemable value, including any
  venue exit fees;
- redemption must burn exactly the requested venue shares; the engine checks the decrease
  (`UnexpectedVenueSharesBurned`) and enforces `minAssets` against the receiver's measured increase
  (`InsufficientAssetsReceived`);
- exact withdrawal must deliver exactly the requested amount (`UnexpectedAssetsReceived`), and the
  EarnShare charge uses the engine's measured venue-share decrease, not the vault's return value;
- the engine must be the only holder of the venue shares backing its EarnVault; and
- `depositInKind` pulls only shares of the engine's own `vault`, only for the EarnVault, and reports
  the measured custody increase.

Holders of that exact vault token can enter in kind; the opt-in path is in
[migration](migration.md#entry-with-existing-venue-shares). The demo vaults under `src/demo/` are
test fixtures, not production venues.

## Factory

[`ERC4626EngineFactory`](../../src/engines/ERC4626EngineFactory.sol) is ownerless and
permissionless, released once per network and pinned in that network's current release
([factory releases](../operations/deployment.md#shared-factory-releases)).
`deploy(deploymentId, vault, owner, nameOverride, symbolOverride)` uses `CREATE2` to deploy the
reviewed engine with the given setup owner; the factory keeps no engine authority and rejects itself
as owner (`FactoryCannotBeFinalOwner`) and a zero deployment ID. `computeEngineSalt` and
`predictEngine` bind the address to the deployment ID, vault, setup owner, and metadata overrides,
so an exact duplicate resolves to the same address and a second `deploy` reverts
`EngineAlreadyExists`. Engine creation is separate from `EarnFactory` because the engine supplies the
asset and metadata the core consumes.

**Why a concrete factory:** integrators create reviewed engines through ordinary contract calls
instead of broadcasting arbitrary creation bytecode, and the factory predicts addresses while
assigning the setup owner directly. Each engine kind that the lifecycle provisions therefore needs
its own reviewed factory, and the setup owner still binds the engine after core creation.

## Deployment

A profile names the engine one of two ways ([profile schema](../../profiles/README.md#schema)):

- `{ "kind": "erc4626", "venue": "0x..." }` runs `deploy-engine`
  (`script/deploy/DeployERC4626Engine.s.sol`) through the release's factory, with the deployer as
  setup owner, a deployment ID of `keccak256("<profile id>:v<version>")`, and no metadata overrides,
  so the venue must report a nonempty name and symbol. `erc4626` is the only kind with a factory.
- `{ "kind": "erc4626", "address": "0x..." }` reuses an existing, unbound engine, for example one
  created through the factory with reviewed metadata overrides, subject to the shared
  [installation checks](../integrations/engines.md#installation).

The lifecycle then runs `deploy-core` and `bind-core`, which calls
`initializeEarnVault(earnVault, finalOwner)` and transfers the engine to the profile `owner`, or
emits the engine-owner handoff when `DEPLOYER_PRIVATE_KEY` is not the setup owner. Optional
[access](access.md), [Zone](zone-router.md#deployment-and-activation), and
[reward](rewards.md#installation) steps follow ([step order](../operations/deployment.md#authority-boundaries)).

## Failure modes

The engine adds no liquidity of its own: a paused, illiquid, or fee-charging venue makes deposits or
exits revert or deliver less, and the receiver-measured bounds above turn any underdelivery into a
revert rather than a loss. `NoVenueSharesReceived` means the venue minted nothing (or an in-kind
transfer moved nothing). A manipulable `previewRedeem` affects fee crystallization and NAV, so the
venue must be dedicated or gated and reviewed against the
[production readiness checklist](../architecture/security-and-privacy.md#production-readiness-checklist).

## Tests

- Foundry, under [`test/engines/erc4626/`](../../test/engines/erc4626/): the engine, the factory,
  and a composition invariant suite.
- E2E: `erc4626` is the default local variant (`pnpm e2e:local`), so every shared case runs over it.
  `public-deposit-existing-venue-shares` (requires `inKindDeposit`) covers in-kind entry, and the
  local fixture adds a fee wrapper over the venue for
  [`migration-morpho-fee-wrapper-to-private-earn`](migration.md#wrapped-positions). On a persistent
  chain the fixture venue holds locked seed liquidity instead.
