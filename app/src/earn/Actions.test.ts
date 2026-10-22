import { describe, expect, test } from 'vitest'

import { actions, amountToken, limits, type ActionDefinition } from './Actions.js'

/** A hypothetical exact-withdraw action: the user types assets and bounds the shares it burns. */
const withdraw: ActionDefinition = {
  ...actions.redeem,
  amountToken: 'output',
  bound: 'maximumInput',
  private: undefined,
}

describe('action limits', () => {
  test('bounds the minimum output of an exact-input action', () => {
    expect(amountToken(actions.deposit)).toBe('asset')
    expect(limits(actions.deposit, 1_000_000n, 1_000_000n)).toEqual({
      input: 1_000_000n,
      output: 1_000_000n,
      bound: 995_000n,
    })
  })

  test('bounds the maximum input of an exact-output action, rounding up', () => {
    expect(amountToken(withdraw)).toBe('asset')
    expect(limits(withdraw, 1_000_000n, 990_000n)).toEqual({
      input: 990_000n,
      output: 1_000_000n,
      bound: 994_950n,
    })
    expect(limits(withdraw, 1n, 1n).bound).toBe(2n)
    expect(() => limits(withdraw, 1n, 0n)).toThrow()
  })
})
