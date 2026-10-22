import {
  optionalPeriphery,
  profileCapabilities,
  zoneRouterStackFields,
  type EarnStack,
  type OptionalPeripheryKey,
} from '@tempoxyz/earn/deployments/operations'

import type * as Deployment from './deployment.js'
import { localEngines } from './engines/index.js'
import type * as Environment from './environment.js'

/**
 * The Earn stack a local or devnet run deployed, described as hosted records describe theirs: its
 * capabilities follow from the deployed profile. Consumers add their own provenance `metadata`.
 */
export function localStack(
  environment: Pick<Environment.State, 'deployment' | 'l1' | 'zone'>,
  options: localStack.Options = {},
): Omit<EarnStack, 'metadata'> {
  const { deployment, l1, zone } = environment
  const periphery: Pick<Deployment.State, OptionalPeripheryKey> = deployment
  const name = options.name ?? 'local'
  const profile = deployment.earnProfile
  const route = zoneRouterStackFields(
    {
      name: `${name}-zone`,
      id: deployment.zoneId,
      chainId: deployment.zoneChainId,
      rpcUrl: options.publicZoneRpc ? zone.publicRpcUrl : zone.rpcUrl,
      portal: deployment.zonePortal,
      messenger: deployment.zoneMessenger,
      sequencers: [deployment.zoneSequencer],
    },
    deployment.earnRouter && {
      earnRouter: deployment.earnRouter,
      privateAsset: deployment.alternateAsset,
    },
  )
  return {
    id: `${name}-${profile.id}-v${profile.version}`,
    label: `${name === 'local' ? 'Local' : 'Devnet'} ${profile.id} stack`,
    status: 'live-demo',
    engineKind: deployment.engineKind,
    network: {
      name: name === 'local' ? 'local-prool' : name,
      chainId: deployment.chainId,
      rpcUrl: l1.rpcUrl,
      pathUsd: deployment.pathUsd,
      tip20Factory: deployment.tip20Factory,
      ...route.network,
    },
    contracts: {
      asset: deployment.baseAsset,
      earnShare: deployment.earnShare,
      earnVault: deployment.earnVault,
      earnFees: deployment.earnFees,
      ...route.contracts,
      engine: deployment.engine,
      venue: deployment.vault,
    },
    expectedMetadata: {
      asset: { name: 'Earn Test Base USD', symbol: 'etBASE', decimals: 6 },
      ...localEngines[deployment.engineKind].metadata,
    },
    modes: { public: { availability: 'available' }, ...route.modes },
    capabilities: profileCapabilities(profile),
    access: deployment.access,
    operations: {
      owner: deployment.owner,
      revenueShareRecipient: deployment.revenueShareRecipient,
      factory: deployment.factory,
      ...optionalPeriphery(periphery),
      accessAdministrator: deployment.accessAdministrator,
    },
  }
}

export declare namespace localStack {
  type Options = {
    /** The environment the stack is named after: `local` (the default) or `devnet`. */
    name?: string | undefined
    /**
     * Targets the Zone's unauthenticated node RPC, which a browser reaches through the Worker,
     * instead of the private RPC that needs per-account tokens.
     */
    publicZoneRpc?: boolean | undefined
  }
}
