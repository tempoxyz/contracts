# Tempo Earn documentation

This documentation describes the code on `main`. Start with the root [Tempo Earn
overview](../../earn/README.md). Each Earn topic has one canonical page below; shared topics (deployment,
profiles, E2E, development, security policy) and the other projects are in the
[repository documentation](../README.md). Other pages link to the canonical page rather than
restating it, so a behavior change needs one documentation edit. The [glossary](glossary.md) defines
each term in one line and links its owning page.

## Reading paths

- **With an agent:** [Tempo Earn skill](../../SKILL.md) → [agent guide](integrations/agent-guide.md) →
  the reference it selects.
- **Review architecture and security:** [system](architecture/system.md) →
  [fees](architecture/fees.md) → [flows](architecture/flows.md) →
  [security and privacy](architecture/security-and-privacy.md) →
  [contract reference](reference/contracts.md) → the [capability modules](#capability-modules) →
  [audits](audit/README.md) → [design decisions](decisions.md).
- **Integrate:** [system](architecture/system.md) → [client](integrations/client.md) →
  [engines](integrations/engines.md) and the deployment's engine module → optional
  [Zone router](modules/zone-router.md), [access policy](modules/access.md),
  [rewards](modules/rewards.md), or [migration](modules/migration.md).
- **Deploy and operate:** [deployment](../deployment/deployment.md) →
  [profiles](../../profiles/README.md) → the enabled [capability modules](#capability-modules) →
  [hosted environments](../deployment/hosted-environments.md) → [E2E environments](../deployment/e2e-environments.md).
- **Contribute:** [contributing](../../CONTRIBUTING.md) → [development](../development/README.md).

## Capability modules

Each capability is a module: its lifecycle steps, inspection, and reads live under
[`deployments/modules/`](../../deployments/modules/) (an engine kind is one `defineEngine` file in
`deployments/modules/earn/engines/`), its E2E cases under [`e2e/modules/`](../../e2e/modules/) (an
engine kind's under [`e2e/engines/`](../../e2e/engines/)), and one page
here owns its contracts, flows, trust boundaries, deployment steps, operations, and design
decisions. The architecture pages describe only the core and link here, so a change to one
capability updates one page. The shared engine contract and the recipe for a new engine kind are in
[yield engines](integrations/engines.md).

| Module                  | Page                                             | Covers                                                                     |
| ----------------------- | ------------------------------------------------ | -------------------------------------------------------------------------- |
| `engines`               | [Yield engines](integrations/engines.md)         | One page per engine kind, listed in its engine table                       |
| `zone-router`           | [Zone router](modules/zone-router.md)            | `SingleZoneEarnRouter`, par conversion, Zone activation, go-live           |
| `access-policy`         | [Access policy](modules/access.md)               | EarnShare TIP-403 whitelist, required members, `pnpm earn access`          |
| `rewards`               | [Rewards](modules/rewards.md)                    | Contribution controller, Merkle distributor, `EarnRewardsFactory`          |
| none                    | [Existing vault migration](modules/migration.md) | Holder opt-in, source-vault composition, stack replacement (E2E in `zone`) |
| top-level `zone-router` | [`ZoneRouter`](../zone-router/zone-router.md)    | The `zoneRouter` field: a `ZoneRouter` mode and its `ZoneRouterFactory`    |

## Document ownership

| Topic                                                                          | Canonical document                                                                            |
| ------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| Goals, layers, custody, accounting, roles, invariants of the core stack        | [System architecture](architecture/system.md)                                                 |
| Fee economics, waterfall, checkpoints, claims, and queued-withdrawal treatment | [Earn fees](architecture/fees.md)                                                             |
| Core transaction and money-movement sequences                                  | [Flows](architecture/flows.md)                                                                |
| Core trust assumptions and privileges, privacy model                           | [Security and privacy](architecture/security-and-privacy.md)                                  |
| Core contract APIs, events, state, and failure behavior                        | [Contract reference](reference/contracts.md)                                                  |
| Shared engine contract, installation checks, and adding an engine kind         | [Yield engines](integrations/engines.md)                                                      |
| One engine kind's contracts, valuation, exits, deployment, and operations      | [ERC-4626](modules/erc4626-engine.md), [Veda](modules/veda.md), [PropAMM](modules/propamm.md) |
| Capability contracts, flows, operations, and rationale                         | [Capability modules](#capability-modules)                                                     |
| Completed Sigma Prime audit reports, finding status, and post-audit coverage   | [Audits](audit/README.md)                                                                     |
| Agent entry-point selection, access checks, and integration troubleshooting    | [Agent guide](integrations/agent-guide.md)                                                    |
| Client integration, approvals, simulation, and revert handling                 | [Client integration](integrations/client.md)                                                  |
| Browser catalog and app profile projection                                     | [App deployment](../deployment/app-deployment.md)                                             |
| Browser wallets, sessions, transactions, private settlement, and UI            | [App browser](../development/app-browser.md)                                                  |
| Worker routes, limits, configuration, secrets, build, and Cloudflare tooling   | [App Worker](../development/app-runtime.md)                                                   |
| Integrator onboarding for agents                                               | [Tempo Earn skill](../../SKILL.md)                                                            |
| One-line term definitions                                                      | [Glossary](glossary.md)                                                                       |
| Settled rationale for the core stack                                           | [Design decisions](decisions.md)                                                              |

## Documentation rules

The [repository rules](../README.md#documentation-rules) apply. Earn adds:

- **Capabilities have one home.** Core sequences live in the flow document and capability
  sequences, decisions, and runbooks on their module page; other pages link instead of restating
  them.
- **Demo code is isolated.** Contracts under `src/demo/`, public test keys, and permissive test
  policies are never presented as production defaults.
