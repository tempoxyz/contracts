# Localnet

`localnet/` starts a disposable Tempo L1 and Zone in Docker, deploys Earn onto them through the
shared profile lifecycle, and hands the running environment to a consumer: the app's
`pnpm dev:local`, local E2E, and downstream localnet consumers. This page owns its
API and the constraints behind it; [development](README.md#local-tempo-and-zone) has the
commands, and the [localnet guide](../../localnet/AGENTS.md) the package rules. Exact image and
protocol versions are owned by `localnet/src/config.ts` and `localnet/fixtures/runtime-lock.json`.
Deploying onto an existing devnet instead is documented in
[existing devnet chains](../deployment/e2e-environments.md#existing-devnet-chains).

## Consumer API

`localnet/src/index.ts`, the `localnet` workspace package's entry, exports the `Deployment`,
`Environment`, `Foundry`, and `Devnet` namespaces, `localEngines`, `defaultEngineKind`, and
`localStack`. A consumer calls `Environment.run(options)`:

| Option           | Meaning                                                                                                                                                                      |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `consumer`       | Required name, printed when the environment is ready.                                                                                                                        |
| `ready`          | Required `async (environment) => result`. The containers stop and the run directory is removed when it settles, so the environment is valid only inside it.                  |
| `engineKind`     | The [engine kind](../earn/integrations/engines.md) whose venue fixtures to deploy; `erc4626` by default. With `earnProfile`, it must match the profile's kind or be omitted. |
| `access`         | `'tip403-whitelist'` (default) or `'open'` EarnShare for the default profile. Not allowed with `earnProfile`, which defines its own access.                                  |
| `earnProfile`    | An authored `EarnDeploymentProfile` to deploy instead of the default ([profiles](#profiles-and-the-shared-lifecycle)).                                                       |
| `sameAssetRoute` | Also deploy a PATHUSD stack with a pool-less router (off by default).                                                                                                        |
| `containers`     | `{ name?, labels? }`: name the containers `<name>.l1` and `<name>.zone` and label the L1 container (Prool does not expose Zone container labels).                            |

`ready(environment)` receives:

- `accounts`: fresh keys for one run. `deployer` (default-profile EarnVault owner, guardian, and
  janitor), `accessAdministrator` (policy membership; the deployer creates the policy and hands its
  admin over), `user` (revenue-share recipient), and `outsider` are faucet-funded.
  `zoneAdministrator` is the L1 genesis Zone Factory owner, which enables Portal tokens, admits
  accounts, registers gateways, and holds the `setAccessMode`/`setGatewayMode` switches in
  `zonePortalAbi`, for consumer-specific setup.
- `deployment`: `Deployment.State`, with the chain, Zone, and Portal identity, the base asset and
  fixtures, the primary stack's contracts and `earnRouter` (present only when its profile configures
  one), `earnProfile` (the localized profile that was deployed), `engineFixtures`, and
  `sameAssetRoute` when requested.
- `l1 { image, rpcUrl }` and `zone { image, publicRpcUrl, rpcUrl }`, where `zone.rpcUrl` is the
  authenticated private RPC.

`localStack(environment, { name?, publicZoneRpc? })` turns that state into an `EarnStack`, handing
the Zone and router it deployed to the Zone router's `zoneRouterStackFields`.

Side contracts a kind provisions beyond its venue and engine (the ERC-4626 `morphoFeeWrapper`;
Veda's Accountant, Teller, Queue, registry, solvers, and replacement periphery) are returned by name
in `deployment.engineFixtures`, which only that kind's modules read.

With `sameAssetRoute: true`, a second stack's vault asset is PATHUSD and its `SingleZoneEarnRouter`
binds no pool, so a Zone holding PATHUSD deposits it directly. `deployment.sameAssetRoute` holds its
asset, venue, engine, EarnVault, EarnShare, EarnFees, and router. Its profile (`sameAssetProfile`) is
always ERC-4626 and keeps the primary profile's core and access without rewards. It shares the
factory, access policy, and Zone; its EarnVault, EarnFees, and router join the primary stack's
policy-membership transactions, and its EarnShare is enabled and mirrored before `ready` runs.

## Localnet layer

`localnet/src/layer.ts` exports `earn(options)`, a v0 layer for `@tempoxyz/localnet`, as the
repository root's `./localnet` export. The root package (`tempo-contracts`) is not published, so a consumer
links a checkout of this repository under a dependency name of its choice. The layer accepts `access`,
`earnProfile`, `engineKind`, and `sameAssetRoute` and runs `Environment.run` with them. `up({ runId })`
resolves inside `ready`; `down()` or the run's abort signal releases it, which stops the containers.
The containers are named `tempo-localnet.<runId>.{l1,zone}`, and the L1 container carries the
`tempo.localnet.run=<runId>` and `tempo.localnet.layer=earn` labels.

The layer writes two manifest sections:

- `network`: `l1 { chainId, rpcUrl, wsUrl }`, `zones[]` with one `{ id, chainId, portal, rpcUrl,
  privateRpcUrl }` (public and private RPC), the run's `accounts`, and `images { l1, zone }`.
- `earn`: `{ version: 1, deployment }`, the `Deployment.State` with bigints as decimal strings.

A consumer needs everything a local run needs: this checkout, its `pnpm install`, Foundry, and Docker.
Localnet installs Earn's pinned Solidity dependencies on first use; Prool supplies only containers.

## Profiles and the shared lifecycle

Every local Earn stack is an `EarnDeploymentProfile` deployed through the same plan and lifecycle as
hosted profiles: `planEarnDeployment` derives the actions, `reconcileEarnProfileActions` runs the
shared `earn/script/deploy/` Forge scripts and the typed authority steps (engine binding, router
admission, Zone token enablement, all held by local accounts), and `verifyEarnDeploymentState`
inspects the result, including the factory-predicted EarnShare, EarnFees, and engine addresses.
Localnet skips only what needs a hosted chain: the reviewed factory runtime check, source
verification, and the published deployment record.

Without `earnProfile`, each variant deploys its default profile (`variantProfile`): the deployer as
owner, guardian, and janitor, the fixed and excess fees, both reward
contracts, and a router through the local conversion pool, with `access` selecting a protected or
open EarnShare. With `earnProfile`, `localizeProfile` replaces only the profile's external
dependencies (chain, venue or engine, TIP-403 policy, Zone ID, router private asset and pool) and
deploys its core settings, principals, rewards, and router customer ID as authored; it rejects a
profile whose access does not match the local policy.

A kind whose `provision` deploys its engine with `deployAsEngineOwner` (PropAMM, which has no engine
factory) leaves that engine with a separate funded setup owner, so the lifecycle stops at the
`bind-core` handoff; localnet binds the engine as that owner and records it with
`recordAuthorityAction`, the path hosted operators use. Any other handoff fails the run. A final
`prepareLifecycleStep` pass must find each stack complete with unchanged pending state.

Each kind's `LocalEngine` lives in `localnet/src/engines/<kind>.ts`: venue `provision`, an optional
fixture `validate`, the `profileEngine` target, token `metadata`, and `hostedFixture` (whether the
kind runs over canonical PATHUSD and how its engine's constructor arguments are read for source
verification). Its fixture contracts deploy from `earn/script/local/script/DeployLocal<Kind>.s.sol`;
shared engine facts come from `engineDefinitions`. [Adding an
engine](../earn/integrations/engines.md#adding-an-engine) lists every file a new kind needs.

The hosted fixture bootstrap (`e2e/fixtures/bootstrap.ts`) runs the same
`Deployment.provisionFixtures` and `localEngines` steps against a hosted chain with
`persistent: true`, under which the Veda engine accepts a ten-year rate age instead of the local one
day. After provisioning, `validateFixtures` checks code at every fixture address, the funder's pair
and issuer roles, the conversion pool's pair, oracle, registry, owner, and unpaused state, and the
kind's own `validate`; a local stack also checks that its router supports exactly deposit and redeem
and prices at par with the full pool inventory.

## Foundry and containers

- Each fixture step is its own `forge script --sig <calldata>` call of one entry point:
  `DeployLocalEarn.s.sol` for engine-independent fixtures, one `DeployLocal<Kind>.s.sol` per engine,
  or a shared release step. Localnet deploys the EarnVault and EarnFees implementations and
  `EarnFactory` from `earn/script/deploy/DeployFactoryRelease.s.sol` and every engine factory from its
  engine's deploy script (`erc4626EngineFactory` in `earn/script/deploy/DeployERC4626Engine.s.sol`); it
  deploys no rewards factory. `Foundry.script` binds a script to its generated ABI from
  `@tempoxyz/contracts/abis`, so step names and arguments are checked against the Solidity signatures.
- Forge receives `DEPLOYER_PRIVATE_KEY` as its only secret, alongside an allowlist of ordinary
  process variables and `FOUNDRY_PROFILE=deploy`, the profile hosted deployments use. Fixture and
  lifecycle steps run with `--batch` and the PATHUSD fee token; Tempo batches allow a top-level
  CREATE only in the first slot.
- Fixture scripts extend `earn/script/local/script/FixtureScript.sol`, shared with the hosted fixture
  bootstrap, so the stablecoin pair (`DemoStablecoinFunder`) and the DirectPropAMM pool deployment
  have one definition. `DeployLocalEarn.s.sol` deploys the `earn/src/demo/` par oracle and recipient
  registry.
- Each `Environment.run` gets a temporary run directory `localnet/.local/run-*` holding its
  `FOUNDRY_BROADCAST` directory (`broadcast/`) and lifecycle resume state (each profile's
  `deployment.pending.json` beside a nominal `profiles/<id>/profile.json`; no record is written),
  and removes it during cleanup. Local app and E2E processes use the same dev chain ID and must never
  share `*-latest.json` broadcasts.
- Large CREATE steps (the EarnVault and EarnFees implementations, `EarnFactory`, the stablecoin
  pair, the Veda engine, and the shared lifecycle steps that declare it) are marked
  `rawGasEstimate`, which uses `--gas-estimate-multiplier 100`; Foundry's default 200% estimate for
  a batch exceeds Tempo's 30M transaction cap even though the deployment fits.
- Stateful TIP-20 mints, including router-pool and engine-pool inventory funding, go through a viem
  Tempo transaction. Generic Foundry's pre-broadcast simulation does not implement the pinned
  node's compound TIP-403 behavior and can report `PolicyForbids` for a transaction the node
  executes successfully.
- Every Foundry profile compiles for Cancun ([toolchain](README.md#toolchain)): the pinned
  Tempo L1 executes Osaka and supports EIP-1153, while Cancun avoids emitting unrelated newer opcodes
  and keeps the production Veda transaction-rate checkpoint deployable in local E2E.
- Genesis is derived from the selected Tempo image (`dump-genesis --chain dev`) with the canonical
  EIP-2935 history account installed, and the content is copied directly into each L1 container.
  Never use a shared on-disk genesis path; app and E2E environments may start concurrently. The
  unpatched dev genesis makes Zone `submitBatch` revert with `InvalidTempoBlockNumber`.
- Both images are pinned by immutable digest in `localnet/fixtures/runtime-lock.json`, which
  `Environment.run` checks, with the runtime fixture's hash, at import. Docker pulls the L1 image
  only when it is missing; Prool re-pulls the Zone image by that digest at each start. The lock
  binds the image pair to the TIP-1091 runtime provenance and nine-field Zone ABI. Upgrade the L1
  image, Zone image, runtime lock, and protocol ABI together, by editing the lock; a hosted image is
  not a drop-in local replacement.
- To move the lock, pick a `ghcr.io/tempoxyz/tempo-zone` image built by `tempoxyz/tempo` and the
  `ghcr.io/tempoxyz/tempo` L1 image built from the same Tempo revision; `sourceCommit` is that
  revision. `tip1091-runtime.json` holds the Portal, Messenger, and Verifier runtimes the L1 image's
  `dump-genesis --chain dev` installs at `0x5AD1…`, `0x5A4d…`, and `0x5A56…` (the constants in that
  revision's `crates/contracts/src/zones.rs`), and `runtimeFixtureSha256` is the file's SHA-256.
- The Zone token's local `transferPolicyId()` may report policy `1`, while the TIP-403 proxy mirrors
  and enforces the L1 compound policy by its registered ID.
- The Zone starts with the freshly deployed base fixture token as its initial token. The pinned Zone
  runtime rejects pathUSD as the default when the L1 genesis has no transfer policy configured for
  that token.

## Zone behavior

- Use Prool's authenticated private Zone RPC for `zone_*` methods and the public RPC for
  unauthenticated chain ID and bytecode checks.
- Local E2E submits `requestWithdrawalSync` through public RPC so viem can read the caller's
  `WithdrawalRequested` receipt log, while account-scoped reads and privacy assertions stay on
  authenticated private RPC, which intentionally strips that system event. It passes PATHUSD as the
  Zone fee token; the test accounts hold no other token on the Zone.
- An `InvalidDepositQueueHash` failure means incompatible L1/Portal and Zone runtimes; move the
  [runtime lock](#foundry-and-containers) rather than swapping one image.
- Discover canonical TIP-1091 sequencers from `ZoneFactory.zones(zoneId)` or the `ZoneCreated`
  event, never from the Portal. `Deployment.create` derives the current sequencer that way and
  verifies the returned Portal; do not accept caller-supplied sequencer state.
- Wait for parent blocks through the Tempo-state predeploy so local synchronization checks remain
  independent of optional `zone_getZoneInfo` metadata fields.
- Each token used by closed-loop flows is enabled, and private cases wait for the Zone to mirror a
  newly deployed EarnShare. The Portal rejects enabling a token whose name, symbol, or currency
  exceeds 31 bytes (`TokenMetadataTooLong`), so local venue names leave room for the factory's
  ` (Earn)` suffix.
- The local Zone starts with access and gateway enforcement off. The Zone administrator registers
  every deployed router as a callback gateway (`setGateway`), as hosted administrators do, so
  routers keep working when a consumer enforces gateway mode, or both modes as hosted Zones do,
  through `environment.accounts.zoneAdministrator`. A Portal account holds one role, so with access
  enforced and gateway mode off a registered router is not an admitted depositor. Do not infer
  hosted Portal admission or gateway policy from the disposable fixture; inspect those controls
  independently in hosted runs.
- The router's `onWithdrawalReceived` callback takes six arguments
  `(zoneId, sourcePortal, senderTag, token, amount, data)`, part of the locked protocol ABI.
- Setup and E2E progress print as numbered trees. Successful Forge output is buffered into receipt
  summaries; raw Forge output is shown, delimited, only on failure.

## PropAMM fixtures

- Each environment deploys one router DirectPropAMM pool, with the alternate asset as base and the
  vault asset as quote, an always-fresh par oracle, and 100,000 units of inventory per side; the
  primary stack's router uses it and the same-asset router has none. The fixture funds and unpauses
  the pool before the lifecycle; unpausing admits no taker, and the lifecycle then admits the router
  as taker and recipient. Off-par and stale-oracle rejection remain covered by the Foundry router
  conversion tests.
- Local PropAMM engine stacks use the unmodified
  [pinned DirectPropAMM fixture](../earn/modules/propamm.md#pinned-directpropamm-fixture) with disposable
  token, oracle, and registry fixtures. The always-fresh local oracle does not cover stale-rate
  economics; retain the Foundry regression suite.
