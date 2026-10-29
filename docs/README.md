# Documentation

This documentation describes the code on `main`. Each project has its own documentation; the
deployment lifecycle, the E2E harness and the development toolchain are shared. Each topic has one
canonical page; other pages link to it rather than restating it, so a behavior change needs one
documentation edit.

## Projects

| Project                                   | Start here                                                                                           |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| [Tempo Earn](../earn/README.md)           | [Earn documentation](earn/README.md): architecture, engines, modules, integrations, audits, glossary |
| [Zone router](../zone-router/README.md)   | [Zone router](zone-router/zone-router.md): `ZoneRouter`, its factory and settlers                    |
| [Bridge integration](../bridge/README.md) | [Bridge documents](../bridge/README.md#documents): design, Bridge's side, deployment, audit scope    |

## Document ownership

Shared topics. Each project's index above owns its own topics.

| Topic                                                                           | Canonical document                                                             |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Repository map: the projects and shared tooling                                 | [README](../README.md#repository-layout)                                       |
| Contribution setup, per-area commands, and pull request conventions             | [Contributing](../CONTRIBUTING.md)                                             |
| Vulnerability reporting and security scope                                      | [Security policy](../SECURITY.md)                                              |
| Toolchain, required checks, contract size, gas, coverage, CI, dependency policy | [Development](development/README.md)                                           |
| Localnet consumer API, layer, lifecycle, and image and fixture constraints      | [Localnet](development/localnet.md)                                            |
| Shared deployment lifecycle, records, verification, handoffs, hosted releases   | [Deployment](deployment/deployment.md)                                         |
| Authored profile JSON, rewards configuration, and test fixture bootstrap        | [Profiles](../profiles/README.md)                                              |
| Deployment package exports, ABIs, modules, and registries                       | [`deployments/README.md`](../deployments/README.md)                            |
| Current hosted state and troubleshooting                                        | [Hosted environments](deployment/hosted-environments.md)                       |
| Stacks deployed outside this repository                                         | [External deployments](deployment/hosted-environments.md#external-deployments) |
| E2E cases, selection, profile acceptance, credentials, and existing devnets     | [E2E environments](deployment/e2e-environments.md)                             |
| User-perceived latency benchmarks and Zone withdrawal exit latency              | [Benchmarks](deployment/benchmarks.md)                                         |
| Agent instruction structure and maintenance                                     | [Guide maintenance](../AGENTS.md#guide-maintenance)                            |

## Documentation rules

- **Document current behavior only.** Implementation claims come from `main`; there are no plans,
  rollout history, dated snapshots, or legacy notes.
- **One canonical page per topic.** Update the page that owns the changed behavior; other pages link
  to it rather than restating it.
- **Addresses have one owner.** Generated `deployment.json` records own profile deployments;
  `earn/app/deployments/` owns browser catalogs; a test profile's `fixture.json` owns its E2E fixture;
  factory registries own shared releases. Other pages link rather than copy.
- **Security claims are explicit.** “Private” always identifies the observer, the sequencer's
  visibility, and public amount/timing leakage.
- **Removing an integration removes every reference to it.**

Projects add their own rules, such as [Earn's](earn/README.md#documentation-rules).
