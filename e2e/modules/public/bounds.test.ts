import { describe, expect, expectTypeOf, test } from 'vitest'
import { ContractFunctionRevertedError, encodeErrorResult } from 'viem'
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
