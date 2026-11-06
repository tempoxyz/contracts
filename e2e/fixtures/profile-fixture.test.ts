import { describe, expect, it } from 'vitest'
import { assertHostedFixtureChain, validateProfileFixtureRuntime } from './profile-fixture.js'

describe('hosted fixture consumption', () => {
  it('allows testnet fixture funding only', () => {
    expect(() => assertHostedFixtureChain(42431)).not.toThrow()
    for (const chainId of [4217, 1337, 1])
      expect(() => assertHostedFixtureChain(chainId)).toThrow('require a testnet')
  })
  it('rejects valuable-chain records before any live read, funding, or fixture use', async () => {
    await expect(
      validateProfileFixtureRuntime({} as never, { chainId: 4217 } as never, {} as never),
    ).rejects.toThrow('require a testnet')
  })
})
