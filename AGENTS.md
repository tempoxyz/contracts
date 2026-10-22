# Working on Tempo Earn

Tempo Earn provides a stable EarnVault and native TIP-20 EarnShare over replaceable yield venues.
Use [README.md](README.md) for the repository map and [docs/README.md](docs/README.md) to find the
one canonical page for each topic. Read what the task needs.

## Find the applicable instructions

Before editing, read the guides along the target file's directory path, from root to leaf. Child
guides add local rules; they do not repeat their parents. A session started at the repository root
must explicitly discover descendant guides rather than assume they were loaded.

| Area                                               | Guide                                                        |
| -------------------------------------------------- | ------------------------------------------------------------ |
| Solidity implementation                            | [src/AGENTS.md](src/AGENTS.md)                               |
| Contract tests                                     | [test/AGENTS.md](test/AGENTS.md)                             |
| Application, app catalog, shared app configuration | [app/AGENTS.md](app/AGENTS.md)                               |
| Browser and Worker                                 | [browser](app/src/AGENTS.md), [Worker](app/worker/AGENTS.md) |
| Shared deployment tooling                          | [deployments/AGENTS.md](deployments/AGENTS.md)               |
| Deployment profiles and records                    | [profiles/AGENTS.md](profiles/AGENTS.md)                     |
| Foundry deployment scripts                         | [script/AGENTS.md](script/AGENTS.md)                         |
| Integration cases and hosted environments          | [e2e/AGENTS.md](e2e/AGENTS.md)                               |
| Disposable chain lifecycle                         | [localnet/AGENTS.md](localnet/AGENTS.md)                     |
| CI and repository automation                       | [.github/AGENTS.md](.github/AGENTS.md)                       |

For application onboarding, use [SKILL.md](SKILL.md) and the
[integrator guide](docs/integrations/agent-guide.md).

## Preserve the cross-repository boundaries

- EarnVault alone issues EarnShare; its current engine holds venue shares. Managed backing,
  quarantined surplus, and pending claims remain separate. The canonical rules live in
  [system](docs/architecture/system.md), [fees](docs/architecture/fees.md), and
  [flows](docs/architecture/flows.md).
- Core contracts and shared tooling are customer-agnostic. Venue behavior belongs in engines,
  private conversion in the scoped router, and customer configuration in deployment profiles.
- Tempo API owns offchain reward policy and operations. This repository owns reward contracts,
  deployment surfaces, and contract-focused tests; do not recreate an offchain reward service.
- Use `viem/tempo` for shared Earn client capabilities. Keep browser signing, Worker transport,
  Node-only deployment operations, and Solidity in their existing layers.
- The shared lifecycle owns deployment reconciliation and verified records. App catalogs and the
  stack each hosted E2E run builds from a profile are separate projections; never bypass
  verification by editing outputs.
- Never hand-write a contract ABI in TypeScript: import it from `@tempoxyz/earn/abis` and regenerate
  after interface changes ([deployments README](deployments/README.md#exports)).
- Secrets and funded private keys stay out of source, logs, and generated records. External
  authority handoffs must be completed by their actual owners.
- Core Zones owns hosted Zone infrastructure, and the Zone administrator and pool owner their
  admission and inventory. CI, app projection, and hosted E2E never hold a hosted Zone administrator
  or pool owner key, and never disable policy, admission, or gateway checks or repair Zone
  infrastructure to pass.
- Zones hide activity from outsiders, not their sequencer. Preserve the
  [privacy model](docs/architecture/security-and-privacy.md), including public amount/timing leakage
  and the prohibition on publicly emitting callback `senderTag`.

## Validation and documentation

Use the commands in [docs/development.md](docs/development.md). Start with focused checks; before
pushing meaningful implementation changes, run `pnpm verify`. Hosted or private behavior changes also
need the relevant E2E case and composed group. Report unrun checks and external blockers explicitly;
after pushing a PR update, report with CI pending unless asked to monitor it. For
documentation-only changes, run the link check (`pnpm --filter @tempoxyz/earn test --run docs`),
format changed files, and run `git diff --check`.

Follow the [documentation rules](docs/README.md#documentation-rules) and update the page that owns
the changed behavior. Read implementation and tests together; resolve contradictions rather than
preserving stale text. Removing an integration means removing every reference to it.

Before pushing to a PR branch, check `gh pr view --json state`; if the PR is merged or closed,
branch from `main` and open a new PR. A config or pin change touches only what was asked; propose
wider follow-ups separately.

## External consumers

Other repositories depend on these surfaces; keep them stable or change them together with their
consumers. [`e2e/harness/workflows-contract.test.ts`](e2e/harness/workflows-contract.test.ts) pins
the tempoxyz/workflows entry points.

- **tempoxyz/workflows** runs `pnpm e2e:devnet -- --group zone` and `pnpm devnet:deploy` against an
  existing devnet and reads each case's ID and status from the `e2e/.results/` run result. Their
  inputs and output files are in
  [existing devnet chains](docs/operations/e2e-environments.md#existing-devnet-chains).
- **tempoxyz/cash** imports `localnet/src/index.ts` and calls
  `Environment.run({ consumer, sameAssetRoute, ready })`.
- **tempoxyz/earn-deployments** (private) pins Earn as a submodule and runs `pnpm earn`,
  `pnpm e2e:profile`, and `pnpm profiles --profiles profiles` against the profiles it holds
  ([profiles in another repository](profiles/README.md#profiles-in-another-repository)).
- **tempoxyz/localnet**'s Earn example uses the root `./localnet` export
  ([localnet layer](docs/development/localnet.md#localnet-layer)).
- **tempoxyz/tempo** builds Earn `src/` and consumes the `SingleZoneEarnRouter` and `DemoParPool`
  outputs.
- **The private customer deployments repository** pins Earn as a submodule and runs `pnpm earn`,
  `pnpm e2e:profile`, and `pnpm profiles` against its own `profiles/`
  ([profiles in another repository](profiles/README.md#profiles-in-another-repository)).

## Guide maintenance

Add an agent instruction only when it prevents a recurring mistake that code, tests, or existing
documentation do not already address, at the narrowest useful scope. This guide holds
cross-repository boundaries and guide discovery; a scoped guide holds rules specific to its subtree
and links the canonical document instead of restating it. Mechanically enforceable properties belong
in tests, lint, schemas, or CI. Sibling directories such as `src/`, `test/`, and `script/` do not
inherit one another's guides, so they link shared rules explicitly. When moving a rule, update its
references and preserve its security or accounting meaning; remove obsolete or contradictory
guidance rather than appending exceptions.
