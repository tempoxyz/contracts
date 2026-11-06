import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadEarnProfileBundle } from '../../deployments/core/bundle.js'
import { describe, expect, it } from 'vitest'
import {
  assertHostedFixtureChain,
  loadOptionalProfileFixture,
  validateProfileFixtureRuntime,
} from './profile-fixture.js'

const mainnetProfilePath = fileURLToPath(
  new URL('../../profiles/veda-mainnet/profile.json', import.meta.url),
)

describe('loadOptionalProfileFixture', () => {
  it('loads the checked-in mainnet profile without the retired synthetic fixture', () => {
    const { profile, record } = loadEarnProfileBundle(mainnetProfilePath)
    expect(profile.chainId).toBe(4217)
    expect(loadOptionalProfileFixture(mainnetProfilePath, profile, record)).toBeUndefined()
  })

  it('still rejects a synthetic fixture added to a mainnet profile', () => {
    const { profile, record } = loadEarnProfileBundle(mainnetProfilePath)
    const root = mkdtempSync(join(tmpdir(), 'mainnet-fixture-'))
    try {
      writeFileSync(
        join(root, 'fixture.json'),
        JSON.stringify({
          version: 1,
          profileId: profile.id,
          chainId: profile.chainId,
          genesisHash: record.target.genesisHash,
          generatedAt: '2026-01-01T00:00:00.000Z',
          engineFixtures: { vault: record.addresses.engine },
          runtimeCodeHashes: { vault: `0x${'11'.repeat(32)}` },
          transactions: [`0x${'22'.repeat(32)}`],
        }),
      )
      expect(() => loadOptionalProfileFixture(join(root, 'profile.json'), profile, record)).toThrow(
        'Hosted synthetic fixtures require a testnet; chain 4217 is not supported',
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it.each(['veda-moderato', 'e2e-moderato'])('preserves the testnet fixture for %s', (id) => {
    const path = fileURLToPath(new URL(`../../profiles/${id}/profile.json`, import.meta.url))
    const { profile, record } = loadEarnProfileBundle(path)
    expect(loadOptionalProfileFixture(path, profile, record)?.record).toMatchObject({
      profileId: id,
      chainId: 42431,
    })
  })
})

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
