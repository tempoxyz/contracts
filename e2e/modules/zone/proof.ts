import { Addresses } from 'viem/tempo'
import type { E2eActor, E2eZoneContext } from '../../harness/context.js'
import { E2ePrerequisiteError, TIMEOUT_MS, assert } from '../../harness/support/utils.js'

/** Rejects known-redacted proof transports before funding; each operation still verifies its full evidence. */
export async function requireZoneProofReads(context: E2eZoneContext) {
  const client = context.actors.user.zone.client
  try {
    const blockNumber = await client.getBlockNumber({ cacheTime: 0 })
    // Native caller-token RPC rejects these addresses even for an empty block, before filtering logs.
    // Reuse configured authority; never fall back to an unconfigured operator or submission endpoint.
    await client.getLogs({
      address: [Addresses.zoneInbox, Addresses.zoneOutbox],
      fromBlock: blockNumber,
      toBlock: blockNumber,
    })
  } catch {
    throw new E2ePrerequisiteError(
      'Private-flow evidence requires an authorized Zone read endpoint exposing canonical Inbox/Outbox logs, receipts, and system calldata; the configured endpoint cannot provide the system-log prerequisite. No private funding or withdrawal was submitted.',
    )
  }
}

/** Submits once, without parsing a potentially redacted receipt on the submission transport. */
export async function submitZoneWithdrawal(
  context: E2eZoneContext,
  actor: E2eActor,
  parameters: Parameters<
    E2eZoneContext['actors']['user']['zone']['submission']['zone']['requestWithdrawal']
  >[0],
) {
  const hash = await context.actors[actor].zone.submission.zone.requestWithdrawal(parameters)
  const receipt = await context.actors.user.zone.client.waitForTransactionReceipt({
    hash,
    timeout: TIMEOUT_MS,
  })
  assert(receipt.transactionHash === hash, 'Zone proof receipt belongs to another submission')
  return receipt
}
