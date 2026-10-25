/**
 * Browser-safe deployment data, hosted network facts, and the stack, engine, and router binding
 * inspectors. Node tooling imports them from here too; no other entry re-exports them.
 */
export { engineDefinitions, engineKinds, quoteEarnDeposit } from './modules/earn/engines/index.js'
export { inspectPropAMMEngine, quotePropAMMRoute } from './modules/earn/engines/propamm.js'
export { vedaPeriphery } from './modules/earn/engines/veda.js'
export { inspectVedaEngine, inspectVedaPeriphery } from './modules/earn/engines/veda-inspection.js'
export {
  inspectRouterBinding,
  inspectRouterReadiness,
  oracleFreshness,
} from './modules/earn/zone-router/inspection.js'
export { InspectionMismatchError } from './chain/inspect.js'
export {
  configuredTempoNetworkChain,
  configuredZoneChain,
  hasFaucet,
  hostedEnvironment,
  hostedEnvironments,
  tempoApiRpcUrl,
  type HostedEnvironment,
  type HostedEnvironmentId,
} from './chain/tempo.js'
export {
  capabilityKeys,
  inspectStackBinding,
  parsePublicStackCatalog,
  publicStack,
  type DeploymentCapabilities,
  type EngineKind,
  type PublicEarnStack,
  type PublicNetwork,
  type PublicStackCatalog,
  type TokenMetadata,
} from './core/stack.js'
export type { ZoneConfiguration } from './modules/earn/zone-router/catalog.js'
// The strict parser kit, for consumers that validate their own JSON the same way.
export { address, array, exactKeys, isBytes32, nonemptyString, object } from './core/parse.js'
