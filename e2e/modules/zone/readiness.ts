import { getAddress } from 'viem'

import { zonePortalAbi } from '@tempoxyz/earn/abis'
import { inspectZone, missingZoneTokens, readZoneTempoBlock } from '@tempoxyz/earn/tempo/zone'
import {
  requireE2eZone,
  type E2eActor,
  type E2eContext,
  type E2eZoneContext,
} from '../../harness/context.js'
import { E2ePrerequisiteError, errorSummary, waitFor } from '../../harness/support/utils.js'

const MAX_ZONE_TEMPO_LAG = 1_000n
const ZONE_WITHDRAWAL_QUEUE_GRACE_MS = 30_000

const readiness = new WeakMap<E2eContext, Promise<void>>()

/**
 * Proves once per run that the Zone is the deployment's canonical Zone, enables every token the
 * cases move, keeps up with Tempo, and drains its withdrawal queue. A failed check is retried by
 * the next case that needs the Zone.
 */
export function ensureZoneReady(context: E2eContext) {
  requireE2eZone(context)
  let ready = readiness.get(context)
  if (!ready) {
    ready = checkZoneReady(context).catch((error: unknown) => {
      readiness.delete(context)
      if (error instanceof E2ePrerequisiteError) throw error
      throw new E2ePrerequisiteError(`The Zone is not ready or accessible: ${errorSummary(error)}`)
    })
    readiness.set(context, ready)
  }
  return ready
}

async function checkZoneReady(context: E2eZoneContext) {
  const zone = context.deployment.network.zone
  // Authorize first: private RPC rejects even `eth_gasPrice` without a caller token.
  for (const actor of ['user', 'operator', 'outsider'] as const) {
    await authorizeZoneActor(context, actor)
  }
  const userZone = context.actors.user.zone.client
  const identity = await inspectZone({
    id: zone.id,
    chainId: zone.chainId,
    l1Client: context.l1Public,
    zoneClient: userZone,
  })
  if (getAddress(identity.portal) !== getAddress(zone.portal)) {
    throw new E2ePrerequisiteError(
      `${zone.name} Portal mismatch: the deployment uses ${zone.portal}, but Zone ${zone.id} uses ${identity.portal}`,
    )
  }
  const sequencers = new Set(identity.sequencers.map((sequencer) => getAddress(sequencer)))
  if (!zone.sequencers.every((sequencer) => sequencers.has(getAddress(sequencer)))) {
    throw new E2ePrerequisiteError(`${zone.name} sequencers do not match the deployment`)
  }
  // Zone withdrawals pay fees in PATHUSD and fund a PATHUSD buffer whenever gas is priced.
  const feesPriced = (await userZone.getGasPrice()) > 0n
  const missing = await missingZoneTokens(context.l1Public, zone.portal, [
    ['alternate asset', context.assets.alternate],
    ['EarnShare', context.contracts.earnShare],
    ...(feesPriced ? ([['fee token', context.deployment.network.pathUsd]] as const) : []),
  ])
  if (missing.length > 0) {
    throw new Error(`Missing Zone ${zone.id} token enablement for: ${missing.join(', ')}`)
  }
  const portal = { address: zone.portal, abi: zonePortalAbi } as const
  const [tempoHead, zoneProcessedThrough, portalSyncedThrough, withdrawalBatchIndex] =
    await Promise.all([
      context.l1Public.getBlockNumber(),
      readZoneTempoBlock(userZone),
      context.l1Public.readContract({ ...portal, functionName: 'lastSyncedTempoBlockNumber' }),
      context.l1Public.readContract({ ...portal, functionName: 'withdrawalBatchIndex' }),
    ])
  if (tempoHead - zoneProcessedThrough > MAX_ZONE_TEMPO_LAG) {
    throw new E2ePrerequisiteError(
      `The Zone is ${tempoHead - zoneProcessedThrough} Tempo blocks behind (${zoneProcessedThrough} processed, ${tempoHead} current)`,
    )
  }
  if (withdrawalBatchIndex > 0n && tempoHead - portalSyncedThrough > MAX_ZONE_TEMPO_LAG) {
    throw new E2ePrerequisiteError(
      `Zone L1 settlement is ${tempoHead - portalSyncedThrough} Tempo blocks behind (${portalSyncedThrough} synced by the portal, ${tempoHead} current)`,
    )
  }
  const initial = await zoneWithdrawalQueueStatus(context)
  if (initial.pending === 0n) return
  await waitFor(
    'Zone withdrawal queue progress',
    async () => {
      const current = await zoneWithdrawalQueueStatus(context)
      return current.pending === 0n || current.head > initial.head ? true : undefined
    },
    { timeoutMs: ZONE_WITHDRAWAL_QUEUE_GRACE_MS, intervalMs: context.pollingInterval },
  ).catch(() => {
    throw new E2ePrerequisiteError(
      `The Zone withdrawal queue is not draining: head ${initial.head}, tail ${initial.tail}, ${initial.pending} pending, and no head progress for ${ZONE_WITHDRAWAL_QUEUE_GRACE_MS / 1_000}s`,
    )
  })
}

export async function authorizeZoneActor(context: E2eContext, actor: E2eActor) {
  requireE2eZone(context)
  const { client, store } = context.actors[actor].zone
  await client.zone.signAuthorizationToken({ zoneId: context.deployment.network.zone.id, store })
}

export async function zoneWithdrawalQueueStatus(context: E2eZoneContext) {
  const portal = { address: context.deployment.network.zone.portal, abi: zonePortalAbi } as const
  // Both counters are monotonic. Reading head first avoids a false head > tail
  // if the two RPC calls land on adjacent blocks while the queue is draining.
  const head = await context.l1Public.readContract({
    ...portal,
    functionName: 'withdrawalQueueHead',
  })
  const tail = await context.l1Public.readContract({
    ...portal,
    functionName: 'withdrawalQueueTail',
  })
  if (tail < head)
    throw new Error(`Zone withdrawal queue is inconsistent: head ${head}, tail ${tail}`)
  return { head, tail, pending: tail - head }
}
