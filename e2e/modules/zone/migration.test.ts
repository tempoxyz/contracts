import { describe, expect, it } from 'vitest'
import {
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeFunctionResult,
  type Hex,
} from 'viem'
import { Abis } from 'viem/tempo'
import { type E2eZoneContext } from '../../harness/context.js'
import { assertPrivateMigrationCredit, canPrivatizeMigrationDust } from './migration.js'

describe('assertPrivateMigrationCredit', () => {
  const options = {
    privateEarnShares: 93n,
    netAmount: 93n,
    fee: 7n,
    publicDust: 1n,
    mintedEarnShares: 101n,
  }
  it('accounts for actual Portal fees and bounded public dust independently', () => {
    expect(() => assertPrivateMigrationCredit(options)).not.toThrow()
    expect(() => assertPrivateMigrationCredit({ ...options, privateEarnShares: 100n })).toThrow(
      'fully attributable',
    )
  })
  it('rejects partial private delivery, unexplained mint and negative public dust', () => {
    expect(() => assertPrivateMigrationCredit({ ...options, privateEarnShares: 1n })).toThrow(
      'fully attributable',
    )
    expect(() => assertPrivateMigrationCredit({ ...options, mintedEarnShares: 102n })).toThrow(
      'fully attributable',
    )
    expect(() =>
      assertPrivateMigrationCredit({ ...options, publicDust: -1n, mintedEarnShares: 99n }),
    ).toThrow('dust')
  })
})

describe('canPrivatizeMigrationDust', () => {
  it.each([
    { deposit: 0n, bounce: 2n, dust: 1n, expected: false },
    { deposit: 1n, bounce: 2n, dust: 2n, expected: false },
    { deposit: 1n, bounce: 2n, dust: 3n, expected: false },
    { deposit: 1n, bounce: 2n, dust: 4n, expected: true },
    { deposit: 0n, bounce: 0n, dust: 1n, expected: true },
  ])('respects both fees for $deposit + $bounce and dust $dust', async (options) => {
    const { context, reads } = feeContext(options)
    expect(await canPrivatizeMigrationDust(context, options.dust)).toBe(options.expected)
    expect(reads).toEqual([
      { functionName: 'calculateDepositFee', block: '0x2a' },
      { functionName: 'calculateBouncebackFee', block: '0x2a' },
    ])
  })

  it('does not need a fee quote when no dust remains', async () => {
    const { context, reads } = feeContext({ deposit: 0n, bounce: 0n })
    expect(await canPrivatizeMigrationDust(context, 0n)).toBe(false)
    expect(reads).toEqual([])
  })

  it('does not fall back to a smaller minimum if the bounce-back quote fails', async () => {
    const { context } = feeContext({ deposit: 0n, bounce: 0n, failBounce: true })
    await expect(canPrivatizeMigrationDust(context, 1n)).rejects.toThrow('fee quote unavailable')
  })
})

function feeContext(options: { deposit: bigint; bounce: bigint; failBounce?: boolean }) {
  const reads: { functionName: string; block: unknown }[] = []
  const client = createPublicClient({
    transport: custom(
      {
        async request({ method, params }) {
          if (method === 'eth_blockNumber') return '0x2a'
          if (method !== 'eth_call') throw new Error(`Unexpected method ${method}`)
          const [call, block] = params as [{ data: Hex }, unknown]
          const { functionName } = decodeFunctionData({ abi: Abis.zonePortal, data: call.data })
          reads.push({ functionName, block })
          if (functionName === 'calculateBouncebackFee' && options.failBounce)
            throw new Error('fee quote unavailable')
          if (functionName !== 'calculateDepositFee' && functionName !== 'calculateBouncebackFee')
            throw new Error(`Unexpected read ${functionName}`)
          return encodeFunctionResult({
            abi: Abis.zonePortal,
            functionName,
            result: functionName === 'calculateDepositFee' ? options.deposit : options.bounce,
          })
        },
      },
      { retryCount: 0 },
    ),
  })
  return {
    context: {
      l1Public: client,
      deployment: { network: { zone: { portal: `0x${'11'.repeat(20)}` } } },
    } as unknown as E2eZoneContext,
    reads,
  }
}
