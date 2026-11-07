import { readFileSync } from 'node:fs'
import { hostedEnvironments } from '@tempoxyz/contracts/deployments'
import { describe, expect, test } from 'vitest'
import { getAddress, type Address, type Hex } from 'viem'
import { assertHostedIdentities, validateHostedTarget } from './hosted.js'
import { readVaultCustody } from './custody.js'
import { knownIssuerCandidates } from './validate.js'
import type { E2eStack } from './context.js'

const address = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const genesis = `0x${'ab'.repeat(32)}` as Hex

describe('hosted identity guards', () => {
  test('refuses mainnet and unknown chains for public fixtures but keeps configured mainnet actors', () => {
    expect(() =>
      assertHostedIdentities(hostedEnvironments.mainnet.chainId, 'public-fixture'),
    ).toThrow('testnet')
    expect(() => assertHostedIdentities(123, 'public-fixture')).toThrow('testnet')
    expect(() =>
      assertHostedIdentities(hostedEnvironments.moderato.chainId, 'public-fixture'),
    ).not.toThrow()
    expect(() =>
      assertHostedIdentities(hostedEnvironments.mainnet.chainId, 'configured'),
    ).not.toThrow()
  })

  test('matches live chain and genesis independently of fixture availability', async () => {
    const client = (chainId: number, hash: Hex | null) =>
      ({
        getChainId: async () => chainId,
        getBlock: async () => ({ hash }),
      }) as unknown as Parameters<typeof validateHostedTarget>[0]
    const target = { chainId: 4217, genesisHash: genesis }
    await expect(validateHostedTarget(client(4217, genesis), target)).resolves.toBeUndefined()
    await expect(validateHostedTarget(client(42431, genesis), target)).rejects.toThrow('RPC chain')
    await expect(
      validateHostedTarget(client(4217, `0x${'cd'.repeat(32)}`), target),
    ).rejects.toThrow('genesis')
    await expect(validateHostedTarget(client(4217, null), target)).rejects.toThrow('genesis')
  })

  test('enforces the fixture-key guard before hosted reads and target validation before acceptance', () => {
    const source = readFileSync(new URL('./hosted.ts', import.meta.url), 'utf8')
    const run = source.slice(source.indexOf('export async function runHosted'))
    expect(run.indexOf('assertHostedIdentities(')).toBeLessThan(
      run.indexOf('await validateHostedProfile('),
    )
    expect(source.indexOf('await validateHostedTarget(')).toBeLessThan(
      source.indexOf('await validateDeployment('),
    )
  })
})

describe('vault custody', () => {
  const contracts = { asset: address(1), venue: address(2), earnVault: address(3) }
  const client = (assets: bigint, venueShares: bigint, aligned: boolean) =>
    ({
      readContract: async (request: { functionName: string; address: Address }) =>
        request.functionName === 'isAccountingAligned'
          ? aligned
          : request.address === contracts.asset
            ? assets
            : venueShares,
    }) as unknown as Parameters<typeof readVaultCustody>[0]

  test('accepts and snapshots unsolicited assets or shares without counting them as backing', async () => {
    await expect(readVaultCustody(client(1n, 7n, true), contracts)).resolves.toEqual({
      assets: 1n,
      venueShares: 7n,
    })
    const source = readFileSync(new URL('./integrity.ts', import.meta.url), 'utf8')
    expect(source).toContain('readVaultCustody(context.l1Public, context.contracts)')
    expect(source).toContain('stringify(current) === stringify(baseline)')
  })

  test('still fails on backing misalignment even when raw custody is zero', async () => {
    await expect(readVaultCustody(client(0n, 0n, false), contracts)).rejects.toThrow(
      'accounting is not aligned',
    )
  })
})

describe('knownIssuerCandidates', () => {
  test('includes nested fixture, factory and owner addresses, excludes only the legitimate vault issuer, and deduplicates', () => {
    const deployment = {
      contracts: {
        earnVault: address(1),
        factories: { nested: address(2) },
        periphery: { teller: address(3) },
      },
      operations: { owner: address(4), deploymentOwner: address(5), factory: address(2) },
      stablecoinFixture: {
        funder: address(6),
        conversionPool: { pool: address(7), oracle: address(8), customerId: genesis },
      },
    } as unknown as E2eStack
    expect(knownIssuerCandidates(deployment, { forwarder: address(9) }).sort()).toEqual(
      [2, 3, 4, 5, 6, 7, 8, 9].map(address).sort(),
    )
  })
})
