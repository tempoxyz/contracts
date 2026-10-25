import { hostedEnvironment, tempoApiRpcUrl } from '@tempoxyz/earn/deployments'
import rawCatalog from 'tempo-earn-deployment'

import { parsePublicEnvironmentCatalog } from '../deployments/catalog.js'
import { privateBalanceTokens } from '../deployments/tokens.js'

const catalog = parsePublicEnvironmentCatalog(rawCatalog)
export const isLocalDeployment = catalog.environments.some(
  (environment) => environment.id === 'local',
)

/**
 * A sponsor pays only on the L1 it is backed by, so it comes from the hosted network of the
 * environment's chain, never from its label.
 */
function sponsorUrl(environment: (typeof catalog.environments)[number]) {
  return isLocalDeployment ? undefined : hostedEnvironment(environment.network.chainId)?.sponsorUrl
}

/** Every sponsor URL the browser may call directly, for the Content Security Policy. */
export const sponsorUrls = [
  ...new Set(catalog.environments.flatMap((environment) => sponsorUrl(environment) ?? [])),
]

/** Resolves one fixed upstream without accepting browser-supplied RPC URLs. */
export function rpcUpstream(environmentId: string, kind: 'l1' | 'zone', bindings: Env) {
  const environment = catalog.environments.find((candidate) => candidate.id === environmentId)
  if (!environment) return undefined
  const network = kind === 'l1' ? environment.network : environment.network.zone
  if (!network) return undefined
  if (isLocalDeployment) {
    return { headers: undefined, url: network.rpcUrl }
  }
  const apiKey = bindings.TEMPO_API_KEY.trim()
  if (!apiKey) throw new Error('TEMPO_API_KEY is required for hosted RPC.')
  return { headers: { 'tempo-api-key': apiKey }, url: tempoApiRpcUrl(network.chainId) }
}

/** Resolves the exact registered tokens that the Worker may read for one private deployment. */
export function zoneReadConfiguration(environmentId: string, zoneId: number, deploymentId: string) {
  const environment = catalog.environments.find((candidate) => candidate.id === environmentId)
  const zone = environment?.network.zone
  if (!environment || !zone || zone.id !== zoneId) return undefined
  const deployment = environment.stacks.find((candidate) => candidate.id === deploymentId)
  if (!deployment?.modes.private || !deployment.capabilities.privateRouting) return undefined
  return { chainId: zone.chainId, tokens: privateBalanceTokens(deployment) }
}

/** Returns every browser-safe hosted environment with same-origin authenticated RPC paths. */
export function createConfig(bindings: Env, origin: string) {
  return {
    defaultEnvironmentId: catalog.defaultEnvironmentId,
    environment: isLocalDeployment ? 'local' : bindings.ENVIRONMENT,
    environments: catalog.environments.map((environment) => ({
      ...environment,
      network: {
        ...environment.network,
        rpcUrl: isLocalDeployment
          ? environment.network.rpcUrl
          : `${origin}/api/environments/${environment.id}/l1-rpc`,
        zone: environment.network.zone
          ? {
              ...environment.network.zone,
              rpcUrl: `${origin}/api/environments/${environment.id}/zone-rpc`,
            }
          : undefined,
      },
      sponsorUrl: sponsorUrl(environment),
      tempoApiZoneReads:
        !isLocalDeployment &&
        environment.network.zone !== undefined &&
        Boolean(bindings.TEMPO_API_KEY.trim()),
    })),
    privyAppId: bindings.PRIVY_APP_ID,
  }
}
