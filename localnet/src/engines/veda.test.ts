import { getAddress } from 'viem'
import { describe, expect, it, vi } from 'vitest'
import { veda } from './veda.js'

const address = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const venue = {
  engine: address(1),
  vault: address(2),
  baseAsset: address(3),
  engineFixtures: {
    registry: address(4),
    queue: address(5),
    teller: address(6),
    accountant: address(7),
    forwardingSolver: address(8),
    stockSolver: address(9),
  },
}

function client(overrides: Record<string, unknown> = {}) {
  return {
    readContract: vi.fn(
      async ({ address: target, functionName }: { address: string; functionName: string }) => {
        const key = `${target}:${functionName}`
        if (Object.hasOwn(overrides, key)) return overrides[key]
        if (functionName === 'engine') return venue.engine
        if (functionName === 'peripheryRegistry') return venue.engineFixtures.registry
        if (functionName === 'queue') return venue.engineFixtures.queue
        if (functionName === 'teller') return venue.engineFixtures.teller
        if (functionName === 'accountant') return venue.engineFixtures.accountant
        if (functionName === 'vault') return venue.vault
        if (functionName === 'asset') return venue.baseAsset
        if (functionName === 'authorizedForwarder') return true
        if (functionName === 'boringSolver') return venue.engineFixtures.stockSolver
        throw new Error(`Unexpected ${key}`)
      },
    ),
  }
}

describe('Veda fixture validation', () => {
  it('accepts the currently bound queue and forwarding solver', async () => {
    await expect(veda.validate!(client() as never, venue)).resolves.toBeUndefined()
  })
  it.each(['queue', 'teller', 'accountant'])(
    'rejects stale %s metadata after an engine rotation',
    async (field) => {
      await expect(
        veda.validate!(client({ [`${venue.engine}:${field}`]: address(20) }) as never, venue),
      ).rejects.toThrow(`active ${field}`)
    },
  )
  it('rejects a forwarder still wired to the old queue even when the fixture names the live queue', async () => {
    await expect(
      veda.validate!(
        client({ [`${venue.engineFixtures.forwardingSolver}:queue`]: address(20) }) as never,
        venue,
      ),
    ).rejects.toThrow('forwarder queue')
  })
  it('rejects a deauthorized forwarder before creating a redemption', async () => {
    await expect(
      veda.validate!(client({ [`${venue.engine}:authorizedForwarder`]: false }) as never, venue),
    ).rejects.toThrow('not authorized')
  })
})
