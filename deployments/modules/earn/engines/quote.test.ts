import { describe, expect, test } from 'vitest'
import { EarnShares } from 'viem/tempo'

import { quoteEarnDeposit } from './index.js'

const address = `0x${'1'.repeat(40)}` as const
const stack = {
  engineKind: 'erc4626',
  contracts: { asset: address, engine: address, venue: address, earnVault: address },
} as const

describe('quoteEarnDeposit', () => {
  test('quotes post-accrual supply and keeps requested slippage despite pending fees', async () => {
    const expected = await quoteEarnDeposit(quoteClient(), stack, 10_000_000n)
    expect(expected).toBe(11_000_000n)
    const minimum = EarnShares.minimumOutput(expected, 50)
    expect(minimum).toBe(10_945_000n)
    // A 1% venue deterioration would pass the old stale 9.95 minimum, but fails the fee-aware one.
    const deteriorated = (9_900_000n * 110_000_000n) / 100_000_000n
    expect(deteriorated).toBeLessThan(minimum)
    expect(deteriorated).toBeGreaterThan(EarnShares.minimumOutput(10_000_000n, 50))
  })
  test('uses managed custody, not quarantined raw surplus, for the accrual anchor', async () => {
    expect(
      await quoteEarnDeposit(quoteClient({ engineShares: 50_000_000n }), stack, 10_000_000n),
    ).toBe(22_000_000n)
  })
  test('rejects an engine migration between stack inspection and snapshot', async () => {
    await expect(
      quoteEarnDeposit(quoteClient({ engine: `0x${'2'.repeat(40)}` }), stack, 10_000_000n),
    ).rejects.toThrow('engine changed')
  })
  test('preserves the contract decimal range above 18 and rejects scales beyond uint256', async () => {
    const empty = { totalEarnShares: 0n, previewAccruedFees: { totalFeeEarnShares: 0n } }
    expect(
      await quoteEarnDeposit(quoteClient({ ...empty, decimals: 19 }), stack, 10_000_000n),
    ).toBe(10n ** 20n)
    await expect(
      quoteEarnDeposit(quoteClient({ ...empty, decimals: 78 }), stack, 10_000_000n),
    ).rejects.toThrow('invalid scale')
  })
  test('retains empty-pool precision normalization and rejects zero backing with active supply', async () => {
    expect(
      await quoteEarnDeposit(
        quoteClient({ totalEarnShares: 0n, previewAccruedFees: { totalFeeEarnShares: 0n } }),
        stack,
        10_000_000n,
      ),
    ).toBe(10_000_000n)
    await expect(
      quoteEarnDeposit(quoteClient({ engineShares: 0n }), stack, 10_000_000n),
    ).rejects.toThrow('without managed backing')
  })
})

function quoteClient(overrides: Record<string, unknown> = {}) {
  const values: Record<string, unknown> = {
    previewDeposit: 10_000_000n,
    totalEarnShares: 100_000_000n,
    engineShares: 100_000_000n,
    earnFees: address,
    engine: address,
    shareScale: 1_000_000n,
    earnShare: address,
    decimals: 6,
    previewAccruedFees: { totalFeeEarnShares: 10_000_000n },
    convertEngineSharesToEarnShares: 10_000_000n,
    ...overrides,
  }
  return {
    getBlockNumber: async () => 99n,
    readContract: async ({
      functionName,
      blockNumber,
      abi,
    }: {
      functionName: string
      blockNumber: bigint
      abi: readonly { type: string; name?: string | undefined }[]
    }) => {
      expect(abi.some((item) => item.type === 'function' && item.name === functionName)).toBe(true)
      expect(blockNumber).toBe(99n)
      if (!(functionName in values)) throw new Error(`Unexpected read: ${functionName}`)
      return values[functionName]
    },
  } as unknown as Parameters<typeof quoteEarnDeposit>[0]
}
