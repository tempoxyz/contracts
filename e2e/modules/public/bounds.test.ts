import { describe, expect, expectTypeOf, test } from 'vitest'
import { BaseError, ContractFunctionRevertedError, encodeErrorResult, parseAbi } from 'viem'
import { Actions } from 'viem/tempo'
import { earnVaultAbi } from '@tempoxyz/contracts/abis'
import { assertBoundResults, simulateBound } from './bounds.js'

const ok = { status: 'success' }
const failure = (errorName: 'ExceedsMaxEarnShares' | 'DepositsPaused') => ({
  status: 'failure',
  error: new ContractFunctionRevertedError({
    abi: earnVaultAbi,
    data: encodeErrorResult({ abi: earnVaultAbi, errorName }),
    functionName: 'withdrawExact',
  }),
})

describe('assertBoundResults', () => {
  test('requires a decoded bound error and the same operation to succeed with its bound relaxed', () => {
    expect(() =>
      assertBoundResults([ok, failure('ExceedsMaxEarnShares')], [ok, ok], ['ExceedsMaxEarnShares']),
    ).not.toThrow()
    expect(() =>
      assertBoundResults([ok, failure('DepositsPaused')], [ok, ok], ['ExceedsMaxEarnShares']),
    ).toThrow('did not decode')
    expect(() =>
      assertBoundResults(
        [ok, failure('ExceedsMaxEarnShares')],
        [ok, failure('DepositsPaused')],
        ['ExceedsMaxEarnShares'],
      ),
    ).toThrow('relaxed bound')
  })
  test('accepts only the exact decoded bound reason, even inside a wrapper', () => {
    const expected = [{ reason: 'MINIMUM_ASSETS' }]
    const rejected = reasonFailure('MINIMUM_ASSETS')
    rejected.error = new BaseError('wrapped simulation failure', { cause: rejected.error })
    expect(() => assertBoundResults([ok, rejected], [ok, ok], expected)).not.toThrow()
    for (const reason of ['SHARES_LOCKED', 'MINIMUM_MINT', 'MINIMUM_ASSETS_EXTRA'])
      expect(() => assertBoundResults([ok, reasonFailure(reason)], [ok, ok], expected)).toThrow(
        'did not decode',
      )
    expect(() => assertBoundResults([ok, rejected], [ok, ok], ['Error'])).toThrow('did not decode')
    expect(() => assertBoundResults([ok, rejected], [ok, rejected], expected)).toThrow(
      'relaxed bound',
    )
    expect(() => assertBoundResults([rejected, rejected], [ok, ok], expected)).toThrow(
      'setup call failed',
    )
  })
  test('rejects arithmetic panics and unknown selectors instead of treating any revert as a bound', () => {
    const abi = parseAbi(['error Panic(uint256)'])
    for (const data of [
      encodeErrorResult({ abi, errorName: 'Panic', args: [0x11n] }),
      '0xdeadbeef',
    ] as const) {
      const rejected = {
        status: 'failure',
        error: new ContractFunctionRevertedError({ abi, data, functionName: 'redeem' }),
      }
      expect(() =>
        assertBoundResults(
          [ok, rejected],
          [ok, ok],
          ['MinimumAssetsNotMet', 'Panic', { reason: 'MINIMUM_ASSETS' }],
        ),
      ).toThrow('did not decode')
    }
  })
  test('does not credit transport failures, successful probes, or a failed approval', () => {
    expect(() =>
      assertBoundResults(
        [ok, { status: 'failure', error: new Error('RPC unavailable') }],
        [ok, ok],
        ['ExceedsMaxEarnShares'],
      ),
    ).toThrow('contract error')
    expect(() => assertBoundResults([ok, ok], [ok, ok], ['ExceedsMaxEarnShares'])).toThrow(
      'contract error',
    )
    expect(() =>
      assertBoundResults([failure('ExceedsMaxEarnShares'), ok], [ok, ok], ['ExceedsMaxEarnShares']),
    ).toThrow('setup call failed')
  })
})

describe('simulateBound input', () => {
  test('accepts each SDK atomic call builder without losing the encoded call shape', () => {
    type Calls = Parameters<typeof simulateBound>[1]['calls']
    expectTypeOf<ReturnType<typeof Actions.earn.deposit.calls>>().toExtend<Calls>()
    expectTypeOf<ReturnType<typeof Actions.earn.depositShares.calls>>().toExtend<Calls>()
    expectTypeOf<ReturnType<typeof Actions.earn.redeem.calls>>().toExtend<Calls>()
    expectTypeOf<ReturnType<typeof Actions.earn.withdrawExact.calls>>().toExtend<Calls>()
  })
})

function reasonFailure(reason: string): { status: string; error: BaseError } {
  const abi = parseAbi(['error Error(string)'])
  return {
    status: 'failure',
    error: new ContractFunctionRevertedError({
      abi,
      data: encodeErrorResult({ abi, errorName: 'Error', args: [reason] }),
      functionName: 'redeem',
    }),
  }
}
