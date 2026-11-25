# Development and validation

This page owns the toolchain, the checks a change must pass, and continuous integration.
[CONTRIBUTING.md](../../CONTRIBUTING.md) is the short path for a first change; the
[localnet](localnet.md) reference holds implementation constraints for that package.

## Toolchain

- **Solidity** `0.8.38`, compiled by the [solar](https://github.com/paradigmxyz/solar) release
  [`solar.lock`](../../solar.lock) pins (currently v0.3.1), with **Foundry v1.8.6**. Forge calls solar through
  [`solar-solc`](../../solar-solc), which presents it as solc `0.8.38`; solar's code
  removes most of solc's stack shuffling, internal jumps and address masking, so the same work costs
  less gas and executes faster. `pnpm deps` downloads that release's published binary for your
  platform into the ignored `.solar/`, after checking it against
  [`solar-releases.json`](../../solar-releases.json). The repository is one Foundry project at its root, so Earn, the Zone router
  and card spend share this build. Forge resolves the wrapper from its working directory: run it from
  the repository root, or set `FOUNDRY_SOLC` to the wrapper's absolute path, as CI does. Only the
  vendored Zones runtime rebuild, Rain's fixture build, and the PropAMM fixture rebuild keep solc,
  because they reproduce bytecode built outside this repository.
  CI installs that Foundry version through `.github/actions/setup` and the PropAMM fixture job, and the
  deployment tooling refuses an older Forge (`deployments/chain/foundry.ts`). A record's
  `foundryVersion` is provenance only. Every Foundry profile compiles for Cancun, the EVM version
  deployments target, so tests and the gas snapshot run on the deployed EVM version.
- **Node.js 22.23.4 or newer in the 22.x line**, pinned by `.nvmrc` and enforced by the root `engines` field.
- **pnpm 11** (`packageManager` in the root `package.json`). The workspace holds the shared deployment package (`deployments/`, named `@tempoxyz/contracts`),
  `localnet/`, and `e2e/`; viem and test tooling are pinned once in the `pnpm-workspace.yaml` catalog.
- **Docker**, for local end-to-end runs only.

The root [`foundry.lock`](../../foundry.lock) pins the Solidity dependencies; they are not
submodules. A fresh clone or Git worktree installs them before working:

```bash
pnpm install
pnpm deps   # scripts/solidity-deps.sh
```

Every dependency is public. Contract tests and every
local stack deploy the committed [DirectPropAMM fixture](../earn/modules/propamm.md#pinned-directpropamm-fixture),
so no PropAMM checkout or build is needed.

## Local Tempo and Zone

Local runs need Docker, Foundry, pnpm, and installed Solidity dependencies, and no credentials. Start a
disposable Tempo L1 and Zone, and run end-to-end cases against a local Earn stack with `pnpm e2e:local`, which runs the default cases on the `erc4626` variant. `--variant <kind>` selects another
[engine kind](../earn/integrations/engines.md), and `--variant all` runs every kind in turn; each variant
starts a fresh L1 and Zone. Each run writes its deployment manifest under the ignored `e2e/.local/`
and a structured JSON result under `e2e/.results/`. The pinned images and the `Environment.run` API
are in the [localnet reference](localnet.md).

## Required checks

Run `pnpm verify` before pushing a meaningful change. Its contract checks run from the repository
root over every domain. The default Foundry profile runs Earn and Zone router tests on the plain EVM
and skips `test/spend/`; the `spend` and `spend-ci` profiles run `test/spend/` on Tempo's hardfork.
The Contracts job in `verify.yml` covers the Zone router with Earn. Card spend has its own
checks ([src/spend/AGENTS.md](../../src/spend/AGENTS.md)), which the `spend.yml` workflow runs:
`FOUNDRY_PROFILE=spend forge build --sizes src/spend`, `FOUNDRY_PROFILE=spend-ci forge test`,
`script/spend/rain/build-fixture.sh --check`, the Bridge matrix against
[`docs/spend/bridge/matrix.md`](../spend/bridge/matrix.md), `pnpm e2e:cards -- --earn`,
`pnpm e2e:bridge -- --earn` and `script/spend/bridge/smoke.sh` (Docker).

`pnpm verify` runs the root
[`package.json`](../../package.json) `verify:contracts` and `verify:typescript` scripts in parallel, and
those scripts are the list of checks:

- `verify:contracts`: `forge fmt --check`, `forge lint --deny warnings`, one `forge build` of `src`,
  `script`, and `test`, the generated-ABI check
  (`abis:check`), the
  [EarnVault size check](#contract-size), `pnpm test:contracts` (the Earn and Zone router tests under
  `FOUNDRY_PROFILE=ci`, then the spend tests under `FOUNDRY_PROFILE=spend-ci`), and the [gas snapshot](#gas-baseline).
- `verify:typescript`: `pnpm check` (lint, formatting, and profile validation), `pnpm check:types`,
  `pnpm test` (every workspace's tests, including the documentation link and anchor check in
  `deployments/docs.test.ts`).

The RPC-environment compatibility test runs against real Forge when it is installed. TypeScript-only
CI skips that native probe, but always checks the environment helper. An installed Forge that fails
or reports the wrong RPC configuration still fails the test.

CI also runs the bounded symbolic fee proofs, the PropAMM fixture rebuild, the brutalized-memory
router fuzz, and local E2E ([continuous integration](#continuous-integration)); `pnpm verify` does
not. While iterating, use `forge test --match-path <path> -vvv`, then finish with the full suite.

`forge build` does not lint. [`foundry.toml`](../../foundry.toml) excludes a small set of lints, with the
reason for each; every other lint, including reentrancy with value, unchecked calls, delegatecall,
and divide-before-multiply, stays enabled and fails on any new finding. Contracts are not changed to
fix lints, so a lint category is enabled only when it passes clean.

Before an audit handoff or source freeze, also run `FOUNDRY_PROFILE=audit forge test`. It raises
fuzz tests to 10,000 runs and stateful invariants to 512 runs at depth 128. Stateful handler reverts
are allowed because rejected calls are part of the explored state space; every successful
transition must still preserve the asserted invariants.

### Contract size

`EarnVault` is the largest contract. Under `FOUNDRY_PROFILE=deploy` its runtime is 15,491 B, a 9,085 B
margin under the EIP-170 limit of 24,576 B, and its initcode is 15,522 B, a 33,630 B margin under the
EIP-3860 limit of 49,152 B. Every other runtime margin is at least 11,313 B (`EarnFees`).

`FOUNDRY_PROFILE=deploy forge build --sizes src/earn/core/EarnVault.sol` fails only when `EarnVault`
exceeds either hard limit; no check enforces a margin or sizes the other contracts. After changing
`src/`, run `FOUNDRY_PROFILE=deploy forge build --sizes src` and read both margin columns. A change
that would cross a limit moves its logic out of `EarnVault` into `EarnFees`, the engine, or
periphery, as the [permanent core decision](../earn/decisions.md#permanent-core-versus-optional-offchain-composition)
assigns it. The compiler, its settings and remappings feed every contract's bytecode and metadata
hash, which the reviewed factory releases pin: changing any of them, including bumping
`solar.lock`, needs a fresh [shared factory release](../deployment/deployment.md#shared-factory-releases).

### Gas baseline

The measurement of record is [`snapshots/`](../../snapshots), which the `test/spend/gas/` tests write
on real TIP-20 precompiles under Tempo's hardfork, where each storage slot written from zero costs
250,000 gas: the EarnVault, async and fee paths, rewards, the Zone router's Earn and spend paths, and
the Bridge and Rain card spends. Each call is measured with `gasleft`. After a material contract
change, run `forge build --force` and `FOUNDRY_PROFILE=spend forge test --match-path 'test/spend/gas/*'`,
then review and commit the changed `snapshots/*.json`.

[`.gas-snapshot`](../../.gas-snapshot) records the `test/earn/gas/` and `test/zone/gas/` benchmarks: fee
checkpointing on deposit, redeem, and contribution, the Veda engine and full-stack paths, including
queued-request forwarding, and the SingleZoneEarnRouter and ZoneRouter Earn deposit and redeem callbacks.
They run on mock tokens on the plain EVM, so they miss the new-slot charge and compare relative compute
only. `pnpm gas:snapshot` checks it; update it with `pnpm gas:update` (with the [toolchain](#toolchain)
Foundry and solar versions), never a bare `forge snapshot`. Values are whole test-case gas before EIP-3529
refunds: compare the same row across revisions, not against production receipts.

### Coverage

`pnpm coverage` prints a per-contract summary and writes `out/coverage/lcov.info` using the
`coverage` Foundry profile. That profile compiles with `--ir-minimum` and skips only
`SingleZoneEarnRouterAbiFuzz.t.sol`, whose fuzz entry point is too deep for the stack without the
optimizer; the router stays covered by its other suites. Tests and deployment scripts are excluded
from the report. Coverage is informational and not a required check.

## Formal specifications

Earn, the Zone router and the card contracts carry formal specifications for `solar-verify`, Solar's
deductive verifier ([paradigmxyz/solar#2530](https://github.com/paradigmxyz/solar/pull/2530)). The
specs are NatSpec in the contracts themselves: `@custom:ensures`, `@custom:requires`,
`@custom:invariant`, `@custom:ghost`, `@custom:trusted` and the rest, with loop invariants, asserts
and ghost updates as `///` comments inside function bodies, written against the contracts' own
constants and expressions. Spec-only helper functions are never called, so the specs change no
behavior, but like any source edit they change a contract's compiled output (its metadata hash at
least) and so the release addresses derived from it. Keep spec-only helpers inside the contract
that uses them, not in a library or another file. The verifier reads the flattened source as it
is, with no patches or generated files.

```bash
# from the repository root
forge flatten src/earn/core/EarnVault.sol -o /tmp/EarnVault.sol
solar-verify --jobs 8 --timeout 120000 /tmp/EarnVault.sol                         # every function
solar-verify --timeout 120000 --only EarnVault.contribute /tmp/EarnVault.sol      # one function
```

Build `solar-verify` from that pull request (`cargo build --release -p solar-verify`) and put Z3 on
`PATH`; its README documents the spec language. A proof covers the flattened source under the
trusted base the verifier documents (trusted library summaries, interfaces on external calls), not
deployed bytecode. A function or property the verifier can't prove says so in its NatSpec
("Not proved:"). When a change breaks a spec, fix the code or the spec in the same change.

## Test map

Solidity tests mirror the `src/` domains under `test/`: `core/`, `engines/<kind>/`, `router/`,
`rewards/`, and the `gas/` benchmarks, with shared mocks in `helpers/` and the PropAMM fixture in
`fixtures/propamm/`. Fee-enabled and async EarnVault stateful invariants are in
`test/earn/core/EarnVaultInvariant.t.sol`, and the [core invariant map](../earn/architecture/system.md#enforcing-tests)
lists the tests that assert each core invariant.

E2E cases live in [`e2e/modules/`](../../e2e/modules/), with per-engine behavior in `e2e/engines/`;
`pnpm -s e2e:local -- --list` lists them. Run a local group with
`pnpm e2e:local -- --group <group>` (add `--variant <kind>`), or a profile's launch set with
`pnpm e2e:profile profiles/<id>/profile.json --launch`. `e2e/harness/modules.test.ts` checks that
every committed profile's launch capabilities have cases.

## E2E validation

Hosted E2E validation is required when changing deployed addresses, deployment scripts, or the
fixture bootstrap; Zone payloads, authentication, polling, callback gas, or router callback
behavior; router or conversion-pool fixture setup; or reward contribution behavior. Run one case
while iterating, then its composed group. Case semantics, selection flags, profile acceptance, and
hosted configuration are in [E2E environments](../deployment/e2e-environments.md).

## Continuous integration

Branch protection on `main` requires `Required / Core` and `Required / Local E2E`; the repository
ruleset also requires `Actions security / Scan GitHub Actions / Scan GitHub Actions` and
`dependency-scan / Dependency Scan`.

| Workflow                  | Trigger                                                                                                                               | Runs                                                                                                                                                                                                                                                                                                                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pull-request.yml`        | Pull request                                                                                                                          | Verify, Actions security, dependency scan, `Required / Core` over those three                                                                                                                                                                                                                                                                                               |
| `verify.yml`              | Called by Pull Request and Main; manual                                                                                               | Contracts (Earn and the Zone router), PropAMM fixture, Symbolic, TypeScript checks, and TypeScript tests, under `FOUNDRY_PROFILE=ci`                                                                                                                                                                                                                                        |
| `local-zone.yml`          | Pull request; push to `main`                                                                                                          | On a pull request, two shards per engine kind and `Required / Local E2E` over them; on `main`, only a `deploy`-profile build that warms the Forge cache                                                                                                                                                                                                                     |
| `main.yml`                | Push to `main`                                                                                                                        | Verify                                                                                                                                                                                                                                                                                                                                                                      |
| `scan-github-actions.yml` | Called by Pull Request; weekly; manual                                                                                                | The shared GitHub Actions scan                                                                                                                                                                                                                                                                                                                                              |
| `zones-compatibility.yml` | Push to `main` touching `src/`, the Foundry and solar configuration, the deps script, itself, or the remediation-event action; manual | Builds Earn's contracts (`src/earn/`, `src/demo/`) with Tempo's script and runs Tempo's `earn_zone_e2e` integration tests                                                                                                                                                                                                                                                   |
| `deploy.yml`              | Manual (`main` only)                                                                                                                  | The [whole hosted stack](../deployment/deployment.md#deploying-the-hosted-stack-from-ci) on Moderato, mainnet, or both: every factory release, the `ZoneRouterFactory`, and every committed profile, reconciled and idempotent, then a pull request recording what changed                                                                                                  |
| `zone-router-release.yml` | Manual (`main` only)                                                                                                                  | One of the [Zone router](../zone/README.md)'s parameterized [ownerless contracts](../deployment/deployment.md#zone-router-releases), a `SendSpender` or a `ZoneRouter`, with its parameters, on Moderato, mainnet, or both, simulated or broadcast and source verified                                                                                                      |
| `bridge-release.yml`      | Manual (`main` only)                                                                                                                  | [Card spend](../spend/README.md)'s ownerless Bridge "TS" handler, or a Bridge program (`BridgeProvider` and `CardSpender`), at its [deterministic address](../spend/bridge/deploy.md#deploying-from-ci) on Moderato or mainnet, simulated or broadcast and source verified, with the calls Bridge's roles submit in its summary                                             |
| `hosted-e2e.yml`          | Manual (`main` only)                                                                                                                  | The [hosted E2E cases](../deployment/e2e-environments.md#profile-acceptance) against one committed profile, or only its read-only validation                                                                                                                                                                                                                                |
| `e2e-benchmarks.yml`      | Daily; manual (`main` only)                                                                                                           | Hosted [user-perceived latency benchmarks](../deployment/benchmarks.md#ci)                                                                                                                                                                                                                                                                                                  |
| `spend.yml`               | Pull request; push to `main`                                                                                                          | When the change touches card spend or its inputs (`src/`, `vendor/`, `test/spend/`, `snapshots/`, `e2e/spend/`, `localnet/`), [Card spend](../spend/README.md)'s build with sizes, tests, Rain fixture and Bridge matrix checks, Rain E2E, Bridge Zone E2E, and Bridge smoke run; on a pull request, `Required / Spend` over them always reports, passing when out of scope |

- **Verify jobs.** Contracts runs the same steps as `verify:contracts`, except that its Forge test
  step skips `test/earn/gas/` and `test/zone/gas/`, which the gas snapshot step runs. A pull request that changes `src/` also
  fuzzes the whole `SingleZoneEarnRouterAbiFuzzTest` contract over brutalized memory at 4,096 runs;
  `main` does not, so `main` never waits on it. Symbolic proves the
  `EarnFeeMathFuzzTest` `prove*` properties with z3 at a loop bound of 32. TypeScript checks and
  build typechecks one workspace at a time (local `pnpm check:types` runs them in parallel).
- **PropAMM fixture.** The job fetches the
  [pinned PropAMM commit](../earn/modules/propamm.md#pinned-directpropamm-fixture) from the public
  source repository without a token and fails when the committed
  fixture differs from its build (`test/earn/fixtures/propamm/update.sh --check`).
- **Local E2E scope.** Each shard runs `pnpm e2e:local -- --variant <kind> --all --shard <n>/2` over
  the pinned images and installs only the `e2e` workspace closure. `.github/actions/e2e-scope` runs
  the shards only when the pull request touches `src/` or `script/` outside card spend, `deployments/`,
  `profiles/`, `test/earn/fixtures/propamm/`, `e2e/`, `localnet/`,
  `scripts/solidity-deps.sh`, `.github/actions/`, `local-zone.yml`, or the build configuration
  (`foundry.toml`, `foundry.lock`, `solar.lock`, `solar-releases.json`, `solar-solc`, `package.json`,
  `pnpm-lock.yaml`, `pnpm-workspace.yaml`, `.nvmrc`). An out-of-scope shard passes without running, so
  `Required / Local E2E` still reports.
- **Secrets.** Pull Request, Verify, and Local E2E execute contributor code and receive no secrets.
  The
  benchmark and hosted E2E jobs receive `TEMPO_API_KEY`; the hosted E2E job also receives the shared `DEPLOYER_PRIVATE_KEY` and the environment's `END_USER_PRIVATE_KEY`, but no RPC
  credentials; the deploy, Zone router release and Bridge release jobs receive the shared
  `DEPLOYER_PRIVATE_KEY` and RPC credentials from the `factory-release-<network>` environment, which
  accepts only `main` and has no required reviewer, so dispatching a release is its approval. Those
  secrets reach only the steps that send or run cases, and the deploy and hosted E2E jobs restore no
  dependency or build cache (`.github/actions/setup` with `caches: 'false'`): they download solar and
  check it against `solar-releases.json`, build from scratch, and install from the lockfile. The deploy
  workflow's record job, with no secrets, may push a
  `deploy/<run>-<attempt>` branch and open its pull request; the remediation-event job receives the
  `EVENTS_*` intake credentials.
- **Forks.** A pull request from a fork runs the same pull request jobs with no secrets, no OIDC
  token, and a read-only `GITHUB_TOKEN`, and can pass every required check. Without an OIDC token,
  each job's secure runner starts Harden Runner with the inline audit egress policy instead of the
  StepSecurity policy store and installs no package firewall, with a warning annotation.
- **Zones compatibility.** The job checks out Tempo `main` and builds with the Foundry nightly
  Tempo's own CI pins. A failed run on `main` publishes a `zones_compatibility_failure` remediation
  event.

Dependency policy lives with explanatory comments in [`pnpm-workspace.yaml`](../../pnpm-workspace.yaml)
and [`.github/dependabot.yml`](../../.github/dependabot.yml). Prefer upgrades over overrides; keep any
unavoidable override or exception version-specific and documented, and remove it when the parent
accepts a patched or attested release. An urgent security fix younger than the seven-day
release-age gate needs a reviewed, narrowly scoped exception rather than a lower gate.

## Review checklist

For contract changes, reviewers should be able to answer:

1. Where does every asset sit before, during, and after the call?
2. Which role can redirect or strand backing?
3. Does active EarnShare supply remain aligned with active engine shares, with pending claims excluded from both?
4. Can a failed external call leave accounted funds rescueable or double-claimable?
5. Does the change create a new public link between private actions?
6. Is the behavior tested at the real venue boundary, not only with a permissive mock?
7. Can any deposit, loss, valuation spike, rounding cadence, or configuration change overcharge positive-accrual fees?
