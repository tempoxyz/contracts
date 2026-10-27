# Working in this repository

This repository holds Tempo's contract projects and the tooling they share. Each project is its own
Foundry project with its own build settings, dependencies, and guide:

- [earn/](earn/AGENTS.md): Tempo Earn, the EarnVault and EarnShare over replaceable yield venues.
- [spend/](spend/AGENTS.md): Tempo Spend, card spend through Bridge's spender contracts.
- [router/](router/AGENTS.md): the Zone router, Zone withdrawal callbacks for Earn and spends.

Shared at the root: the pnpm workspace, the deployment lifecycle (`deployments/`, with one module
folder per project) and its `profiles/`, the app (`app/`), the disposable Tempo L1 and Zone
(`localnet/`), the E2E harness (`e2e/`), the docs (`docs/`), CI, and `scripts/solidity-deps.sh`, which
installs each project's pinned Solidity dependencies. [README.md](README.md) maps the repository.

## Find the applicable instructions

Before editing, read the guides along the target file's directory path, from root to leaf. Child
guides add local rules; they do not repeat their parents. A session started at the repository root
must explicitly discover descendant guides rather than assume they were loaded.

| Area                                                            | Guide                                    |
| --------------------------------------------------------------- | ---------------------------------------- |
| Tempo Earn, including its app, deployment modules, and profiles | [earn/AGENTS.md](earn/AGENTS.md)         |
| Tempo Spend (Bridge card spend)                                 | [spend/AGENTS.md](spend/AGENTS.md)       |
| Zone router                                                     | [router/AGENTS.md](router/AGENTS.md)     |
| Integration cases and hosted environments                       | [e2e/AGENTS.md](e2e/AGENTS.md)           |
| Disposable chain lifecycle                                      | [localnet/AGENTS.md](localnet/AGENTS.md) |
| CI and repository automation                                    | [.github/AGENTS.md](.github/AGENTS.md)   |

## Keep projects separate

- Run every `forge` command from the project directory. Never merge one project's remappings,
  dependencies, or hardfork into another's `foundry.toml`: Earn's remappings and source paths feed
  the metadata hash of its reviewed releases.
- A project imports another's contracts through a remapping to its `src/`, never a copy. Shared
  Solidity belongs in the project that owns it until a second owner needs it.
- Integrator-specific code stays in its own project; `earn/` stays integrator-agnostic and never
  imports from `spend/`.
- Secrets and funded private keys stay out of source, logs, and generated records.

## Validation and documentation

Use the commands in [development](docs/development/README.md). Start with focused checks; before
pushing meaningful implementation changes, run `pnpm verify`, plus the project's own checks for
`spend/` ([spend/AGENTS.md](spend/AGENTS.md)) and `router/` ([router/AGENTS.md](router/AGENTS.md)).
Hosted or private behavior changes also need the relevant E2E case and composed group. Report unrun checks and external blockers explicitly; after
pushing a PR update, report with CI pending unless asked to monitor it. For documentation-only
changes, run the link check (`pnpm --filter @tempoxyz/earn test --run docs`), format changed files,
and run `git diff --check`.

Follow the [documentation rules](docs/earn/README.md#documentation-rules) and update the page that
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
- Tempo node builds compile `earn/src/` (their `EARN_ROOT` is this repository's `earn/`) and consume
  the `SingleZoneEarnRouter` and `DemoParPool` outputs.

## Guide maintenance

Add an agent instruction only when it prevents a recurring mistake that code, tests, or existing
documentation do not already address, at the narrowest useful scope. This guide holds
repository-wide boundaries and guide discovery; a project guide holds that project's boundaries; a
scoped guide holds rules specific to its subtree and links the canonical document instead of
restating it. Mechanically enforceable properties belong in tests, lint, schemas, or CI. Sibling
directories such as `src/`, `test/`, and `script/` do not inherit one another's guides, so they
link shared rules explicitly. When moving a rule, update its references and preserve its security or
accounting meaning; remove obsolete or contradictory guidance rather than appending exceptions.
