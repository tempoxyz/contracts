# Tempo Earn deployment tooling

`@tempoxyz/earn` is a private workspace package for this repository's deployment registries,
generated ABIs, and operator tooling. It is not published as a client dependency. Earn actions,
TIP-403 policy actions, Earn math, and client decoration come from the upstream `viem/tempo`
preview; see the [client integration guide](../docs/earn/integrations/client.md).

The lifecycle that `pnpm earn` drives (records, verification, activation, and authority handoffs) is
documented in the [deployment runbook](../docs/deployment/deployment.md); the authored JSON is
documented in [deployment profiles](../profiles/README.md).

## Exports

| Export                                  | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `@tempoxyz/earn/deployments`            | Browser-safe: the `hostedEnvironments` network table (chain templates and IDs, testnet flag, public RPC and explorer URLs, faucet, fee-token policy, app sponsor, hosted Zone), the public stack catalog parser and `publicStack` projection, the engine registry (`engineDefinitions`, `quoteEarnDeposit`), `configuredTempoNetworkChain` and `configuredZoneChain`, the strict parser kit (`object`, `array`, `exactKeys`, `nonemptyString`, `address`, `isBytes32`), and the stack, engine, and router binding inspectors |
| `@tempoxyz/earn/deployments/node`       | Node-only profile reconciliation, records, `loadHostedProfileStack`, capability output discovery (`discoverOutputs`), runtime and key parsing, Foundry, and Zone RPC tooling                                                                                                                                                                                                                                                                                                                                                 |
| `@tempoxyz/earn/deployments/operations` | The operational `EarnStack` model, profile parsing, policy and access-membership helpers, and planning                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `@tempoxyz/earn/tempo/zone`             | Canonical Zone predeploys, `discoverZone`, `inspectZone`, `waitForZoneTempoBlock`, `waitForWithdrawalProcessed`, `processedRouterEvent`, and `missingZoneTokens`                                                                                                                                                                                                                                                                                                                                                             |
| `@tempoxyz/earn/abis`                   | Every contract ABI the TypeScript packages use                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |

Each name has one entry, except `configuredTempoNetworkChain`, which is in both the browser-safe and
`operations` entries. Node tooling imports the inspectors and
hosted network facts from the browser-safe entry. The whole-profile `inspectEarnDeployment`, which
runs every capability module's inspection, is exported from `/node` only.

`@tempoxyz/earn/abis` is the only place TypeScript gets a contract ABI; never hand-write one.
`abis/generate.ts` writes `abis/generated.ts` from this repository's Foundry artifacts:

- every deployable contract under `earn/src/` (not an interface, library, or abstract contract) as
  `<name>Abi`, ordered by source directory with `EarnVault`, `EarnFees`, and `EarnFactory` first.
  Its only tables are the directory order, one alias (`SingleZoneEarnRouter` exports
  `earnRouterAbi`), and the Foundry-only contracts it excludes, so a new contract needs no entry; a
  contract in a new `earn/src/` directory fails generation until the directory joins the order;
- the state-changing entry points of every deployment and localnet fixture script as
  `<name>ScriptAbi`; and
- the derived `earnEngineBindingAbi`; and
- `zoneRouterAbi`, `zoneRouterFactoryAbi` and the `router/` deployment scripts' `<name>ScriptAbi`,
  from the separate [`router/`](../router/README.md) project.

After a contract interface change, run `forge build src script test` in `earn/` and
`forge build src script` in `router/`, then
`pnpm --filter @tempoxyz/earn abis`, and commit the result; `abis:check` fails on drift.
`abis/external.ts` hand-maintains contracts built elsewhere: Tempo Zone predeploys, the PropAMM
pool, oracle, and controller, the Veda periphery, the Morpho fee wrapper, and the Safe. Use
`erc20Abi` and `erc4626Abi` from `viem` and `Abis.tip20` from `viem/tempo` for tokens.

## Layout

The root holds the three deployment entry points (`index.ts`, `node.ts`, `operations.ts`), `abis/` (the `./abis` entry, its generator, and the hand-maintained external ABIs),
and the documentation link test (`docs.test.ts`). Everything else lives in one of three layers;
the `./tempo/zone` entry is `chain/zone.ts`.

| Directory  | Ownership                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `chain/`   | Chain plumbing with no Earn policy: RPC transport and credentials (`runtime.ts`), the Foundry version and process environment (`foundry.ts`), Tempo chain identity and the hosted network table (`tempo.ts`), canonical Zone predeploys and discovery (`zone.ts`), and shared onchain assertions (`inspect.ts`)                                                                                                                           |
| `core/`    | The capability-neutral lifecycle: the strict parser kit (`parse.ts`), the profile envelope and its hashes, intent components, records, pending state, the profile bundle and its dotenv, reviewed factory releases and their runtime-hash review (`releases.ts`), plan, reconcile, deploy, verify, the `EarnStack` model, and the `pnpm earn` CLI                                                                                         |
| `modules/` | One directory per capability: under `earn/`, `core/` and `engines/` steps, `zone-router/`, `access-policy/`, and `rewards/`; and `router/`, the `ZoneRouter` from the `router/` project. `module.ts` defines the slice, capability-module, and step interfaces; `slices.ts` registers the browser-safe slices, `index.ts` the steps in execution order and the lifecycle modules, and `commands.ts` the Node-only `pnpm earn` subcommands |

