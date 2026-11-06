import { describe, expect, it } from 'vitest'
import { Addresses } from 'viem/tempo'
import type { E2eZoneContext } from '../../harness/context.js'
import { E2ePrerequisiteError } from '../../harness/support/utils.js'
import { requireZoneProofReads, submitZoneWithdrawal } from './proof.js'
import {
  fundPrivateFeeBuffer,
  fundPrivateInput,
  zoneDeposit,
  zoneDepositExpectBounce,
  zoneDepositExpectRecipientBounce,
  zoneRedeem,
} from './actions.js'
import { migrateExistingVenueSharesToZone } from './migration.js'

describe('requireZoneProofReads', () => {
  it('probes both system addresses at the same current block through configured reads', async () => {
    const { context, reads } = fixture(false)
    await expect(requireZoneProofReads(context)).resolves.toBeUndefined()
    expect(reads).toEqual([
      { cacheTime: 0 },
      { address: [Addresses.zoneInbox, Addresses.zoneOutbox], fromBlock: 7n, toBlock: 7n },
    ])
  })

  it('reports a prerequisite instead of falling back to a submission or operator endpoint', async () => {
    const { context, writes } = fixture(true)
    await expect(requireZoneProofReads(context)).rejects.toBeInstanceOf(E2ePrerequisiteError)
    expect(writes).toEqual([])
  })
})

describe('private-flow proof prerequisites', () => {
  it.each([
    ['deposit', (context: E2eZoneContext) => zoneDeposit(context, { amount: 1n })],
    [
      'prefunded deposit',
      (context: E2eZoneContext) => zoneDeposit(context, { amount: 1n, funded: true }),
    ],
    ['redeem', (context: E2eZoneContext) => zoneRedeem(context, { earnShares: 1n })],
    [
      'prefunded redeem',
      (context: E2eZoneContext) => zoneRedeem(context, { earnShares: 1n, funded: true }),
    ],
    [
      'callback bounce',
      (context: E2eZoneContext) => zoneDepositExpectBounce(context, { amount: 1n }),
    ],
    [
      'recipient bounce',
      (context: E2eZoneContext) => zoneDepositExpectRecipientBounce(context, { amount: 1n }),
    ],
    ['input funding', (context: E2eZoneContext) => fundPrivateInput(context, 1n)],
    ['fee funding', (context: E2eZoneContext) => fundPrivateFeeBuffer(context)],
    ['venue migration', (context: E2eZoneContext) => migrateExistingVenueSharesToZone(context)],
  ] as const)(
    'blocks %s before funding or submitting when system logs are redacted',
    async (_label, run) => {
      const { context, writes, authorizations } = fixture(true)
      await expect(run(context)).rejects.toThrow('system-log prerequisite')
      expect(writes).toEqual([])
      expect(authorizations).toHaveLength(3)
    },
  )
})

function fixture(redacted: boolean) {
  const reads: unknown[] = []
  const writes: string[] = []
  const authorizations: string[] = []
  const address = '0x0000000000000000000000000000000000000001'
  const forbidden = (label: string) => async () => {
    writes.push(label)
    throw new Error(`Unexpected ${label} before proof preflight`)
  }
  const client = {
    async getBlockNumber(options: unknown) {
      reads.push(options)
      return 7n
    },
    async getLogs(options: unknown) {
      reads.push(options)
      // Native scope_filter_addresses refuses Inbox/Outbox before evaluating the block range.
      if (redacted) throw new Error('address is not an enabled token')
      return []
    },
    readContract: forbidden('contract read'),
    writeContract: forbidden('Zone write'),
    zone: {
      async signAuthorizationToken() {
        authorizations.push('token')
      },
      requestWithdrawalSync: forbidden('Zone withdrawal'),
    },
  }
  const actors = Object.fromEntries(
    ['user', 'operator', 'outsider', 'accessAdministrator'].map((name) => [
      name,
      {
        account: { address },
        wallet: {
          writeContract: forbidden('L1 write'),
          sendTransactionSync: forbidden('L1 write'),
          zone: { encryptedDepositSync: forbidden('Portal entry') },
        },
        zone: { client, store: {}, submission: { getLogs: forbidden('submission fallback') } },
      },
    ]),
  )
  const context = {
    actors,
    assets: { base: address, alternate: address },
    contracts: { earnRouter: address, earnShare: address },
    deployment: {
      contracts: { earnVault: address, engine: address, earnShare: address, venue: address },
      capabilities: { inKindDeposit: true },
      network: { zone: { id: 1, portal: address } },
    },
    l1Public: { readContract: forbidden('L1 read') },
  } as unknown as E2eZoneContext
  return { context, reads, writes, authorizations }
}

describe('submitZoneWithdrawal', () => {
  it('submits one hash-only withdrawal and reads its receipt only through the proof client', async () => {
    const hash = `0x${'ab'.repeat(32)}` as const
    const receipt = { status: 'success', transactionHash: hash, logs: [] }
    const parameters = {
      amount: 1n,
      token: '0x20c0000000000000000000000000000000000000',
      to: Addresses.zoneOutbox,
    } as const
    const calls: unknown[] = []
    const context = {
      actors: {
        user: {
          zone: {
            client: {
              async waitForTransactionReceipt(options: unknown) {
                calls.push(['proof', options])
                return receipt
              },
            },
          },
        },
        operator: {
          zone: {
            submission: {
              zone: {
                async requestWithdrawal(options: unknown) {
                  calls.push(['submit', options])
                  return hash
                },
                async requestWithdrawalSync() {
                  throw new Error('Cannot parse caller-redacted receipts')
                },
              },
            },
          },
        },
      },
    } as unknown as E2eZoneContext
    expect(await submitZoneWithdrawal(context, 'operator', parameters)).toBe(receipt)
    expect(calls).toEqual([
      ['submit', parameters],
      ['proof', { hash, timeout: 180_000 }],
    ])
  })

  it('does not resubmit when the proof receipt is unavailable', async () => {
    let submits = 0
    const context = {
      actors: {
        user: {
          zone: {
            submission: {
              zone: {
                async requestWithdrawal() {
                  submits++
                  return `0x${'ab'.repeat(32)}`
                },
              },
            },
            client: {
              async waitForTransactionReceipt() {
                throw new Error('Proof receipt unavailable')
              },
            },
          },
        },
      },
    } as unknown as E2eZoneContext
    await expect(
      submitZoneWithdrawal(context, 'user', {
        amount: 1n,
        token: '0x20c0000000000000000000000000000000000000',
        to: Addresses.zoneOutbox,
      }),
    ).rejects.toThrow('Proof receipt unavailable')
    expect(submits).toBe(1)
  })
})
