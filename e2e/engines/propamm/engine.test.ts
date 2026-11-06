import { describe, expect, test } from 'vitest'
import { ContractFunctionRevertedError, encodeErrorResult, maxUint256 } from 'viem'
import type { E2eContext } from '../../harness/context.js'
import { assertBoundResults } from '../../modules/public/bounds.js'
import { engine } from './engine.js'

describe('redeemBoundErrors', () => {
  test('decodes the native pool revert with its pinned ABI and requires a successful control', () => {
    const configured = engine.redeemBoundErrors!({} as E2eContext)!
    // Original native simulation: SlippageExceeded(maxUint256, 1_000_000).
    const error = new ContractFunctionRevertedError({
      abi: configured.abi!.filter((item) => item.type === 'error'),
      data: `0x71c4efed${'ff'.repeat(32)}${'0'.repeat(58)}0f4240`,
      functionName: 'redeem',
    })
    expect(error.data).toMatchObject({
      errorName: 'SlippageExceeded',
      args: [maxUint256, 1_000_000n],
    })
    const rejected = { status: 'failure', error }
    const ok = { status: 'success' }
    expect(() => assertBoundResults([ok, rejected], [ok, ok], configured.errors)).not.toThrow()
    expect(() => assertBoundResults([ok, rejected], [ok, rejected], configured.errors)).toThrow(
      'relaxed bound',
    )
  })
  test('rejects unrelated venue failures', () => {
    const configured = engine.redeemBoundErrors!({} as E2eContext)!
    const rejected = {
      status: 'failure',
      error: new ContractFunctionRevertedError({
        abi: configured.abi!,
        data: encodeErrorResult({ abi: configured.abi!, errorName: 'AmountIsZero' }),
        functionName: 'redeem',
      }),
    }
    expect(() =>
      assertBoundResults([rejected], [{ status: 'success' }], configured.errors),
    ).toThrow('did not decode')
  })
})
