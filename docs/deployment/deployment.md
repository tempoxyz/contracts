# Earn deployment lifecycle

This runbook owns the shared deployment lifecycle: the `pnpm earn` commands, the generated record,
verification, authority handoffs, and shared factory releases. The authored profile JSON is in
[deployment profiles](../../profiles/README.md), each capability's own steps in its
[module page](../earn/README.md#capability-modules), engine installation in
[yield engines](../earn/integrations/engines.md#installation), and package exports in the
[deployment package reference](../../deployments/README.md).

The current Foundry deployment scripts and this profile lifecycle tooling are outside audit scope
([audits](../earn/audit/README.md#scope)).

## Commands

One profile JSON drives every command, and `deploy` is the only one an operator must run:

```sh
cp .env.example earn/.env.app-moderato
pnpm earn plan profiles/app-moderato/profile.json
pnpm earn deploy profiles/app-moderato/profile.json
pnpm earn status profiles/app-moderato/profile.json
pnpm earn verify profiles/app-moderato/profile.json
```

| Command   | What it does                                                                                                                                                             | Flags                                                                                    |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------- |
| `plan`    | Prints the planned actions. With an RPC, it labels a privileged action `authority` only after read-only calls prove the configured signer holds it; otherwise `handoff`. | `--rpc-url`, `--json`                                                                    |
| `deploy`  | Reconciles the profile until it completes or reaches an external authority ([lifecycle](#lifecycle)).                                                                    | `--rpc-url`, `--json`, `--watch` (rechecks every 15 seconds until the handoff completes) |
| `status`  | Reads the record or pending state without chain reads: `not-started`, `in-progress`, `deployed`, `verification-pending`, or `complete`.                                  | `--json`                                                                                 |
| `verify`  | Rechecks a completed record against the live chain without a signer or any write ([rechecking](#rechecking-deployed-profiles)).                                          | `--rpc-url`, `--json`, `--skip-zone`                                                     |
| `deposit` | Quotes, and with `--broadcast` submits, a user deposit into the deployed stack.                                                                                          | see below                                                                                |
| `access`  | Reads or changes one member of a protected profile's TIP-403 whitelist ([access](../earn/modules/access.md#deployment-and-operations)).                                  | `--earn-file <profile.json> <status\|add\|remove> <address>`                             |

Every command loads only the ignored `.env.<profile-id>` beside the `profiles/` directory that holds
the profile (`earn/` for Earn's own; [profiles in another repository](../../profiles/README.md#profiles-in-another-repository));
values already in the process environment take precedence. A command fails, naming that file, when
neither supplies a value it needs:

- `DEPLOYER_PRIVATE_KEY`, for every command until the profile has a `deployment.json`, because the
  deployer fixes the deterministic deployment identity;
- `TEMPO_RPC_URL` (or `--rpc-url`), for `deploy`, `verify`, and `deposit`.

`verify` of a Zone profile also needs `TEMPO_API_KEY` or `ZONE_RPC_URL` unless `--skip-zone` is
passed.

`ZONE_ADMIN_PRIVATE_KEY` is optional: when set, `deploy` performs the Zone administrator's steps
([authority boundaries](#authority-boundaries)). Plans are derived and never checked in.

The deposit helper quotes through the engine's own module for any engine kind:

```sh
# Read-only quote plus deployment and wiring checks
pnpm earn deposit profiles/app-moderato/profile.json --assets 1

# Submit the atomic approval + deposit transaction
pnpm earn deposit profiles/app-moderato/profile.json --assets 1 --broadcast
```

`--assets` is a decimal amount of the vault asset. The helper signs with `DEPLOYER_PRIVATE_KEY`;
`--account <address>` quotes for another account without that key, and `--receiver <address>`
mints elsewhere. The minimum output defaults to 50 bps below the quote (`--slippage-bps`, 0 to
10000). It refuses an RPC whose chain or genesis differs from the record. Nothing is sent without
`--broadcast`, and approval and deposit are one Tempo transaction.

## Lifecycle

```text
profile.json + .env.<profile-id>
  -> refuse privileged roles held by a public fixture identity
  -> with a committed record: recheck its provenance and source verification onchain
     without one: match the locally compiled shared factories to the reviewed release
  -> discover L1 genesis and each capability's external identity (such as the Zone Portal)
  -> reconcile the deployment steps, stopping at an external authority it cannot act as
  -> verify deployed state and publish deployment.json with source verification pending
  -> attempt every activation step, reporting the first handoff afterward
  -> verify contract sources, then remove the pending state
```

Rerun the same command after an external authority acts; it resumes from chain state. Deployment
steps must all complete before the record is published. Activation steps (pool admission, Zone
token enablement, gateway registration) are mutable external readiness: each is attempted on every
run, a handoff on one does not block the others or source verification, and none of them is
recorded as a completed action.
Forge may write only inside the Earn checkout, so for a profile outside Earn's `profiles/` each
Forge step writes its outputs to a staging copy under the ignored `.earn/external/<id>/`, which the
tooling moves back into the profile's `deployment.pending.json` after the step or, if the run
stopped, on the next run.

The profile declares immutable creation intent and the external readiness it requires; the chain
is authoritative, and later operator-authorized changes are operational state. The ignored
`deployment.pending.json` beside the profile is the only private resume state. It records the
profile ID, deployer, final owner, factory release, intent hash, pinned factory runtime hashes,
discovered and deployed addresses, and each completed action's transactions. Consumers use the
typed handoff or completed record and never parse it. Deleting it changes nothing onchain, but
before the record is published it discards the transaction provenance a clean resume needs.
Pending state resumes only under the identity that wrote it: a different deployer, factory
release, or intent hash (including a checkout that hashes intent differently) is refused, so
finish an unpublished deployment before moving to a newer Earn checkout.

Deployment subprocesses use the repository's `deploy` Foundry profile, which compiles for Cancun
like Tempo's deployment runtime and writes separate artifacts. A hosted broadcast requires the
[toolchain](../development/README.md#toolchain) Foundry version on `PATH`, checked when reconciliation
first reaches a broadcast. Foundry output files are not proof of deployment, because simulation
can write them before broadcast: completion and crash recovery accept an output only after the
expected code and immutable bindings are observed onchain. `EarnFactory.deploy` is permissionless
and refuses an occupied EarnShare prediction, so when the profile's predicted EarnShare already
exists and no Foundry output of this run explains it, `deploy-core` adopts that stack instead of
retrying. It records the addresses `DeployEarnCore` would have written, including the engine and its
asset, which a configured engine has no other step to record, and the factory transaction that
created the stack: the predicted EarnShare and EarnFees cover every creation-time parameter, and
inspection checks the adopted stack before any record is written. An interrupted run's own outputs
are recovered first. Either way, `deploy-core` records the transaction named by the factory's
`EarnStackDeployed` event for that EarnShare, never a hash from Forge's latest-broadcast file, which
every profile on the chain shares and which may lack the receipt.

## Generated record

When the deployment steps complete, the command atomically publishes `deployment.json` beside
`profile.json`, initially with `source.contractVerification: "pending"`, then upgrades it in place
to `"verified"` once source verification succeeds. Neither file contains secrets. Commit the
profile and record together, but treat the record as complete only once `contractVerification` is
`verified`. Never edit generated addresses into the profile or hand-copy them into E2E arguments.

The record (`version: 4`) contains:

- `deploymentId`, `deployer`, `owner`, and `factories`, the resolved shared factory release;
- `deploymentIntentHash` and `componentDeploymentIntentHashes`, one hash per intent component
  (`core`, `engine`, `zone`, `targetYield`, `boostRewards`, `null` when not configured);
- `target`: the chain ID, L1 genesis hash, and each capability's external identity, such as the
  Zone's ID, chain ID, Portal, and Messenger;
- `addresses`, `assetDecimals`, and `deploymentBlock`, the earliest block of a deployment
  transaction;
- `actions`: each completed deployment step with its transaction hashes;
- `runtimeCodeHashes` for every recorded address with code;
- `source`: the factory deployment ID, Git commit and dirty state, Foundry version, verifier URL,
  and per-contract source verification.

Changing intent, replacing code, or restoring state across a regenesis therefore cannot silently
reuse stale addresses. Publication is strict: the record must contain exactly the addresses and
completed deployment steps derived from the plan. Activation steps are not recorded; their state is
always read from the pool and Portal. Changing an optional component (`zone`, `targetYield`,
`boostRewards`) redeploys only that component's contracts and republishes the record; core and
engine never change in place, so a record whose `core` or `engine` hash differs from the profile is
refused.

The record does not choose its own trust roots. `source.factoryDeploymentId` must equal the
keccak-256 hash of `<profile-id>:v<version>`, and the recorded verifier must be the trusted Tempo
verifier the tooling hard-codes before it is contacted. Every ordinary Solidity source match must
identify the expected fully qualified contract, reproduce every source input from the canonical
checkout, and, when the verifier reports a creation transaction, point to Earn's recorded
transaction (factory-created contracts may omit it). The Git commit is provenance, not a required
local object in a fresh or squash-merged checkout. Changing the recorded deployment transaction or
Zone Factory identity requires a fresh successful verification before promotion.

On a fresh checkout, the command seeds pending state from the committed record only after
revalidating its runtime provenance, derived contract identity, and each completed action onchain;
a stale or edited record is rejected before it can drive an authority transaction. A record marked
`pending` resumes source verification without repeating deployment or activation.

### Source verification

For hosted deployments the command submits missing source to `https://contracts.tempo.xyz`, waits
for a bytecode and source match, and records the result. A verifier outage never causes a
rebroadcast or loses the record: rerunning resumes at verification after rechecking deployed state.
Hosted completion cannot opt out of source verification.

The record classifies actual code forms instead of treating every output as an ordinary Solidity
deployment. Ordinary contracts keep the verifier's `exact_match` or normalized `match`; the
canonical Zone Messenger is a functionally authenticated protocol precompile without a runtime-code
hash; EarnVault records its ERC-1967 proxy plus the factory implementation's address and
runtime-code hash; EarnFees records the canonical minimal proxy with the same implementation
provenance; and EarnShare records its protocol-native TIP-20 factory. Shared implementation source
verification belongs to the factory release, not to each profile.

### Rechecking deployed profiles

`pnpm check` validates Earn's committed profiles and their records offline. To recheck a deployed
profile against its live chain, run on demand, with no signer:

```sh
pnpm earn verify profiles/<profile-id>/profile.json
pnpm e2e:profile profiles/<profile-id>/profile.json --validate-only
```

`verify` checks the record's target, addresses, provenance, and recorded source verification, and
reports engine and capability readiness, such as router conversion inventory. For a Zone profile it
also requires `TEMPO_API_KEY` or `ZONE_RPC_URL` to confirm the live Zone; `--skip-zone` checks
everything else and reports the Zone as not verified. `--validate-only` fails on what `verify` only
reports: engine or capability readiness, custody, EarnShare issuer exclusivity, accounting
alignment, and required TIP-403 members ([profile acceptance](e2e-environments.md#profile-acceptance)).
Nothing reruns these checks on a schedule, in Earn or in a deployments repository that holds
other stacks ([profiles in another repository](../../profiles/README.md#profiles-in-another-repository)).

## Authority boundaries

Steps run in the order of [`deploymentSteps`](../../deployments/modules/index.ts); a profile's plan
is the enabled subset. Each [module page](../earn/README.md#capability-modules) owns its steps'
preconditions and results.

Before any step, `pnpm earn deploy` refuses a profile that assigns a privileged role to an address
derived from a private key in the public `.env.example`. The guard covers core's roles (owner,
including one defaulted from the deployer; emergency guardian; async janitor; every fee recipient;
fee distributor) and every role a capability slice declares through `privilegedPrincipals`, such as
the reward treasury.

| Step                             | Phase      | Authority (signer)                                                   | Owner                                                                           |
| -------------------------------- | ---------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `deploy-engine`                  | deployment | deployer (`DEPLOYER_PRIVATE_KEY`)                                    | [Factory-provisioned engine](../earn/modules/erc4626-engine.md#deployment)      |
| `deploy-core`                    | deployment | deployer                                                             | EarnShare, EarnVault, and EarnFees with the exact configuration                 |
| `bind-core`                      | deployment | current engine owner (`DEPLOYER_PRIVATE_KEY` when it holds the role) | Bind EarnVault and atomically transfer the engine to the configured final owner |
| `deploy-router`                  | deployment | deployer                                                             | [Zones](../earn/modules/zone-router.md#deployment-and-activation)               |
| `deploy-merkle-distributor`      | deployment | deployer                                                             | [Rewards](../earn/modules/rewards.md#installation)                              |
| `validate-access`                | deployment | deployer                                                             | [Access policy](../earn/modules/access.md#deployment-and-operations)            |
| `deploy-contribution-controller` | deployment | deployer                                                             | [Rewards](../earn/modules/rewards.md#installation)                              |
| `authorize-router`               | activation | PropAMM pool owner (`DEPLOYER_PRIVATE_KEY` when it holds the role)   | [Zones](../earn/modules/zone-router.md#deployment-and-activation)               |
| `enable-zone-tokens`             | activation | Zone Portal administrator (`ZONE_ADMIN_PRIVATE_KEY`)                 | [Zones](../earn/modules/zone-router.md#deployment-and-activation)               |
| `register-zone-gateway`          | activation | Zone Portal administrator (`ZONE_ADMIN_PRIVATE_KEY`)                 | [Zones](../earn/modules/zone-router.md#deployment-and-activation)               |

Forge receives only `DEPLOYER_PRIVATE_KEY`; it never receives another authority key. Each typed
authority step first proves with read-only calls that its signer holds the exact authority (the
Zone administrator key may also be the sole owner of a threshold-1 Safe that administers the
Portal), batches its changes atomically, and continues. Authority signing is pinned to the
profile's chain and the protocol nonce: the client refuses an RPC that reports another chain ID or
fills a transaction under another nonce key, because viem would otherwise sign what the RPC fills.
When no configured signer holds the
authority, the command emits a handoff naming the exact call and addresses for its actual owner.
Stale pending state or a plausible-looking transaction hash cannot bypass the onchain check.

The reconciler returns a typed `complete` or `handoff` result, the stable boundary for automation;
an adapter may satisfy only authority it legitimately owns before invoking it again.

## Shared factory releases

Production profiles consume a reviewed release from the per-chain
[release registry](../../deployments/core/releases.ts); they never deploy shared implementations.
A release names the `EarnFactory` (`earn`) and, under each engine's `factory.releaseKey`, the engine
factories it carries. Each chain has exactly one current release: an unpublished pending deployment
must use it, and a committed record keeps the release it pinned. Finish or discard any pending
deployment before replacing a chain's release. Before a fresh deployment's first broadcast, the
deploy command compiles the current EarnFactory, EarnVault, EarnFees, and, for a profile that
provisions its engine from a venue, that engine's factory, and compares their runtime code with the
reviewed onchain release and its immutable implementation bindings, so a source change requires a
fresh release. Pending deployments pin the resolved factory runtime hashes; completed records keep
the release with their source provenance.

Releases create EarnShare with empty currency metadata (`""`) and the underlying asset as its quote
token: an EarnShare is not a USD stablecoin or a 1:1 claim on another EarnShare. Shared factories
are ownerless, and their constructors impose no PATHUSD transfer-policy ID. The deployer must be
funded and authorized to pay fees under its chosen fee token's live policy; a custom PATHUSD policy
does not by itself block a release.

Earn compiles with solar ([`earn/solar.lock`](../../earn/solar.lock)). Tempo's source verifier
rebuilds only the solar builds it pins in tempo-apps'
[`solar-builds.json`](https://github.com/tempoxyz/tempo-apps/blob/main/apps/contract-verification/container/solar-builds.json),
so a new `solar.lock` revision must be added there and deployed before a hosted deployment built
with it. Source verification passes Forge the solar build (`--compiler-version`, from
`earn/solar-solc --version`, with `--compilation-profile default`); a manual
`forge verify-contract` needs the same two flags. Deploy a core release with:

```bash
FOUNDRY_PROFILE=deploy forge script \
  script/deploy/DeployFactoryRelease.s.sol:DeployFactoryReleaseScript \
  --sig 'earnFactoryRelease(uint256)' 4217 \
  --network tempo --rpc-url https://rpc.tempo.xyz --broadcast --slow \
  --gas-estimate-multiplier 100
```

`DeployFactoryRelease` holds the core (`earnFactoryRelease`) and rewards (`earnRewardsFactory`)
release entry points; each engine factory's entry point lives in that engine's deploy script. Every
entry point takes the expected chain ID, refuses another chain or a Foundry profile other than
`deploy`, and broadcasts with `DEPLOYER_PRIVATE_KEY`. `earnFactoryRelease` deploys fresh EarnVault
and EarnFees implementations, constructs the immutable factory, and checks its code and bindings.
Tempo's RPC must supply the creation estimate for the large EarnVault implementation; only this
release pins Forge's multiplier to `100`, because default padding can exceed Tempo's 30M gas cap.
Reconcile the receipt before continuing after a failed broadcast. Source-verify all three contracts
before updating the registry. Localnet deploys the same release through the single-CREATE entry
points `earnVaultImplementation`, `earnFeesImplementation`, and `earnFactory`, plus every
registered engine factory's entry point.

### Releasing from CI

The **Factory Release** workflow ([`factory-release.yml`](../../.github/workflows/factory-release.yml))
releases from `main` in one run. Choose the networks (`both` runs Moderato, then mainnet only after
Moderato succeeds), the releases (`all` is the core release and every engine factory the registry
names; `core`, `rewards`, or one engine factory's `releaseKey`, such as `erc4626Engine`, deploys just
that one), and whether to broadcast. Each network's job runs
`pnpm factory-release <network> <release|all> [--broadcast]` ([`core/factory-release.ts`](../../deployments/core/factory-release.ts)),
which runs each release's entry point below with the `deploy` profile, checks that it created exactly
the release's contracts, each from the locally compiled creation bytecode, and, after a broadcast,
source-verifies each one on Tempo's verifier. Without broadcast, Forge only simulates, and each
release simulates from the deployer's current nonce, so only the first release's addresses are the
ones a broadcast creates. Each job's summary and its `factory-release-<network>` artifact list the
addresses, transactions, and source matches; a run that stops keeps the releases before it.

After a broadcast, the last job records every release whose contracts all source verified, from
every network that reached it, in [`releases.ts`](../../deployments/core/releases.ts) on a
`factory-release/<run>-<attempt>` branch (`pnpm factory-release registry`) and links it in the job summary with
the pull request description; a maintainer opens that pull request, so the registry changes only
through its review.

Each network's job runs in the `factory-release-<network>` environment, which requires a reviewer's
approval and holds `DEPLOYER_PRIVATE_KEY` (and optional `TEMPO_RPC_URL`, `TEMPO_RPC_USERNAME`,
`TEMPO_RPC_PASSWORD`). Both environments hold the same deployer key that local profile deployments
use; releases are ownerless, so it only pays fees. Rotating it updates both environments. The
network's `hosted-contracts-<network>` queue orders only CI jobs, so do not broadcast with that key
locally while a release runs. The same command runs locally with `DEPLOYER_PRIVATE_KEY` exported,
for example from a profile's `.env.<id>`; it does not load dotenv files itself.

An engine factory release is independent: the `<releaseKey>Factory` entry point of the engine's
deploy script (for example `erc4626EngineFactory` in `DeployERC4626Engine`) deploys it. Deploy one
when the engine creation bytecode changes, then source-verify it before updating the registry. A
core already created against an old engine remains tied to that engine.

```bash
FOUNDRY_PROFILE=deploy forge script \
  script/deploy/DeployERC4626Engine.s.sol:DeployERC4626EngineScript \
  --sig 'erc4626EngineFactory(uint256)' 42431 \
  --network tempo --rpc-url https://rpc.moderato.tempo.xyz --broadcast --slow
```
