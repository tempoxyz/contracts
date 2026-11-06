import {
  decodeFunctionData,
  encodeAbiParameters,
  encodePacked,
  getAbiItem,
  keccak256,
  parseEventLogs,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
  type Log,
} from 'viem'
import { Abis, Addresses } from 'viem/tempo'
import type { E2eZoneContext } from '../../harness/context.js'
import { assert, waitFor } from '../../harness/support/utils.js'
import { zoneDepositAbi } from './delivery.js'

type Refund = {
  depositHash: Hex
  token: Address
  sender: Address
  recipient: Address
  netAmount: bigint
}

type MinedLog = Log<bigint, number, false>
const withdrawalFunction = getAbiItem({ abi: Abis.zonePortal, name: 'processWithdrawals' })
const withdrawalParameter = { ...withdrawalFunction.inputs[0], type: 'tuple' } as const
// Native Withdrawal::sender_tag preserves the 52-byte zero-sender bounce tag, without the user nonce suffix.
const bounceSenderTag = keccak256(encodePacked(['address', 'bytes32'], [zeroAddress, zeroHash]))

/** Waits for a deposit-specific, delivered public refund; pending refunds never count as delivery. */
export async function waitForRecipientRefund(
  context: E2eZoneContext,
  options: Refund & { zoneFromBlock: bigint; l1FromBlock: bigint },
): Promise<bigint> {
  assert(options.l1FromBlock > 0n, 'Refund correlation needs a preceding L1 block')
  const portal = context.deployment.network.zone.portal
  const zone = context.actors.user.zone.client
  const batch = await waitFor(
    `Zone failure and withdrawal batch for ${options.depositHash}`,
    async () => {
      const failures = await zone.getLogs({
        address: Addresses.zoneInbox,
        events: zoneDepositAbi.filter(
          (item) =>
            item.type === 'event' &&
            (item.name === 'DepositFailed' ||
              item.name === 'EncryptedDepositFailed' ||
              item.name === 'DepositRejected'),
        ),
        fromBlock: options.zoneFromBlock,
        toBlock: 'latest',
      })
      const failure = failures.find((log) => same(log.args.depositHash, options.depositHash))
      if (!failure) return undefined
      return recipientRefundBatch(
        await zone.getLogs({
          address: [Addresses.zoneInbox, Addresses.zoneOutbox],
          blockHash: failure.blockHash,
        }),
        options,
      )
    },
    { intervalMs: context.pollingInterval },
  )
  // Replay the queue ordinal from before the action, so identical bounce hashes cannot select an older batch.
  const initialQueueHead = await context.l1Public.readContract({
    address: portal,
    abi: Abis.zonePortal,
    functionName: 'withdrawalQueueHead',
    blockNumber: options.l1FromBlock - 1n,
  })
  return waitFor(
    `authenticated public refund for ${options.depositHash} (complete logs and calldata required)`,
    async () => {
      const toBlock = await context.l1Public.getBlockNumber({ cacheTime: 0 })
      const [logs, queueHead] = await Promise.all([
        context.l1Public.getLogs({ address: portal, fromBlock: options.l1FromBlock, toBlock }),
        context.l1Public.readContract({
          address: portal,
          abi: Abis.zonePortal,
          functionName: 'withdrawalQueueHead',
          blockNumber: toBlock,
        }),
      ])
      const hashes = [...new Set(outcomes(logs, portal).map((log) => log.transactionHash))]
      const executions = await Promise.all(
        hashes.map(async (hash) => {
          const [transaction, receipt] = await Promise.all([
            context.l1Public.getTransaction({ hash }),
            context.l1Public.getTransactionReceipt({ hash }),
          ])
          return { transaction, receipt }
        }),
      )
      return recipientRefundAmount(batch, {
        executions,
        initialQueueHead,
        logs,
        portal,
        queueHead,
      })
    },
    { intervalMs: context.pollingInterval },
  )
}

