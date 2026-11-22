# Working in this repository

This repository holds Tempo's contracts and the tooling they share, in one Foundry project at the
repository root (`foundry.toml`, `foundry.lock`, `lib/`, and the solar compiler pinned by
`solar.lock` behind `solar-solc`). Its Solidity is split into domains, each with its own guide:

- [Earn](src/earn/AGENTS.md) (`src/earn/`): Tempo Earn, the EarnVault and EarnShare over replaceable
  yield venues, with the demo contracts it tests against in `src/demo/` (built, never deployed).
- [Zone](src/zone/AGENTS.md) (`src/zone/`): the Zone router, Zone withdrawal callbacks for Earn and
  spends, and the generic spenders a spend pays through (`src/zone/spenders/`, such as `SendSpender`).
- [Spend](src/spend/AGENTS.md) (`src/spend/`): card spend on Tempo: our provider-agnostic contracts
  (`CardSpender`, `CardFactory`, `CardSpend`), our code for each card provider
  (`src/spend/providers/<provider>/`: Bridge's `BridgeProvider` and "TS" handler, Rain's
  `RainProvider`), each provider's own contracts vendored as they are (`vendor/<provider>/`), and the
  card programs on the reservation core (`src/spend/programs/`: `CardAuth` and its funding sources).

Each domain's interfaces live in `src/interfaces/<domain>/` (`earn`, `zone`, `spend`), and those of
outside systems in `src/interfaces/external/`. Tests and scripts follow the same split: `test/earn/`,
`test/zone/`, `test/spend/`, `script/earn/`, `script/zone/`, and `script/spend/`.

Also at the root: the pnpm workspace, the deployment lifecycle (`deployments/`, with module folders
for Earn and the Zone router) and its `profiles/`, the disposable Tempo L1 and Zone (`localnet/`), the
E2E harness (`e2e/`), the docs (`docs/`), CI, and `scripts/solidity-deps.sh` (`pnpm deps`), which
installs the pinned Solidity dependencies and the solar compiler. [README.md](README.md) maps the
repository.

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

## Keep domains separate

- Run every `forge` command from the repository root, after `pnpm deps` installs `lib/` at the
  revisions `foundry.lock` pins. The default profile runs Earn and Zone tests on the plain EVM;
  `FOUNDRY_PROFILE=spend` (or `spend-ci`) runs `test/spend/` on Tempo's hardfork.
- The remappings, source paths, and compiler settings in `foundry.toml` feed the metadata hash of
  every reviewed release and deterministic address. Never change them, or move a released
  contract's source, without accounting for the addresses that change moves.
- Domains import each other's contracts by relative path, never a copy. Shared Solidity belongs in
  the domain that owns it until a second owner needs it.
- Imports flow one way: `src/earn/` imports neither `src/zone/` nor `src/spend/`, `src/zone/` imports
  only Earn's interfaces, and `src/spend/` imports both. Generic spenders live in
  `src/zone/spenders/`; a card program's spender is its `CardSpender` (`src/spend/`), which implements
  the Zone router's `ISpender`.
- Provider-specific code stays under its provider: our code in `src/spend/providers/<provider>/` and
  its vendored contracts in `vendor/<provider>/`. `src/earn/` and the spend core (`src/spend/` outside
  `providers/`) stay provider-agnostic.
- Secrets and funded private keys stay out of source, logs, and generated records.

## Preserve Earn's boundaries

- EarnVault alone issues EarnShare; its current engine holds venue shares. Managed backing,
  quarantined surplus, and pending claims remain separate. The canonical rules live in
  [system](docs/earn/architecture/system.md), [fees](docs/earn/architecture/fees.md), and
  [flows](docs/earn/architecture/flows.md).
- Core contracts and shared tooling are integrator-agnostic. Venue behavior belongs in engines,
  private conversion in the scoped router, and per-deployment configuration in deployment profiles.
- Tempo API owns offchain reward policy and operations. This repository owns reward contracts,
  deployment surfaces, and contract-focused tests; do not recreate an offchain reward service.
- Use `viem/tempo` for shared Earn client capabilities. Keep Node-only deployment operations, and
  Solidity in their existing layers.
- The shared lifecycle owns deployment reconciliation and verified records. The stack each hosted
  E2E run builds from a profile is a separate projection; never bypass verification by editing
  outputs.
- Never hand-write a contract ABI in TypeScript: import it from `@tempoxyz/contracts/abis` and
  regenerate after interface changes ([deployments README](deployments/README.md#exports)).
- External authority handoffs must be completed by their actual owners.
- Core Zones owns hosted Zone infrastructure, and the Zone administrator and pool owner their
  admission and inventory. CI, deployment projection, and hosted E2E never hold a hosted Zone
  administrator or pool owner key, and never disable policy, admission, or gateway checks or repair
  Zone infrastructure to pass.
- Zones hide activity from outsiders, not their sequencer. Preserve the
  [privacy model](docs/earn/architecture/security-and-privacy.md), including public amount/timing
  leakage and the prohibition on publicly emitting callback `senderTag`.

## Validation and documentation

Use the commands in [development](docs/development/README.md). Start with focused checks; before
pushing meaningful implementation changes, run `pnpm verify`, plus the domain's own checks for
the Zone router ([src/zone/AGENTS.md](src/zone/AGENTS.md)) and card spend
([src/spend/AGENTS.md](src/spend/AGENTS.md)). Hosted or private behavior changes also need the
relevant E2E case and composed group. Report unrun checks and external blockers explicitly; after
pushing a PR update, report with CI pending unless asked to monitor it. For documentation-only
changes, run the link check (`pnpm --filter @tempoxyz/contracts test --run docs`), format changed files,
and run `git diff --check`.

Follow the [documentation rules](docs/README.md#documentation-rules) and update the page that
owns the changed behavior. Read implementation and tests together; resolve contradictions rather
than preserving stale text. Removing an integration means removing every reference to it.

Before pushing to a PR branch, check `gh pr view --json state`; if the PR is merged or closed,
branch from `main` and open a new PR. A config or pin change touches only what was asked; propose
wider follow-ups separately.

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
