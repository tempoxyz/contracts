import { createPublicClient, getAddress, type Address } from 'viem'
import { Addresses } from 'viem/tempo'

import { configuredRpcTransport, rpcClient, rpcConfiguration } from '../../chain/runtime.js'
import { tempoApiRpcUrl } from '../../chain/tempo.js'
import { inspectZone } from '../../chain/zone.js'
import type { EarnDeploymentProfile } from '../../core/profile.js'
import { configuredZone } from './profile.js'

/**
 * Discovers the configured Zone's canonical identity as deployment outputs: Portal, Messenger, and
 * Outbox addresses plus `zoneSequencer<N>` discovery metadata. Without `requireLiveZone`, discovery
 * reads only the L1 and never contacts the Zone RPC.
 */
export async function discoverZoneOutputs(options: {
  environment: NodeJS.ProcessEnv
  profile: EarnDeploymentProfile
  requireLiveZone?: boolean
  rpcUrl: string
}) {
  const zone = configuredZone(options.profile)
  if (!zone) return undefined
  const requireLiveZone = options.requireLiveZone ?? true
  const zoneRpc = requireLiveZone
    ? zoneRpcConfiguration(zone.chainId, options.environment)
    : undefined
  if (requireLiveZone && !zoneRpc?.url) {
    throw missingZoneRpcError(zone, 'pnpm earn verify --skip-zone checks everything else.')
  }
  const identity = await inspectZone({
    id: zone.id,
    chainId: zone.chainId,
    l1Client: rpcClient(options.rpcUrl),
    ...(zoneRpc?.url
      ? {
          zoneClient: createPublicClient({ transport: configuredRpcTransport(zoneRpc) }),
        }
      : {}),
  })
  const sequencers = Object.fromEntries(
    identity.sequencers.map((sequencer, index) => [`zoneSequencer${index}`, sequencer]),
  ) as Record<`zoneSequencer${number}`, Address>
  return {
    zonePortal: identity.portal,
    zoneMessenger: identity.messenger,
    zoneOutbox: getAddress(Addresses.zoneOutbox),
    ...sequencers,
  }
}

/** A live Zone check without Zone RPC access; `fallback` names the command that skips it. */
export function missingZoneRpcError(zone: { id: number; chainId: number }, fallback: string) {
  return new Error(
    `Set ZONE_RPC_URL (or TEMPO_API_KEY for the Tempo API) to verify Zone ${zone.id}: its RPC ` +
      `must report chain ID ${zone.chainId} and an inbox bound to the L1 Portal. ${fallback}`,
  )
}

/** Whether an output key is discovered Zone sequencer metadata rather than a recorded address. */
export function isZoneSequencerOutput(key: string) {
  return key === 'zoneSequencer' || /^zoneSequencer[0-9]+$/.test(key)
}

/** Tempo API when `TEMPO_API_KEY` is set, otherwise the explicit `ZONE_RPC_URL` (or `fallbackUrl`). */
export function zoneRpcConfiguration(
  chainId: number,
  values: Readonly<Record<string, string | undefined>>,
  fallbackUrl?: string,
) {
  const apiKey = values.TEMPO_API_KEY?.trim()
  if (apiKey) {
    const url = tempoApiRpcUrl(chainId)
    return {
      authenticatedUrl: url,
      headers: { 'tempo-api-key': apiKey },
      url,
    }
  }
  return rpcConfiguration('ZONE', values, fallbackUrl)
}
