import { getAddress } from 'viem'
import { describe, expect, test } from 'vitest'

import { privateRoute, zoneProfile } from './profile.js'

const address = (value: string) => getAddress(`0x${value.padStart(40, '0')}`)
const earn = { privateAsset: address('6') }
const zone = { id: 7, chainId: 1, enableEarnShare: true } as const

describe('privateRoute', () => {
  test('returns the Earn binding of a Deposit and Redeem router on the Zone', () => {
    expect(
      privateRoute({ zone, zoneRouter: { zoneId: 7, ops: ['deposit', 'redeem'], earn } }),
    ).toBe(earn)
  })

  test.each([
    ['deposit only', { zoneId: 7, ops: ['deposit'], earn }],
    ['redeem only', { zoneId: 7, ops: ['redeem'], earn }],
    [
      'with spend',
      { zoneId: 7, ops: ['deposit', 'redeem', 'spend'], earn, spenders: [address('a')] },
    ],
    ['another Zone', { zoneId: 8, ops: ['deposit', 'redeem'], earn }],
  ] as const)('is undefined for a router %s', (_, zoneRouter) => {
    expect(
      privateRoute({ zone, zoneRouter: { ...zoneRouter, ops: [...zoneRouter.ops] } as never }),
    ).toBeUndefined()
  })

  test('is undefined without a Zone or a router', () => {
    expect(
      privateRoute({ zone: null, zoneRouter: { zoneId: 7, ops: ['deposit', 'redeem'], earn } }),
    ).toBeUndefined()
    expect(privateRoute({ zone, zoneRouter: null })).toBeUndefined()
  })
})

describe('zoneProfile.capabilities', () => {
  test('advertise private routing only for a Deposit and Redeem router', () => {
    const { privateRouting, routerSwaps } = zoneProfile.capabilities
    const both = { zone, zoneRouter: { zoneId: 7, ops: ['deposit', 'redeem'], earn } } as never
    const depositOnly = { zone, zoneRouter: { zoneId: 7, ops: ['deposit'], earn } } as never
    expect([privateRouting(both), routerSwaps(both)]).toEqual([true, true])
    expect([privateRouting(depositOnly), routerSwaps(depositOnly)]).toEqual([false, false])
  })
})