/** Links one deposit failure to its immediately preceding bounce and its complete Zone block batch. */
export function recipientRefundBatch(logs: readonly MinedLog[], options: Refund) {
  const ordered = [...logs].sort((a, b) => a.logIndex - b.logIndex)
  const failures = parseEventLogs({
    abi: zoneDepositAbi,
    eventName: ['DepositFailed', 'EncryptedDepositFailed', 'DepositRejected'],
    logs: ordered.filter((log) => same(log.address, Addresses.zoneInbox)),
  }).filter((log) => same(log.args.depositHash, options.depositHash))
  assert(failures.length === 1, 'Expected exactly one deposit-specific Zone failure')
  const failure = failures[0]!
  assert(
    same(failure.args.sender, options.sender) &&
      same(failure.args.token, options.token) &&
      failure.args.amount === options.netAmount,
    'Zone failure does not match the deposited sender, token, and net amount',
  )
  if (failure.eventName === 'DepositRejected')
    assert(
      same(failure.args.tempoRefundRecipient, options.recipient),
      'Rejected deposit names a different refund recipient',
    )
  assert(
    ordered.every(
      (log, index) =>
        !log.removed &&
        log.blockHash === failure.blockHash &&
        log.blockNumber === failure.blockNumber &&
        (index === 0 || log.logIndex > ordered[index - 1]!.logIndex),
    ),
    'Zone evidence must contain unique canonical logs from one block',
  )
  const withdrawals = parseEventLogs({
    abi: Abis.zoneOutbox,
    eventName: 'WithdrawalRequested',
    logs: ordered.filter((log) => same(log.address, Addresses.zoneOutbox)),
  })
  const index = withdrawals.findIndex(
    (log) =>
      log.logIndex === failure.logIndex - 1 && log.transactionHash === failure.transactionHash,
  )
  assert(
    index >= 0,
    'Deposit failure lacks its adjacent bounce withdrawal; evidence may be redacted',
  )
  const bounce = withdrawals[index]!.args
  assert(
    same(bounce.sender, zeroAddress) &&
      same(bounce.token, options.token) &&
      same(bounce.to, options.recipient) &&
      bounce.amount === options.netAmount &&
      bounce.fee === 0n &&
      bounce.fallbackNonce === 0n &&
      bounce.gasLimit === 0n &&
      same(bounce.memo, zeroHash) &&
      bounce.data === '0x' &&
      bounce.revealTo === '0x',
    'Adjacent withdrawal is not the expected canonical deposit bounce',
  )
  assert(
    withdrawals.every(
      (log, i) =>
        i === 0 || log.args.withdrawalIndex === withdrawals[i - 1]!.args.withdrawalIndex + 1n,
    ),
    'Zone withdrawal evidence has a gap',
  )
  const batches = parseEventLogs({
    abi: Abis.zoneOutbox,
    eventName: 'BatchFinalized',
    logs: ordered.filter((log) => same(log.address, Addresses.zoneOutbox)),
  })
  assert(batches.length === 1, 'Expected exactly one finalized withdrawal batch in the Zone block')
  const batch = batches[0]!
  assert(
    batch.logIndex > withdrawals.at(-1)!.logIndex &&
      !same(batch.args.withdrawalQueueHash, zeroHash),
    'Zone batch finalization does not cover the bounce withdrawal',
  )
  return { options, index, withdrawals, finalized: batch }
}

type Batch = ReturnType<typeof recipientRefundBatch>
type Execution = {
  transaction: {
    hash: Hex
    to?: Address | null | undefined
    input?: Hex | undefined
    calls?: readonly { to?: Address | undefined; data?: Hex | undefined }[] | undefined
  }
  receipt: {
    transactionHash: Hex
    blockHash: Hex
    blockNumber: bigint
    transactionIndex: number
    status: 'success' | 'reverted' | 'pending'
    logs: readonly MinedLog[]
  }
}