`core/` and `chain/` name no capability. A capability declares itself in two registered objects:

- Its browser-safe **slice** (`profile.ts`, registered in `modules/slices.ts`): profile parsing,
  authored JSON, intent-hash fields and components, `EarnFactory` inputs it decides, recorded
  addresses (discovered, deployed into its own stack fields, or optional periphery), its key of the
  record target, the capabilities it advertises, the privileged roles it assigns (which a hosted
  deployment refuses to give a public `.env.example` identity), and its optional published-stack
  fields with their parsers and cross-field rules. Core derives `EarnDeploymentProfile`, its
  hashes, the record's address order and target, `capabilityKeys`, `EarnStack`, and the catalog
  parser from the list, in registry order, at both the type and the runtime level; slices never
  import the envelope at runtime.
- Its **lifecycle module** (`index.ts`, registered in `modules/index.ts`), whose hooks core runs
  for every registered module: preflight checks, discovered external outputs, access principals
  from a plan or a live stack, post-deployment inspection and readiness, and the module's
  `EarnStack` fields from a record and live reads.

Each step declares its authority (ID, handoff label, and signer variable) and whether its CREATE
needs Forge's raw gas estimate; plan authority labels and the signer environment derive from the
registered steps.

The dependency direction is chain → slices → core profile → modules → core lifecycle; the browser
entry imports neither the profile envelope nor Node-only code, and the operations entry imports no
Node-only code.

### Extending

- **A deployment step** is one `defineFoundryStep` or `defineAuthorityStep` object in its
  capability's `steps.ts` (such as `modules/earn/rewards/` or `modules/router/`), listed in execution
  order in `modules/index.ts`; its literal ID becomes an `EarnDeploymentActionId`. A contract it creates is declared by its `source`,
  with `source.accessMember` (and any principals it pays) when it moves EarnShare or the asset. A
  step whose script and contract belong to a sibling Foundry project, such as `router/`, names it
  in `project`; Forge then runs, and source verification compiles, from that project. A step that
  calls a permissionless factory, which returns a contract another deployer already created for the
  same inputs, declares `adopt` to record that contract and its creation transaction instead, as
  `deploy-zone-router` does with the factory's `RouterDeployed` event.
- **A recorded address** names its owning intent component in one of its slice's address maps.
  **A profile field** belongs to one slice and its intent hash. **A published stack field** is a
  parser in its slice's `stack` section.
- **Capability behavior** the lifecycle needs is a `CapabilityModule` hook, not a branch in
  `core/`. Optional contracts are carried as `OptionalPeriphery`.
- **A new capability** is its folder under `modules/` (`modules/earn/<capability>/` for an Earn
  capability) plus one line in `modules/slices.ts` and, when it has lifecycle hooks or steps, its entries in `modules/index.ts`.
- **A `pnpm earn` subcommand** is a `CapabilityCommand` registered in `modules/commands.ts`, not a
  `CapabilityModule` hook, so the operations entry that loads the module registry stays free of
  Node-only imports.
- **Engine-kind behavior** (reads, quotes, inspection, factory provisioning, and the in-kind
  deposit and exit capabilities its stacks advertise) is a field of that kind's `defineEngine`
  module in `modules/earn/engines/`; the cross-workspace recipe is
  [adding an engine](../docs/earn/integrations/engines.md#adding-an-engine).
- **A new contract or script** needs no ABI entry: [generation](#exports) picks up every deployable
  `earn/src/` contract and every `.s.sol` deployment or fixture script.

Records, resume, source verification, access membership, stacks, and E2E derive from these
declarations, so none of them gains a step-ID, per-contract, or engine-kind branch. Localnet's
`localStack` is the exception for Zone fields: its `Deployment.State` carries the Zone and router it
deployed, and it hands them to the Zone router's `zoneRouterStackFields` itself.

## Registries

Root `deployments/` owns generic Earn-stack reconciliation and the consumer-neutral `EarnStack`
model. `loadHostedProfileStack` builds a deployed profile's stack from its record and live reads,
and `publicStack` allowlists its browser-safe fields. It does not own a concrete hosted catalog, app
release pipeline, or hosted E2E fixture lifecycle.

- The app's browser catalog list, generator, and generated `generated.json` live under
  `app/deployments/`; [app deployment](../docs/deployment/app-deployment.md#catalog-boundaries)
  owns what the catalog carries.
- Hosted E2E builds its stack from a deployed profile's record and attaches its own test fixture
  ([E2E environments](../docs/deployment/e2e-environments.md)). Fixtures, roles, receipts, and
  source metadata never enter the browser catalog.
- `network.explorerUrl` is an optional explorer base URL; consumers append the resource route,
  such as `/receipt/<hash>` or `/address/<address>`, and show no link when it is absent (local
  stacks have none).
- Default helpers are lookup primitives and do not select an app environment. Consumers must honor
  deployment and mode availability rather than attempt zero-address writes.

Per-package commands are in [CONTRIBUTING.md](../CONTRIBUTING.md#work-on-one-area); `check` also
validates every checked-in profile (`core/profiles.ts`).
