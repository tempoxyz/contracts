import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadEarnProfileBundle } from '../../deployments/core/bundle.js'
import { getAddress, keccak256, type Address } from 'viem'
import { describe, expect, it } from 'vitest'
import type { DeploymentPublicClient } from '../harness/context.js'
import {
  assertHostedFixtureChain,
  loadOptionalProfileFixture,
  validateProfileFixtureRuntime,
  type ProfileFixtureRecord,
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

describe('validateProfileFixtureRuntime venue provenance', () => {
  it.each(['engine', 'stablecoin'] as const)(
    'accepts a matching %s fixture venue',
    async (kind) => {
      const { client, fixture, deployment } = runtimeFixture(kind)
      await expect(
        validateProfileFixtureRuntime(client, fixture, deployment),
      ).resolves.toBeUndefined()
    },
  )

  it.each(['engine', 'stablecoin'] as const)(
    'rejects a stale %s fixture even when the live stack and engine agree',
    async (kind) => {
      const { client, fixture, deployment } = runtimeFixture(kind)
      if (fixture.stablecoinFixture) fixture.stablecoinFixture.venue = address(20)
      else fixture.engineFixtures!.vault = address(20)
      // Both venues still have the recorded runtime, so hashes alone cannot catch a stale record.
      await expect(validateProfileFixtureRuntime(client, fixture, deployment)).rejects.toThrow(
        'venue does not match the live deployment',
      )
    },
  )

  it('requires a recorded venue instead of trusting a value read from the live engine', async () => {
    const { client, fixture, deployment } = runtimeFixture('engine')
    delete fixture.engineFixtures!.vault
    delete fixture.runtimeCodeHashes.vault
    await expect(validateProfileFixtureRuntime(client, fixture, deployment)).rejects.toThrow(
      'has no recorded venue',
    )
  })

  it('rejects conflicting venue records when both fixture forms are present', async () => {
    const { client, fixture, deployment } = runtimeFixture('stablecoin')
    fixture.engineFixtures = { vault: address(20) }
    fixture.runtimeCodeHashes.vault = keccak256('0x6000')
    await expect(validateProfileFixtureRuntime(client, fixture, deployment)).rejects.toThrow(
      'venue records disagree',
    )
  })

  it('still compares the Veda engine with the recorded vault after reading the stack', async () => {
    const { client, fixture, deployment } = runtimeFixture('engine', address(20))
    await expect(validateProfileFixtureRuntime(client, fixture, deployment)).rejects.toThrow(
      'Veda fixture vault',
    )
  })
})

function address(n: number) {
  return getAddress(`0x${n.toString(16).padStart(40, '0')}`)
}

function runtimeFixture(kind: 'engine' | 'stablecoin', liveVault = address(2)) {
  const engine = address(1)
  const vault = address(2)
  const asset = address(3)
  const periphery = {
    registry: address(4),
    queue: address(5),
    teller: address(6),
    accountant: address(7),
    forwardingSolver: address(8),
    stockSolver: address(9),
  }
  const genesisHash = `0x${'11'.repeat(32)}` as const
  const fixture: ProfileFixtureRecord = {
    version: 1,
    profileId: 'runtime-fixture',
    chainId: 42431,
    genesisHash,
    generatedAt: '2026-01-01T00:00:00.000Z',
    ...(kind === 'engine'
      ? { engineFixtures: { vault, ...periphery } }
      : {
          stablecoinFixture: {
            baseAsset: asset,
            alternateAsset: address(10),
            venue: vault,
            funder: null,
          },
        }),
    runtimeCodeHashes: Object.fromEntries(
      (kind === 'engine'
        ? ['vault', ...Object.keys(periphery)]
        : ['baseAsset', 'alternateAsset', 'venue']
      ).map((name) => [name, keccak256('0x6000')]),
    ),
    transactions: [`0x${'22'.repeat(32)}`],
  }
  const client = {
    getBlock: async () => ({ hash: genesisHash }),
    getCode: async () => '0x6000',
    readContract: async ({ functionName }: { address: Address; functionName: string }) => {
      const values: Record<string, Address | boolean> = {
        engine,
        peripheryRegistry: periphery.registry,
        queue: periphery.queue,
        teller: periphery.teller,
        accountant: periphery.accountant,
        vault: liveVault,
        asset,
        authorizedForwarder: true,
        boringSolver: periphery.stockSolver,
      }
      if (!(functionName in values)) throw new Error(`Unexpected read: ${functionName}`)
      return values[functionName]
    },
  } as unknown as DeploymentPublicClient
  return {
    client,
    fixture,
    deployment: {
      engineKind: kind === 'engine' ? ('veda' as const) : ('erc4626' as const),
      engine,
      asset,
      venue: vault,
    },
  }
}
