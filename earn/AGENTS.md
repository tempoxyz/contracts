# Working on Tempo Earn

Tempo Earn provides a stable EarnVault and native TIP-20 EarnShare over replaceable yield venues.
This is its own Foundry project: run `forge` from `earn/`. Use [README.md](README.md) for the
project map and [docs/README.md](docs/README.md) to find the one canonical page for each topic.
Paths in Earn's guides and docs are relative to `earn/` unless they start with `../`. Read what the
task needs.

## Find the applicable instructions

Read the [repository guide](../AGENTS.md) first, then the guides along the target file's path.

| Area                                               | Guide                                                        |
| -------------------------------------------------- | ------------------------------------------------------------ |
| Solidity implementation                            | [src/AGENTS.md](src/AGENTS.md)                               |
| Contract tests                                     | [test/AGENTS.md](test/AGENTS.md)                             |
| Application, app catalog, shared app configuration | [app/AGENTS.md](app/AGENTS.md)                               |
| Browser and Worker                                 | [browser](app/src/AGENTS.md), [Worker](app/worker/AGENTS.md) |
| Shared deployment tooling                          | [deployments/AGENTS.md](deployments/AGENTS.md)               |
| Deployment profiles and records                    | [profiles/AGENTS.md](profiles/AGENTS.md)                     |
| Foundry deployment scripts                         | [script/AGENTS.md](script/AGENTS.md)                         |
| Earn's local fixture contracts                     | [localnet/](localnet/), built with this project              |
| Integration cases and hosted environments          | [e2e/AGENTS.md](../e2e/AGENTS.md)                            |
| Disposable chain lifecycle                         | [localnet/AGENTS.md](../localnet/AGENTS.md)                  |
| CI and repository automation                       | [.github/AGENTS.md](../.github/AGENTS.md)                    |

For application onboarding, use [SKILL.md](../SKILL.md) and the
[integrator guide](docs/integrations/agent-guide.md).

## Preserve Earn's boundaries

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

Validation, documentation, external consumers, and guide maintenance follow the
[repository guide](../AGENTS.md).
