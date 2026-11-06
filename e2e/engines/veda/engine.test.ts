import { describe, expect, test } from 'vitest'
import { ContractFunctionRevertedError, encodeErrorResult, parseAbi } from 'viem'
import type { E2eContext } from '../../harness/context.js'
import { assertBoundResults } from '../../modules/public/bounds.js'
import { engine } from './engine.js'

describe('redeemBoundErrors', () => {
  test('recognizes the LocalVeda reason only when the loader supplies its teller fixture', () => {
    const context = { engineFixtures: {} } as E2eContext
    expect(engine.redeemBoundErrors!(context)).toBeUndefined()
    const configured = engine.redeemBoundErrors!({
      ...context,
      engineFixtures: { teller: `0x${'ab'.repeat(20)}` },
    })!
    expect(configured.errors).toEqual([{ reason: 'VEDA_MINIMUM_ASSETS' }])
    const abi = parseAbi(['error Error(string)'])
    const rejected = (reason: string) => ({
      status: 'failure',
      error: new ContractFunctionRevertedError({
        abi,
        data: encodeErrorResult({ abi, errorName: 'Error', args: [reason] }),
        functionName: 'redeem',
      }),
    })
    const ok = { status: 'success' }
    expect(() =>
      assertBoundResults([ok, rejected('VEDA_MINIMUM_ASSETS')], [ok, ok], configured.errors),
    ).not.toThrow()
    expect(() =>
      assertBoundResults([ok, rejected('VEDA_SHARES_LOCKED')], [ok, ok], configured.errors),
    ).toThrow('did not decode')
  })
})
