# Working in this repository

This repository holds Tempo's contracts and the tooling that builds, deploys, and tests them: one
Foundry project at the root (`foundry.toml`, `foundry.lock`, `lib/`, and the solar release pinned by
`solar.lock` and `solar-releases.json` behind `solar-solc`), the pnpm workspace (`deployments/`,
`localnet/`, `e2e/`), the deployment `profiles/`, the docs (`docs/`), CI, and
`scripts/solidity-deps.sh` (`pnpm deps`), which installs the pinned Solidity dependencies and the
solar compiler. [README.md](README.md) maps the repository.

The Solidity is split into three domains. Each keeps its interfaces in `src/interfaces/<domain>/`
(outside systems in `src/interfaces/external/`), its tests in `test/<domain>/`, and its scripts in
`script/<domain>/`:

- **Earn** (`src/earn/`): the EarnVault and EarnShare over replaceable yield venues, with the demo
  contracts it tests against in `src/demo/` (built, never deployed).
- **Zone** (`src/zone/`): the Zone router, its withdrawal callbacks for Earn and spends, and the
  generic spenders a spend pays through (`src/zone/spenders/`, such as `SendSpender`).
- **Spend** (`src/spend/`): card spend, with a provider-agnostic core (`CardSpender`, `CardFactory`,
  `CardSpend`), our code for each card provider (`src/spend/providers/<provider>/`), and each
  provider's own contracts vendored unmodified (`vendor/<provider>/`).

## Find the applicable instructions

Before editing, read the guides along the target file's directory path, from root to leaf. Child
guides add local rules; they do not repeat their parents. A session started at the repository root
must explicitly discover descendant guides rather than assume they were loaded.

| Area                                                                         | Guide                                          |
| ---------------------------------------------------------------------------- | ---------------------------------------------- |
| Earn Solidity implementation                                                 | [src/earn/AGENTS.md](src/earn/AGENTS.md)       |
| Earn contract tests                                                          | [test/earn/AGENTS.md](test/earn/AGENTS.md)     |
| Earn Foundry deployment scripts                                              | [script/earn/AGENTS.md](script/earn/AGENTS.md) |
| Earn's local fixture contracts and scripts                                   | [script/earn/local/](script/earn/local/)       |
| Zone router and its spenders, with their tests and scripts                   | [src/zone/AGENTS.md](src/zone/AGENTS.md)       |
| Card spend: core, providers (Bridge, Rain), vendored code, tests and scripts | [src/spend/AGENTS.md](src/spend/AGENTS.md)     |
| Shared deployment tooling                                                    | [deployments/AGENTS.md](deployments/AGENTS.md) |
| Deployment profiles and records                                              | [profiles/AGENTS.md](profiles/AGENTS.md)       |
| Integration cases and hosted environments                                    | [e2e/AGENTS.md](e2e/AGENTS.md)                 |
| Disposable chain lifecycle                                                   | [localnet/AGENTS.md](localnet/AGENTS.md)       |
| CI and repository automation                                                 | [.github/AGENTS.md](.github/AGENTS.md)         |

For Earn application onboarding, use [SKILL.md](SKILL.md) and the
[integrator guide](docs/earn/integrations/agent-guide.md).

## Rules for every change

- **The build is the deployment identity.** The compiler (`solar.lock`, `solar-releases.json`),
  `foundry.toml`'s remappings, source paths, and settings, and each contract's source path feed its
  metadata hash, and so its deterministic address and every reviewed release. Change them only on
  purpose, with a fresh [shared factory release](docs/deployment/deployment.md#shared-factory-releases);
  never move a released contract's source to tidy up. Compile only with a published solar release
  checked against `solar-releases.json`, never a branch build, and run `forge build --force` after
  any compiler change.
- **Run Forge from the root.** Run every `forge` command from the repository root, after `pnpm deps`.
  The default profile runs Earn and Zone tests on the plain EVM; `FOUNDRY_PROFILE=spend` (or
  `spend-ci`) runs `test/spend/` on Tempo's hardfork.
- **Imports flow one way.** `src/earn/` imports neither `src/zone/` nor `src/spend/`, `src/zone/`
  imports only Earn's interfaces, and `src/spend/` imports both, always by relative path, never a
  copy. Shared Solidity belongs in the domain that owns it until a second owner needs it.
- **Provider code stays under its provider.** Our code lives in `src/spend/providers/<provider>/` and
  its vendored contracts in `vendor/<provider>/`. `src/earn/` and the spend core stay
  provider-agnostic, and core contracts and shared tooling stay integrator-agnostic: per-deployment
  configuration lives in deployment profiles.
- **Zones hide activity from outsiders, not their sequencer.** Preserve the
  [privacy model](docs/earn/architecture/security-and-privacy.md), including public amount and timing
  leakage. No contract emits or stores a callback `senderTag`.
- **Everything here is public.** Keep secrets and funded private keys out of source, logs, and
  generated records, and name no customer in code, tests, docs, commits, or pull requests.

## Changing contracts

- Start from the simplest design that does the job. Every contract, function, storage field, and
  check must justify itself; remove what cannot rather than keeping it for later.
- Keep each contract's deployment shape (EarnVault's fixed proxy, EarnFees' clone, ownerless
  immutable routers and card programs). Do not introduce new clone, proxy, or immutable-args
  patterns to save gas.
