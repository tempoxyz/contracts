import { defineChain, type Address, type Chain } from 'viem'
import { tempoMainnet, tempoModerato } from 'viem/tempo/chains'
import { Zone } from 'viem/tempo'

import type { EarnStack } from '../core/stack.js'

/** What one hosted network entry authors; its chain ID, public RPC, and explorer come from `chain`. */
type HostedNetwork = {
  /** The network's `viem/tempo/chains` template, which every Tempo client on it extends. */
  chain: Chain
  /** Whether the network is a testnet, where disposable test stacks and test-only cases may run. */
  testnet: boolean
  /** Whether the network serves the Tempo testnet faucet. */
  faucet: boolean
  /** Whether sends keep the protocol's default fee token instead of pinning the caller's. */
  defaultFeeToken: boolean
  /** The fee sponsor the app's passkey wallet uses on this network; omit when it has none. */
  sponsorUrl?: string
  /** Zone chain IDs `zoneChainIdBase + zoneId`, below `zoneChainIdEnd`. */
  zoneChainIdBase: number
  zoneChainIdEnd: number
  /** The Tempo-owned hosted Zone, read through Tempo API. */
  zone: { id: number }
}

/**
 * The single source of hosted network facts, the only chains hosted deployments target. The
 * hosted environments runbook says how to add a network.
 */
const networks = {
  mainnet: {
    chain: tempoMainnet,
    testnet: false,
    faucet: false,
    defaultFeeToken: false,
    zoneChainIdBase: 421_700_000,
    zoneChainIdEnd: 1_424_310_000,
    zone: { id: 1 },
  },
  moderato: {
    chain: tempoModerato,
    testnet: true,
    faucet: true,
    defaultFeeToken: true,
    sponsorUrl: 'https://sponsor.moderato.tempo.xyz',
    zoneChainIdBase: 1_424_310_000,
    zoneChainIdEnd: 2 ** 31,
    zone: { id: 3 },
  },
} as const satisfies Record<string, HostedNetwork>

/** Operational environment ID, used by app catalogs, E2E, and dotenv-free tooling. */
export type HostedEnvironmentId = keyof typeof networks

/** One hosted Tempo network. */
export type HostedEnvironment = Omit<HostedNetwork, 'chain' | 'zone'> & {
  id: HostedEnvironmentId
  chain: (typeof networks)[HostedEnvironmentId]['chain']
  chainId: number
  /** Default credential-free public L1 RPC. */
  rpcUrl: string
  /** Explorer base URL; consumers append the resource route. */
  explorerUrl: string
  zone: HostedNetwork['zone'] & { chainId: number }
}

export const hostedEnvironments = Object.fromEntries(
  Object.entries(networks).map(([id, network]: [string, HostedNetwork]) => {
    const { chain, zone } = network
    const explorerUrl = chain.blockExplorers?.default.url
    if (!explorerUrl) throw new Error(`Hosted network ${id} has no explorer`)
    const environment = {
      ...network,
      id,
      chainId: chain.id,
      rpcUrl: chain.rpcUrls.default.http[0],
      explorerUrl,
      zone: { ...zone, chainId: network.zoneChainIdBase + zone.id },
    }
    return [id, environment]
  }),
) as { [Id in HostedEnvironmentId]: HostedEnvironment & { id: Id } }

/** The hosted environment of a Tempo L1 chain ID, or `undefined` for any other chain. */
export function hostedEnvironment(chainId: number): HostedEnvironment | undefined {
  return Object.values(hostedEnvironments).find((environment) => environment.chainId === chainId)
}

/** Whether a chain ID is a hosted Tempo network. */
export function isHostedDeploymentChain(chainId: number) {
  return hostedEnvironment(chainId) !== undefined
}

/** Operational label derived from the canonical Tempo L1 chain identity. */
export function deploymentEnvironmentId(chainId: number) {
  return hostedEnvironment(chainId)?.id ?? `chain-${chainId}`
}

/** Tempo API's authenticated RPC route for any Tempo L1 or Zone chain. */
export function tempoApiRpcUrl(chainId: number) {
  return `https://api.tempo.xyz/rpc/${chainId}`
}

/**
 * The chain ID of Zone `zoneId` on parent chain `parentChainId`: a hosted parent's reserved range,
 * otherwise the parent chain ID in the high bits, as the Zone node derives it.
 */
export function zoneChainId(parentChainId: number, zoneId: number) {
  const environment = hostedEnvironment(parentChainId)
  if (environment) {
    const chainId = environment.zoneChainIdBase + zoneId
    if (chainId >= environment.zoneChainIdEnd) {
      throw new Error(`Zone ${zoneId} exhausts the ${environment.id} Zone chain ID range`)
    }
    return chainId
  }
  if (parentChainId > 1_048_574) {
    throw new Error(`Zone parent chain ${parentChainId} must be at most 1048574`)
  }
  return Number((BigInt(parentChainId) << 32n) | BigInt(zoneId))
}

/** Constructs a Tempo chain from a deployment's network. */
export function configuredTempoChain(deployment: Pick<EarnStack, 'network'>) {
  const network = deployment.network
  return configuredTempoNetworkChain({
    id: network.name,
    chainId: network.chainId,
    rpcUrl: network.rpcUrl,
    feeToken: network.pathUsd,
  })
}

/** The `viem/tempo/chains` template of a Tempo L1: its hosted network's, else Moderato's. */
function tempoChainTemplate(chainId: number) {
  return hostedEnvironment(chainId)?.chain ?? tempoModerato
}

/** Whether a Tempo L1 serves the testnet faucet: a hosted network's fact, else true (local chains). */
export function hasFaucet(chainId: number) {
  return hostedEnvironment(chainId)?.faucet ?? true
}

export function configuredTempoNetworkChain(network: {
  id: string
  chainId: number
  rpcUrl: string
  feeToken?: Address | undefined
}) {
  return defineChain({
    ...tempoChainTemplate(network.chainId),
    ...(hostedEnvironment(network.chainId)?.defaultFeeToken || !network.feeToken
      ? {}
      : { feeToken: network.feeToken }),
    id: network.chainId,
    name: network.id,
    rpcUrls: { default: { http: [network.rpcUrl] } },
    // Sponsored and concurrent sends use expiring nonces (nonce 0 under the max nonce key), so
    // viem's sender-and-nonce replacement check would return an earlier transaction's receipt.
    supportsTransactionReplacementDetection: false,
  })
}

/**
 * The viem `Zone` chain of one Zone on parent chain `sourceId`, pinned to its Portal and Messenger.
 * `rpcUrl` overrides the Zone's own RPC, for example with an authenticated proxy route.
 */
export function configuredZoneChain(options: {
  sourceId: number
  zone: {
    id: number
    chainId: number
    name?: string | undefined
    rpcUrl: string
    portal: Address
    messenger: Address
  }
  rpcUrl?: string | undefined
}) {
  const { sourceId, zone } = options
  return Zone.from({
    contracts: {
      messenger: { [sourceId]: { address: zone.messenger } },
      portal: { [sourceId]: { address: zone.portal } },
    },
    id: zone.chainId,
    name: zone.name ?? `Tempo Zone ${String(zone.id).padStart(3, '0')}`,
    sourceId,
    rpcUrls: { default: { http: [options.rpcUrl ?? zone.rpcUrl] } },
  })
}