/** Verifies ABI evidence and queue order, returning only a fully correlated delivered refund. */
export function recipientRefundAmount(
  batch: Batch,
  options: {
    portal: Address
    logs: readonly MinedLog[]
    executions: readonly Execution[]
    initialQueueHead: bigint
    queueHead: bigint
  },
): bigint | undefined {
  const submissions = parseEventLogs({
    abi: Abis.zonePortal,
    eventName: 'BatchSubmitted',
    logs: options.logs.filter((log) => same(log.address, options.portal)),
  }).filter((log) => same(log.args.nextBlockHash, batch.finalized.blockHash))
  if (submissions.length === 0) return undefined
  assert(submissions.length === 1, 'Ambiguous L1 submission for the Zone block')
  const submitted = submissions[0]!
  assert(
    same(submitted.args.withdrawalQueueHash, batch.finalized.args.withdrawalQueueHash) &&
      submitted.args.withdrawalBatchIndex === batch.finalized.args.withdrawalBatchIndex,
    'L1 batch submission does not authenticate the Zone withdrawal batch',
  )
  assert(!submitted.removed, 'L1 batch submission was removed')
  assert(
    options.initialQueueHead <= submitted.args.withdrawalQueueIndex,
    'L1 correlation starts after the refund batch was processed',
  )
  let head = options.initialQueueHead
  let suffix = batch.finalized.args.withdrawalQueueHash
  let offset = 0
  let refund: bigint | undefined
  const executions = [...options.executions].sort((a, b) =>
    a.receipt.blockNumber < b.receipt.blockNumber
      ? -1
      : a.receipt.blockNumber > b.receipt.blockNumber
        ? 1
        : a.receipt.transactionIndex - b.receipt.transactionIndex,
  )
  const seen = new Set<Hex>()
  for (const { transaction, receipt } of executions) {
    assert(!seen.has(transaction.hash), 'Duplicate processWithdrawals transaction evidence')
    seen.add(transaction.hash)
    assert(
      transaction.hash === receipt.transactionHash && receipt.status === 'success',
      'Withdrawal receipt is reverted or belongs to another transaction',
    )
    const call = transaction.calls
      ? transaction.calls.length === 1
        ? transaction.calls[0]
        : undefined
      : { to: transaction.to, data: transaction.input }
    assert(
      call !== undefined && same(call.to, options.portal) && call.data !== undefined,
      'Refund correlation requires a direct, single-call processWithdrawals transaction',
    )
    const decoded = decodeFunctionData({ abi: Abis.zonePortal, data: call.data })
    assert(
      decoded.functionName === 'processWithdrawals',
      'Withdrawal events came from an unsupported wrapped call',
    )
    const [withdrawals, remainingQueue] = decoded.args
    const events = outcomes(receipt.logs, options.portal)
    assert(
      events.length === withdrawals.length && withdrawals.length > 0,
      'Withdrawal receipt has an ambiguous or incomplete outcome layout',
    )
    assert(
      events.every(
        (event, i) =>
          !event.removed &&
          event.transactionHash === receipt.transactionHash &&
          event.blockHash === receipt.blockHash &&
          event.blockNumber === receipt.blockNumber &&
          event.transactionIndex === receipt.transactionIndex &&
          (i === 0 || event.logIndex > events[i - 1]!.logIndex),
      ),
      'Withdrawal receipt contains inconsistent or unordered logs',
    )
    if (head === submitted.args.withdrawalQueueIndex) {
      assert(
        receipt.blockNumber > submitted.blockNumber ||
          (receipt.blockNumber === submitted.blockNumber &&
            receipt.transactionIndex > submitted.transactionIndex),
        'Refund processing precedes its authenticated batch submission',
      )
      // Each successful call removes a prefix of exactly one batch; its tail authenticates split calls.
      let hash = remainingQueue
      for (const withdrawal of [...withdrawals].reverse())
        hash = keccak256(
          encodeAbiParameters([withdrawalParameter, { type: 'bytes32' }], [withdrawal, hash]),
        )
      assert(
        same(hash, suffix),
        'processWithdrawals calldata does not authenticate the expected queue suffix',
      )
      for (const [i, withdrawal] of withdrawals.entries()) {
        const requested = batch.withdrawals[offset + i]
        assert(requested !== undefined, 'Zone withdrawal evidence is incomplete or redacted')
        const expected = requested.args
        const senderTag =
          same(expected.sender, zeroAddress) && expected.fallbackNonce === 0n
            ? bounceSenderTag
            : keccak256(
                encodePacked(
                  ['address', 'bytes32', 'uint64'],
                  [expected.sender, requested.transactionHash, expected.fallbackNonce],
                ),
              )
        assert(
          same(withdrawal.senderTag, senderTag) &&
            same(withdrawal.token, expected.token) &&
            same(withdrawal.to, expected.to) &&
            withdrawal.amount === expected.amount &&
            same(withdrawal.memo, expected.memo) &&
            withdrawal.gasLimit === expected.gasLimit &&
            withdrawal.fallbackNonce === expected.fallbackNonce &&
            same(withdrawal.callbackData, expected.data) &&
            (expected.revealTo !== '0x' || withdrawal.encryptedSender === '0x'),
          'Authenticated withdrawal order differs from the complete Zone block evidence',
        )
        const event = events[i]!
        if (withdrawal.fallbackNonce === 0n) {
          assert(
            event.eventName === 'DepositBounceBack' ||
              event.eventName === 'DepositBounceBackPending',
            'Deposit bounce has no corresponding Portal outcome',
          )
          assert(
            same(event.args.tempoRefundRecipient, withdrawal.to) &&
              same(event.args.token, withdrawal.token) &&
              event.args.amount + event.args.bouncebackFee === withdrawal.amount,
            'Portal bounce amount and actual fee do not match the authenticated withdrawal',
          )
          if (offset + i === batch.index) {
            assert(
              event.eventName === 'DepositBounceBack',
              'Deposit refund is pending, not delivered',
            )
            refund = event.args.amount
          }
        } else {
          assert(
            event.eventName === 'WithdrawalProcessed' &&
              same(event.args.to, withdrawal.to) &&
              same(event.args.senderTag, withdrawal.senderTag) &&
              same(event.args.token, withdrawal.token) &&
              event.args.amount === withdrawal.amount,
            'Withdrawal outcome order differs from the authenticated calldata',
          )
        }
      }
      offset += withdrawals.length
      suffix = remainingQueue
      if (same(suffix, zeroHash))
        assert(
          offset === batch.withdrawals.length,
          'Zone block evidence does not match the full finalized batch',
        )
    }
    if (same(remainingQueue, zeroHash)) head += 1n
  }
  // This cursor is only a completeness check; it is never accepted as evidence that the refund arrived.
  assert(
    head === options.queueHead,
    'L1 processing evidence is missing; queue replay did not reach the observed head',
  )
  return same(suffix, zeroHash) ? refund : undefined
}

function outcomes(logs: readonly MinedLog[], portal: Address) {
  return parseEventLogs({
    abi: Abis.zonePortal,
    eventName: ['WithdrawalProcessed', 'DepositBounceBack', 'DepositBounceBackPending'],
    logs: logs.filter((log) => same(log.address, portal)),
  })
}

function same(a: string | null | undefined, b: string) {
  return a?.toLowerCase() === b.toLowerCase()
}