- A check stays unless it is redundant on every path. Payments can be imitated (fee minting can
  look like a payment to a balance check), so prove redundancy before removing a check for gas.
- Keep events, errors, and ABIs stable: indexers and Tempo API decode them. Change one only together
  with its consumers, and check the [external consumers](#external-consumers) before removing a
  contract or interface.
- A change to a function with [formal specifications](docs/development/README.md#formal-specifications)
  reruns `solar-verify` on it. Fix the code or the spec in the same change; a change that leaves a
  proved property unproved does not ship.

### Gas

Tempo charges 250,000 gas for each storage slot written from zero, allowances included, so storage
writes dominate every path users pay for.

- Pack fields that change together into one slot, reuse values already read, read callback and spend
  data from calldata, use transient storage for locks and in-call bookkeeping, and hold values fixed
  at deployment in immutables.
- Keep a standing allowance only to a spender that cannot change and moves tokens only inside the
  holder's own call, and keep a one-unit residue where a balance or allowance would otherwise return
  to zero; the domain guides say where each is allowed. Set an allowance with `approve` first, and
  reset it to zero before setting it only when the token rejects that (reverts, returns false, or
  returns no data).
- Measure with the real TIP-20 gas tests in `test/spend/gas/`, after `forge build --force`:
  `FOUNDRY_PROFILE=spend forge test --match-path 'test/spend/gas/*'` rewrites `snapshots/`, the
  measurement of record. The `test/earn/gas/` and `test/zone/gas/` benchmarks use mock tokens on the
  plain EVM and miss the new-slot charge; update their baseline with `pnpm gas:update`, never a bare
  `forge snapshot` ([gas baseline](docs/development/README.md#gas-baseline)). Ship an optimization
  only when it saves a meaningful amount (about 1% or more) on a path users pay for, without
  weakening a check, an event, or a proof, and update the docs that quote the measured figures.

## Validation and documentation

Use the commands in [development](docs/development/README.md). Start with focused checks; before
pushing meaningful implementation changes, run `pnpm verify`, plus the domain's own checks for
the Zone router ([src/zone/AGENTS.md](src/zone/AGENTS.md)) and card spend
([src/spend/AGENTS.md](src/spend/AGENTS.md)). Hosted or private behavior changes also need the
relevant E2E case and composed group. When a check fails, compare it with `main` and tell a tool
failure or timeout from a regression. Report unrun checks and external blockers explicitly; after
pushing a PR update, report with CI pending unless asked to monitor it. For documentation-only
changes, run the link check (`pnpm --filter @tempoxyz/contracts test --run docs`), format changed
files, and run `git diff --check`.

Follow the [documentation rules](docs/README.md#documentation-rules) and update the page that
owns the changed behavior. Read implementation and tests together; resolve contradictions rather
than preserving stale text. Removing an integration means removing every reference to it.

## Pull requests

- One concern per pull request, on a branch from a freshly fetched `origin/main`. Keep
  optimizations apart from behavior changes so each can be reviewed and reverted alone.
- Before pushing to a PR branch, check `gh pr view --json state`; if the PR is merged or closed,
  branch from `main` and open a new PR.
- After a rebase, regenerate generated files (`.gas-snapshot`, ABIs, fixtures) rather than resolving
  their conflicts by hand.
- Address every review item, and test the edge state it names, not only the ordinary path.
- A config or pin change touches only what was asked; propose wider follow-ups separately.
  [CONTRIBUTING.md](CONTRIBUTING.md#commits-and-pull-requests) owns the commit and title format.

## External consumers

Other repositories depend on these surfaces; keep them stable or change them together with their
consumers. [`e2e/harness/workflows-contract.test.ts`](e2e/harness/workflows-contract.test.ts) pins
the automation entry points.

- Devnet automation runs `pnpm e2e:devnet -- --group zone` and `pnpm devnet:deploy` against an
  existing devnet and reads each case's ID and status from the `e2e/.results/` run result. Their
  inputs and output files are in
  [existing devnet chains](docs/deployment/e2e-environments.md#existing-devnet-chains).
- Localnet consumers import `localnet/src/index.ts` and call
  `Environment.run({ consumer, sameAssetRoute, ready })`, or use the root `./localnet` export
  ([localnet layer](docs/development/localnet.md#localnet-layer)).
- Deployment repositories pin this repository as a submodule, install its Solidity dependencies
  with `pnpm deps`, and run `pnpm earn`, `pnpm e2e:profile`, and `pnpm profiles --profiles profiles`
  against the profiles they hold
  ([profiles in another repository](profiles/README.md#profiles-in-another-repository)).
- Tempo node builds point their `EARN_ROOT` at this repository's root, compile `src/earn/` and
  `src/demo/`, and consume the `SingleZoneEarnRouter` and `DemoParPool` outputs.

## Guide maintenance

Add an agent instruction only when it prevents a recurring mistake that code, tests, or existing
documentation do not already address, at the narrowest useful scope. This guide holds
repository-wide boundaries and guide discovery; a domain guide holds that domain's boundaries; a
scoped guide holds rules specific to its subtree and links the canonical document instead of
restating it. Mechanically enforceable properties belong in tests, lint, schemas, or CI. Sibling
directories such as `src/`, `test/`, and `script/` do not inherit one another's guides, so they
link shared rules explicitly. When moving a rule, update its references and preserve its security or
accounting meaning; remove obsolete or contradictory guidance rather than appending exceptions.
