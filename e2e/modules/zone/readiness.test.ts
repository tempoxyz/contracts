import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { zeroHash, type Address, type Hex } from 'viem'
import type { E2eZoneContext } from '../../harness/context.js'
import { waitForZoneWithdrawalQueueProgress, zoneWithdrawalQueueStatus } from './readiness.js'

const portal: Address = '0x0000000000000000000000000000000000000001'
const hashA: Hex = `0x${'aa'.repeat(32)}`
const hashB: Hex = `0x${'bb'.repeat(32)}`

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

describe('zoneWithdrawalQueueStatus', () => {
  it('pins the head, tail, and current slot commitment to the same uncached L1 block', async () => {
    const { context, calls, blockRequests } = queueFixture([snapshot()])
    expect(await zoneWithdrawalQueueStatus(context)).toEqual({
      blockNumber: 100n,
      head: 5n,
      tail: 7n,
      pending: 2n,
      headHash: hashA,
    })
    expect(blockRequests).toEqual([{ cacheTime: 0 }])
    expect(
      calls.map(({ address, blockNumber, functionName, args }) => ({
        address,
        blockNumber,
        functionName,
        args,
      })),
    ).toEqual([
      { address: portal, blockNumber: 100n, functionName: 'withdrawalQueueHead', args: undefined },
      { address: portal, blockNumber: 100n, functionName: 'withdrawalQueueTail', args: undefined },
      { address: portal, blockNumber: 100n, functionName: 'withdrawalQueueSlot', args: [5n] },
    ])
  })

  it('does not read a nonexistent head slot for an empty queue', async () => {
    const { context, calls } = queueFixture([snapshot({ tail: 5n, headHash: zeroHash })])
    expect(await zoneWithdrawalQueueStatus(context)).toMatchObject({
      pending: 0n,
      headHash: undefined,
    })
    expect(calls.map(({ functionName }) => functionName)).toEqual([
      'withdrawalQueueHead',
      'withdrawalQueueTail',
    ])
  })

  it('rejects inconsistent queue counters', async () => {
    const { context } = queueFixture([snapshot({ tail: 4n })])
    await expect(zoneWithdrawalQueueStatus(context)).rejects.toThrow(
      'queue is inconsistent: head 5, tail 4',
    )
  })

  it('rejects a pending batch without a commitment', async () => {
    const { context } = queueFixture([snapshot({ headHash: zeroHash })])
    await expect(zoneWithdrawalQueueStatus(context)).rejects.toThrow('pending head 5 has no hash')
  })
})

describe('waitForZoneWithdrawalQueueProgress', () => {
  it('accepts an initially empty queue without polling', async () => {
    const { context, blockRequests } = queueFixture([snapshot({ tail: 5n })])
    await expect(waitForZoneWithdrawalQueueProgress(context)).resolves.toBeUndefined()
    expect(blockRequests).toHaveLength(1)
  })

  it('accepts a partially dequeued batch even when head and tail do not move', async () => {
    const { context } = queueFixture([snapshot(), snapshot({ blockNumber: 101n, headHash: hashB })])
    await expect(waitForZoneWithdrawalQueueProgress(context)).resolves.toBeUndefined()
  })

  it('waits for fresh within-batch progress rather than accepting its initial commitment', async () => {
    const { context, blockRequests } = queueFixture([
      snapshot(),
      snapshot({ blockNumber: 101n }),
      snapshot({ blockNumber: 102n }),
      snapshot({ blockNumber: 103n, headHash: hashB }),
    ])
    let complete = false
    const result = waitForZoneWithdrawalQueueProgress(context).then(() => {
      complete = true
    })
    await vi.advanceTimersByTimeAsync(1_999)
    expect(complete).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await result
    expect(complete).toBe(true)
    expect(blockRequests).toHaveLength(4)
  })

  it.each([
    ['completed batch', snapshot({ blockNumber: 101n, head: 6n, headHash: hashB })],
    ['empty queue', snapshot({ blockNumber: 101n, head: 7n, headHash: zeroHash })],
  ] as const)('still accepts a %s', async (_label, current) => {
    const { context } = queueFixture([snapshot(), current])
    await expect(waitForZoneWithdrawalQueueProgress(context)).resolves.toBeUndefined()
  })

  it.each([
    ['static old state', snapshot()],
    ['new blocks without dequeue', snapshot({ blockNumber: 101n })],
    ['tail growth only', snapshot({ blockNumber: 101n, tail: 8n })],
    ['changed hash at the old block', snapshot({ headHash: hashB })],
    ['older block evidence', snapshot({ blockNumber: 99n, headHash: hashB })],
    ['regressed head', snapshot({ blockNumber: 101n, head: 4n, headHash: hashB })],
  ] as const)('rejects %s at the unchanged 30-second deadline', async (_label, current) => {
    const { context } = queueFixture([snapshot(), current])
    const result = expect(waitForZoneWithdrawalQueueProgress(context)).rejects.toThrow(
      'no head or current-batch progress for 30s',
    )
    await vi.advanceTimersByTimeAsync(30_000)
    await result
  })

  it('does not reset the deadline while new batches accumulate behind a stuck head', async () => {
    const { context } = queueFixture(
      Array.from({ length: 40 }, (_, index) =>
        snapshot({
          blockNumber: 100n + BigInt(index),
          tail: 7n + BigInt(index),
        }),
      ),
    )
    const result = expect(waitForZoneWithdrawalQueueProgress(context)).rejects.toThrow(
      'not draining',
    )
    await vi.advanceTimersByTimeAsync(30_000)
    await result
  })
})

type QueueSnapshot = { blockNumber: bigint; head: bigint; tail: bigint; headHash: Hex }

function snapshot(changes: Partial<QueueSnapshot> = {}): QueueSnapshot {
  return { blockNumber: 100n, head: 5n, tail: 7n, headHash: hashA, ...changes }
}

/** Read-only in-memory Portal states, including repeated or stale RPC responses. */
function queueFixture(snapshots: readonly QueueSnapshot[]) {
  type Call = {
    address: Address
    blockNumber: bigint
    functionName: string
    args?: readonly unknown[]
  }
  const calls: Call[] = []
  const blockRequests: unknown[] = []
  let index = -1
  let current = snapshots[0]!
  const context = {
    deployment: { network: { zone: { portal } } },
    pollingInterval: 1_000,
    l1Public: {
      getBlockNumber: async (options: unknown) => {
        blockRequests.push(options)
        current = snapshots[Math.min(++index, snapshots.length - 1)]!
        return current.blockNumber
      },
      readContract: async (call: Call) => {
        calls.push(call)
        if (call.address !== portal || call.blockNumber !== current.blockNumber)
          throw new Error('Queue reads must use the selected Portal and block')
        switch (call.functionName) {
          case 'withdrawalQueueHead':
            return current.head
          case 'withdrawalQueueTail':
            return current.tail
          case 'withdrawalQueueSlot':
            if (call.args?.[0] !== current.head) throw new Error('Expected current head slot')
            return current.headHash
          default:
            throw new Error(`Unexpected read: ${call.functionName}`)
        }
      },
    },
  } as unknown as E2eZoneContext
  return { context, calls, blockRequests }
}
