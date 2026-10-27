# Development and validation

This page owns the toolchain, the checks a change must pass, and continuous integration.
[CONTRIBUTING.md](../../CONTRIBUTING.md) is the short path for a first change; the
[app](app-browser.md), [Worker](app-runtime.md), and
[localnet](localnet.md) references hold implementation constraints for those packages.

## Toolchain

- **Solidity** `0.8.36`, compiled by [solar](https://github.com/paradigmxyz/solar) at the revision
  [`earn/solar.lock`](../../earn/solar.lock) pins, with **Foundry v1.8.6**. Forge calls solar through
  [`earn/solar-solc`](../../earn/solar-solc), which presents it as solc `0.8.36`; solar's code
  removes most of solc's stack shuffling, internal jumps and address masking, so the same work costs
  less gas and executes faster. `pnpm deps` builds that revision once with cargo (Rust stable) into
  the ignored `.solar/`. Forge resolves the wrapper from its working directory: run it from `earn/`,
  or set `FOUNDRY_SOLC` to the wrapper's absolute path, as CI does. Spend and the router compile
  with solc.
  CI installs that Foundry version through `.github/actions/setup` and the PropAMM fixture job, and the
  deployment tooling refuses an older Forge (`deployments/chain/foundry.ts`). A record's
  `foundryVersion` is provenance only. Every Foundry profile compiles for Cancun, the EVM version
  deployments target, so tests and the gas snapshot run on the deployed EVM version.
- **Node.js 22.23.4 or newer in the 22.x line**, pinned by `.nvmrc` and enforced by the root `engines` field.
- **pnpm 11** (`packageManager` in the root `package.json`). The workspace holds Earn's app
  (`app/`), Earn's deployment package (`deployments/`, named `@tempoxyz/earn`),
  `localnet/`, and `e2e/`; viem,
  Cloudflare, and test tooling are pinned once in the `pnpm-workspace.yaml` catalog.
- **Docker**, for local end-to-end runs only.

Each Foundry project (`earn/`, `spend/`, `router/`) pins its Solidity dependencies in its own `foundry.lock`; they
are not submodules. A fresh clone or Git worktree installs them before working:

```bash
pnpm install
pnpm deps   # scripts/solidity-deps.sh earn spend router
```

Every dependency is public. Contract tests and every
local stack deploy the committed [DirectPropAMM fixture](../earn/modules/propamm.md#pinned-directpropamm-fixture),
so no PropAMM checkout or build is needed.

## App environment

`pnpm dev` runs the app against hosted Moderato. Create the ignored local file (the template
carries the public Privy application ID), set `TEMPO_API_KEY` in it, and restart the dev server
after any change:

```bash
cp app/.env.example app/.env.local
pnpm dev
```

The Worker returns the public `PRIVY_APP_ID` to the browser; browser-owned Privy signing needs no
application secret. Bindings, secrets, and production builds are in the
[Worker reference](app-runtime.md#configuration-and-secrets).

## Local Tempo and Zone

Local runs need Docker, Foundry, pnpm, and installed Solidity dependencies, and no credentials. Start a
disposable Tempo L1 and Zone, deploy and verify a local Earn stack, and run the app against it:

```bash
pnpm dev:local
pnpm dev:local -- --smoke   # stop after setup and verification
```

`pnpm e2e:local` runs the default cases on the `erc4626` variant. `--variant <kind>` selects another
[engine kind](../earn/integrations/engines.md), and `--variant all` runs every kind in turn; each variant
starts a fresh L1 and Zone. Each run writes its deployment manifest under the ignored `e2e/.local/`
and a structured JSON result under `e2e/.results/`. The pinned images and the `Environment.run` API
are in the [localnet reference](localnet.md).

## Required checks

Run `pnpm verify` before pushing a meaningful change. Its contract checks run in Earn's Foundry
project (`earn/`); `spend/` and `router/` have their own checks ([spend/AGENTS.md](../../spend/AGENTS.md),
[router/AGENTS.md](../../router/AGENTS.md)), which the `spend.yml` and `router.yml` workflows run. It runs the root
[`package.json`](../../package.json) `verify:contracts` and `verify:typescript` scripts in parallel, and
those scripts are the list of checks:

- `verify:contracts`: `forge fmt --check`, `forge lint --deny warnings`, one `forge build` of `src`,
  `script`, and `test` in `earn/`, a `forge build src script` in `router/`, the generated-ABI check
  (`abis:check`), the
  [EarnVault size check](#contract-size), `pnpm test:contracts` (every Forge test under
  `FOUNDRY_PROFILE=ci`), and the [gas snapshot](#gas-baseline).
- `verify:typescript`: `pnpm check` (lint, formatting, and profile validation), `pnpm check:types`,
  `pnpm test` (every workspace's tests, including the documentation link and anchor check in
  `deployments/docs.test.ts`), and `pnpm build`.

CI also runs the bounded symbolic fee proofs, the PropAMM fixture rebuild, the brutalized-memory
router fuzz, and local E2E ([continuous integration](#continuous-integration)); `pnpm verify` does
not. While iterating, use `forge test --match-path <path> -vvv`, then finish with the full suite.

`forge build` does not lint. [`foundry.toml`](../../earn/foundry.toml) excludes a small set of lints, with the
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

`FOUNDRY_PROFILE=deploy forge build --sizes src/core/EarnVault.sol` fails only when `EarnVault`
exceeds either hard limit; no check enforces a margin or sizes the other contracts. After changing
`src/`, run `FOUNDRY_PROFILE=deploy forge build --sizes src` and read both margin columns. A change
that would cross a limit moves its logic out of `EarnVault` into `EarnFees`, the engine, or
periphery, as the [permanent core decision](../earn/decisions.md#permanent-core-versus-optional-offchain-composition)
assigns it. The compiler, its settings and remappings feed every contract's bytecode and metadata
hash, which the reviewed factory releases pin: changing any of them, including bumping
`solar.lock`, needs a fresh [shared factory release](../deployment/deployment.md#shared-factory-releases).

### Gas baseline

[`.gas-snapshot`](../../earn/.gas-snapshot) records only the `test/gas/` benchmarks: fee checkpointing on
deposit, redeem, and contribution, and the Veda engine and full-stack paths, including
queued-request forwarding. `pnpm gas:snapshot` checks it. After a material contract change, run
`forge build --force` and `pnpm gas:update` with the [toolchain](#toolchain) Foundry and solar versions. Values
are whole test-case gas before EIP-3529 refunds: compare the same row across revisions, not against
production receipts.

### Coverage

`pnpm coverage` prints a per-contract summary and writes `earn/out/coverage/lcov.info` using the
`coverage` Foundry profile. That profile compiles with `--ir-minimum` and skips only
`SingleZoneEarnRouterAbiFuzz.t.sol`, whose fuzz entry point is too deep for the stack without the
optimizer; the router stays covered by its other suites. Tests and deployment scripts are excluded
from the report. Coverage is informational and not a required check.

## Test map

Solidity tests mirror the `src/` domains under `test/`: `core/`, `engines/<kind>/`, `router/`,
`rewards/`, and the `gas/` benchmarks, with shared mocks in `helpers/` and the PropAMM fixture in
`fixtures/propamm/`. Fee-enabled and async EarnVault stateful invariants are in
`test/core/EarnVaultInvariant.t.sol`, and the [core invariant map](../earn/architecture/system.md#enforcing-tests)
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

| Workflow                  | Trigger                                                                                                                                | Runs                                                                                                                                                                                                             |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pull-request.yml`        | Pull request                                                                                                                           | Verify, Actions security, dependency scan, `Required / Core` over those three, and Build Preview, which uploads the static `app/dist/client` artifact                                                            |
| `verify.yml`              | Called by Pull Request and Main; manual                                                                                                | Contracts, PropAMM fixture, Symbolic, TypeScript checks, the app and Worker build, and TypeScript tests, under `FOUNDRY_PROFILE=ci`                                                                              |
| `local-zone.yml`          | Pull request; push to `main`                                                                                                           | On a pull request, two shards per engine kind and `Required / Local E2E` over them; on `main`, only a `deploy`-profile build that warms the Forge cache                                                          |
| `preview.yml`             | `workflow_run` after Pull Request succeeds                                                                                             | Deploy Preview for same-repository pull requests                                                                                                                                                                 |
| `main.yml`                | Push to `main`                                                                                                                         | Verify, then Deploy Production                                                                                                                                                                                   |
| `scan-github-actions.yml` | Called by Pull Request; weekly; manual                                                                                                 | The shared GitHub Actions scan                                                                                                                                                                                   |
| `pr-audit.yml`            | Pull request label, push, or comment                                                                                                   | The Cyclops audit                                                                                                                                                                                                |
| `zones-compatibility.yml` | Push to `main` touching `earn/src/`, `earn/foundry.*`, `earn/solar*`, the deps script, itself, or the remediation-event action; manual | Builds `earn/`'s contracts with Tempo's script and runs Tempo's `earn_zone_e2e` integration tests                                                                                                                |
| `factory-release.yml`     | Manual (`main` only)                                                                                                                   | The [shared factory releases](../deployment/deployment.md#releasing-from-ci) on Moderato, mainnet, or both, simulated or broadcast and source verified, then a branch recording them in `releases.ts` for review |
| `e2e-benchmarks.yml`      | Daily; manual (`main` only)                                                                                                            | Hosted [user-perceived latency benchmarks](../deployment/benchmarks.md#ci)                                                                                                                                       |
| `spend.yml`               | Pull request or push to `main` touching `spend/` or its inputs                                                                         | The separate [`spend/`](../../spend/README.md) project's format, build, tests, card matrix, Zone E2E, and smoke run; not a required check                                                                        |
| `router.yml`              | Pull request or push to `main` touching `router/` or its Earn inputs                                                                   | The separate [`router/`](../../router/README.md) project's format, lint, build with sizes, and tests; not a required check                                                                                       |

- **Verify jobs.** Contracts runs the same steps as `verify:contracts`, except that its Forge test
  step skips `test/gas/`, which the gas snapshot step runs. A pull request that changes `src/` also
  fuzzes the whole `SingleZoneEarnRouterAbiFuzzTest` contract over brutalized memory at 4,096 runs;
  `main` does not, so production deploys never wait on it. Symbolic proves the
  `EarnFeeMathFuzzTest` `prove*` properties with z3 at a loop bound of 32. TypeScript checks and
  build typechecks one workspace at a time (local `pnpm check:types` runs them in parallel).
- **PropAMM fixture.** The job checks out the
  [pinned PropAMM commit](../earn/modules/propamm.md#pinned-directpropamm-fixture) with a short-lived
  read-only token and fails when the committed
  fixture differs from its build (`earn/test/fixtures/propamm/update.sh --check`).
- **Local E2E scope.** Each shard runs `pnpm e2e:local -- --variant <kind> --all --shard <n>/2` over
  the pinned images and installs only the `e2e` workspace closure. `.github/actions/e2e-scope` runs
  the shards only when the pull request touches Earn's `src/`, `script/`, `deployments/`,
  `profiles/`, `localnet/`, or `test/fixtures/propamm/`, the root `e2e/` or `localnet/`,
  `scripts/solidity-deps.sh`, `.github/actions/`, `local-zone.yml`, or the build configuration
  (`earn/foundry.toml`, `earn/foundry.lock`, `package.json`, `pnpm-lock.yaml`,
  `pnpm-workspace.yaml`, `.nvmrc`). An out-of-scope shard passes without running, so
  `Required / Local E2E` still reports.
- **Deployments.** Deploy Preview checks out and builds the Worker from the default branch, never
  from the pull request, and installs the pull request's static artifact only after rejecting
  symbolic links, non-regular files, files outside `client/`, and a missing `index.html`. It
  requires the preview Worker's `PRIVY_APP_ID` and `TEMPO_API_KEY` secrets, uploads a Worker version
  with the `pr-<number>` alias, and comments its URL. Deploy Production runs in the `production`
  environment after Verify. Both smoke-test `/` and `/health` and parse the live `/api/config` with
  `app/deployments/check-live-config.ts`.
- **Secrets.** Pull Request, Verify, and Local E2E execute contributor code and receive no secrets.
  Only the two deploy jobs receive the `DEV_CLOUDFLARE_*` credentials, which are secrets of the
  `production` and `preview` environments, and both environments deploy only from `main`; the
  benchmark job receives `TEMPO_API_KEY`; the factory release job receives the shared
  `DEPLOYER_PRIVATE_KEY` and RPC credentials from the reviewer-gated `factory-release-<network>`
  environment, and its registry job, with no secrets, gets a `GITHUB_TOKEN` that may push a
  `factory-release/<run>-<attempt>` branch; the audit and remediation-event jobs receive the
  `EVENTS_*` intake credentials.
- **Forks.** A pull request from a fork runs the same pull request jobs with no secrets, no OIDC
  token, and a read-only `GITHUB_TOKEN`, and can pass every required check. Without an OIDC token,
  each job's secure runner starts Harden Runner with the inline audit egress policy instead of the
  StepSecurity policy store and installs no package firewall, with a warning annotation. Three
  things do not run for a fork: the PropAMM fixture rebuild (the job passes when
  `test/fixtures/propamm/` is unchanged and fails otherwise, until a maintainer re-verifies the
  change from a branch in this repository), the preview deployment, and the label- and
  push-triggered Cyclops audit, which a maintainer starts with a `cyclops audit` comment.
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
