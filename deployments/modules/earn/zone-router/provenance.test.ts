import { describe, expect, test, vi } from 'vitest'
import { concatHex, zeroAddress, type Hex } from 'viem'
import { requireRouterProvenance } from './provenance.js'

const options = {
  address: `0x${'1'.repeat(40)}` as const,
  project: 'earn' as const,
  contract: 'src/router/SingleZoneEarnRouter.sol:SingleZoneEarnRouter' as const,
  constructorArgs: `0x${'2'.repeat(64)}` as const,
}
const code = '0x600160005260206000f3' as const

describe('requireRouterProvenance', () => {
  test('compares exact runtime from a read-only canonical constructor call', async () => {
    const compile = vi.fn(() => code)
    const getCode = vi.fn(async () => '0x60011234' as const)
    const call = vi.fn(async () => ({ data: '0x60011234' as const }))
    await requireRouterProvenance({ getCode, call } as never, options, compile)
    expect(compile).toHaveBeenCalledWith(options)
    expect(getCode).toHaveBeenCalledWith({ address: options.address })
    expect(call).toHaveBeenCalledWith({
      account: zeroAddress,
      data: concatHex([code, options.constructorArgs]),
    })
    expect(call.mock.calls[0]).toHaveLength(1)
  })

  test.each([
    ['0x60011235', '0x60011234'],
    ['0x60021234', '0x60011234'],
    ['0x', '0x60011234'],
    [undefined, '0x60011234'],
    ['0x60011234', undefined],
  ])(
    'rejects altered code, immutable bytes, or missing evidence %s/%s',
    async (actual, expected) => {
      const client = { getCode: async () => actual, call: async () => ({ data: expected }) }
      await expect(requireRouterProvenance(client as never, options, () => code)).rejects.toThrow(
        'canonical implementation provenance',
      )
    },
  )

  test('propagates RPC and compiler failure instead of admitting unverified code', async () => {
    const error = new Error('verification unavailable')
    const client = {
      getCode: async () => code,
      call: async () => {
        throw error
      },
    }
    await expect(requireRouterProvenance(client as never, options, () => code)).rejects.toBe(error)
    const compile = (): Hex => {
      throw error
    }
    await expect(requireRouterProvenance(client as never, options, compile)).rejects.toBe(error)
  })
})
