import { describe, expect, it } from 'vitest'
import { getAddress } from 'viem'
import { requireRewardActors } from './preflight.js'
import { withRecovery } from '../controls/recovery.js'
import { fundingSupply, fundWithSupplyQuote } from './funding.js'

const user = getAddress('0x0000000000000000000000000000000000000a01')
const operator = getAddress('0x0000000000000000000000000000000000000a02')
const owner = operator

describe('requireRewardActors', () => {
  it('accepts an authorized recovery owner and distinct user', () => {
    expect(() => requireRewardActors({ user, operator, owner })).not.toThrow()
  })

  it('blocks owner aliases before any funding or pause', async () => {
    const mutations: string[] = []
    await expect(
      (async () => {
        requireRewardActors({ user: owner.toLowerCase() as typeof owner, operator, owner })
        mutations.push('fund', 'setActive(false)')
      })(),
    ).rejects.toThrow('configure END_USER_PRIVATE_KEY')
    expect(mutations).toEqual([])
  })

  it('blocks a configured operator that cannot restore the controller', () => {
    expect(() => requireRewardActors({ user, operator: user, owner })).toThrow(
      'configured operator',
    )
  })

  it('restores activity when a negative probe unexpectedly succeeds', async () => {
    let active = true
    const error = new Error('non-owner pause succeeded')
    await expect(
      withRecovery(async () => {
        active = false
        throw error
      }, [
        {
          label: 'controller owner setActive(true)',
          async restore() {
            active = true
          },
        },
      ]),
    ).rejects.toBe(error)
    expect(active).toBe(true)
  })
})

describe('fundWithSupplyQuote', () => {
  it('includes pending fees without arbitrary supply headroom', async () => {
    expect(fundingSupply({ supply: 100n, pendingFeeShares: 7n })).toBe(107n)
    const caps: bigint[] = []
    const result = await fundWithSupplyQuote({
      quote: async () => ({ supply: 100n, pendingFeeShares: 7n }),
      async submit(cap) {
        caps.push(cap)
        return { funded: 10n, receipt: { blockNumber: 1n } }
      },
    })
    expect(caps).toEqual([107n])
    expect(result.funded).toBe(10n)
  })

  it('retries only a confirmed zero-funding receipt after a fee-only quote race', async () => {
    const caps: bigint[] = []
    const blocks: (bigint | undefined)[] = []
    const result = await fundWithSupplyQuote({
      async quote(block) {
        blocks.push(block)
        return { supply: 100n, pendingFeeShares: caps.length ? 8n : 7n }
      },
      async submit(cap) {
        caps.push(cap)
        return {
          funded: caps.length === 1 ? 0n : 10n,
          receipt: { blockNumber: BigInt(caps.length) },
        }
      },
    })
    expect(caps).toEqual([107n, 108n])
    expect(blocks).toEqual([undefined, 1n, undefined])
    expect(result.funded).toBe(10n)
  })

  it('refuses to raise the anti-JIT cap after a supply increase', async () => {
    const caps: bigint[] = []
    await expect(
      fundWithSupplyQuote({
        quote: async () => ({ supply: caps.length ? 101n : 100n, pendingFeeShares: 7n }),
        async submit(cap) {
          caps.push(cap)
          return { funded: 0n, receipt: { blockNumber: 1n } }
        },
      }),
    ).rejects.toThrow('refusing to raise the anti-JIT cap')
    expect(caps).toEqual([107n])
  })

  it('checks principal supply again before a retry, not just at the zero-funding block', async () => {
    let quotes = 0
    const caps: bigint[] = []
    await expect(
      fundWithSupplyQuote({
        async quote() {
          quotes++
          return { supply: quotes === 3 ? 101n : 100n, pendingFeeShares: BigInt(quotes) }
        },
        async submit(cap) {
          caps.push(cap)
          return { funded: 0n, receipt: { blockNumber: 1n } }
        },
      }),
    ).rejects.toThrow('refusing to raise the anti-JIT cap')
    expect(caps).toEqual([101n])
  })

  it('returns zero for a failed provider instead of blindly retrying it', async () => {
    const caps: bigint[] = []
    const result = await fundWithSupplyQuote({
      quote: async () => ({ supply: 100n, pendingFeeShares: 7n }),
      async submit(cap) {
        caps.push(cap)
        return { funded: 0n, receipt: { blockNumber: 1n } }
      },
    })
    expect(result.funded).toBe(0n)
    expect(caps).toEqual([107n])
  })

  it('bounds fee-only retries to three attempts', async () => {
    let quotes = 0n
    const caps: bigint[] = []
    await expect(
      fundWithSupplyQuote({
        async quote() {
          return { supply: 100n, pendingFeeShares: quotes++ }
        },
        async submit(cap) {
          caps.push(cap)
          return { funded: 0n, receipt: { blockNumber: 1n } }
        },
      }),
    ).rejects.toThrow('3 confirmed zero-funding attempts')
    expect(caps).toEqual([100n, 102n, 104n])
  })

  it('does not retry unknown submission outcomes or failed receipt-block reads', async () => {
    const caps: bigint[] = []
    const submissionError = new Error('receipt timeout')
    await expect(
      fundWithSupplyQuote({
        quote: async () => ({ supply: 100n, pendingFeeShares: 0n }),
        async submit(cap) {
          caps.push(cap)
          throw submissionError
        },
      }),
    ).rejects.toBe(submissionError)
    expect(caps).toEqual([100n])
    const readError = new Error('historical read unavailable')
    await expect(
      fundWithSupplyQuote({
        async quote(block) {
          if (block) throw readError
          return { supply: 100n, pendingFeeShares: 0n }
        },
        async submit(cap) {
          caps.push(cap)
          return { funded: 0n, receipt: { blockNumber: 1n } }
        },
      }),
    ).rejects.toBe(readError)
    expect(caps).toEqual([100n, 100n])
  })
})
