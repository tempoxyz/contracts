import { describe, expect, test, vi } from 'vitest'
import { assertCaseIntegrity, captureCaseIntegrity } from './integrity.js'
import type { E2eContext } from './context.js'

vi.mock('./modules.js', () => ({ moduleIntegrity: [] }))
const address = `0x${'11'.repeat(20)}` as const
const asset = `0x${'22'.repeat(20)}` as const
const venue = `0x${'33'.repeat(20)}` as const

function fixture() {
  const state = { assets: 1n, venueShares: 7n, aligned: true }
  const context = {
    contracts: { asset, venue, earnVault: address, earnShare: address },
    l1Public: {
      readContract: async (request: { functionName: string; address: string }) => {
        switch (request.functionName) {
          case 'balanceOf':
            return request.address === asset ? state.assets : state.venueShares
          case 'isAccountingAligned':
            return state.aligned
          case 'depositsPaused':
            return false
          case 'transferPolicyId':
            return 2n
          case 'operator':
          case 'emergencyGuardian':
            return address
          default:
            throw new Error(`Unexpected read ${request.functionName}`)
        }
      },
    },
  } as unknown as E2eContext
  return { state, context }
}

describe('assertCaseIntegrity', () => {
  test('allows preexisting unsolicited custody only while it remains unchanged', async () => {
    const { context, state } = fixture()
    const baseline = await captureCaseIntegrity(context)
    await expect(assertCaseIntegrity(context, baseline)).resolves.toBeUndefined()
    state.assets += 1n
    await expect(assertCaseIntegrity(context, baseline)).rejects.toThrow('vault custody')
    state.assets -= 1n
    state.venueShares -= 1n
    await expect(assertCaseIntegrity(context, baseline)).rejects.toThrow('vault custody')
  })
  test('does not let preserved dust hide an accounting loss', async () => {
    const { context, state } = fixture()
    const baseline = await captureCaseIntegrity(context)
    state.aligned = false
    await expect(assertCaseIntegrity(context, baseline)).rejects.toThrow(
      'accounting is not aligned',
    )
  })
})
