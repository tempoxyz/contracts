import { getAddress, zeroAddress, zeroHash } from 'viem'
import { describe, expect, test } from 'vitest'

import { inspectEarnDeployment } from './inspection.js'
import { parseEarnDeploymentProfile } from './profile.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as `0x${string}`
const customerId = `0x${'c'.repeat(64)}` as const
const issuerRole = `0x${'1'.repeat(64)}` as const
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'router-inspection-test',
    chainId: 4217,
    owner: address('4'),
    engine: { kind: 'erc4626', address: address('1') },
    zone: {
      id: 1,
      enableEarnShare: true,
      router: { privateAsset: address('6'), pool: address('7'), customerId },
    },
  },
  { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
)
const outputs = {
  asset: address('a'),
  earnVault: address('b'),
  earnShare: address('c'),
  earnFees: address('d'),
  earnRouter: address('e'),
  zonePortal: address('f'),
}

type Overrides = Partial<Record<string, unknown>>

function client(overrides: Overrides = {}) {
  const values: Record<string, unknown> = {
    [`${address('1')}.asset`]: outputs.asset,
    [`${address('1')}.owner`]: profile.owner,
    [`${address('1')}.earnVault`]: outputs.earnVault,
    [`${outputs.earnVault}.asset`]: outputs.asset,
    [`${outputs.earnVault}.engine`]: address('1'),
    [`${outputs.earnVault}.earnShare`]: outputs.earnShare,
    [`${outputs.earnVault}.earnFees`]: outputs.earnFees,
    [`${outputs.earnVault}.operator`]: profile.owner,
    [`${outputs.earnFees}.earnVault`]: outputs.earnVault,
    [`${outputs.earnFees}.earnShare`]: outputs.earnShare,
    [`${outputs.earnShare}.ISSUER_ROLE`]: issuerRole,
    [`${outputs.earnShare}.transferPolicyId`]: 1n,
    [`${address('3')}.predictEarnShare`]: outputs.earnShare,
    [`${address('3')}.predictEarnFees`]: outputs.earnFees,
    [`${outputs.earnRouter}.allowedZoneId`]: 1,
    [`${outputs.earnRouter}.earnVault`]: outputs.earnVault,
    [`${outputs.earnRouter}.privateAsset`]: address('6'),
    [`${outputs.earnRouter}.vaultAsset`]: outputs.asset,
    [`${outputs.earnRouter}.earnShare`]: outputs.earnShare,
    [`${outputs.earnRouter}.pool`]: address('7'),
    [`${outputs.earnRouter}.customerId`]: customerId,
    [`${outputs.earnRouter}.privateAssetIsBase`]: true,
    [`${outputs.earnRouter}.liquidityStatus`]: [false, true, true, 10n, 20n],
    [`${address('7')}.baseToken`]: address('6'),
    [`${address('7')}.quoteToken`]: outputs.asset,
    [`${address('7')}.oracle`]: address('8'),
    [`${address('7')}.maxOracleAge`]: 86_400n,
    [`${address('8')}.latestPrice`]: [100_000_000n, 1_800_000_000n],
    [`${outputs.zonePortal}.isTokenEnabled`]: true,
    [`${outputs.zonePortal}.areDepositsActive`]: true,
    ...overrides,
  }
  return {
    getBlock: async () => ({ timestamp: (overrides.now as bigint | undefined) ?? 1_800_000_100n }),
    getCode: async () => '0x01' as const,
    readContract: async ({
      address: target,
      functionName,
      args,
    }: {
      address: string
      functionName: string
      args?: readonly unknown[]
    }) => {
      if (functionName === 'hasRole') {
        const [account, role] = args as [string, string]
        return getAddress(target) === outputs.earnShare
          ? account === outputs.earnVault && role === issuerRole
          : false
      }
      const key = `${getAddress(target)}.${functionName}`
      if (!(key in values)) throw new Error(`unexpected read ${key}`)
      const value = values[key]
      if (value instanceof Error) throw value
      return value
    },
  }
}

describe('SingleZoneEarnRouter inspection', () => {
  test('rejects router pool, customer, and pool-pair binding mismatches', async () => {
    for (const [overrides, message] of [
      [{ [`${outputs.earnRouter}.pool`]: address('9') }, 'router PropAMM pool'],
      [{ [`${outputs.earnRouter}.customerId`]: zeroHash }, 'Router customer ID'],
      [{ [`${outputs.earnRouter}.privateAssetIsBase`]: false }, 'pool base token'],
      [{ [`${address('7')}.quoteToken`]: address('9') }, 'pool quote token'],
      [{ [`${outputs.earnRouter}.privateAsset`]: address('9') }, 'router private asset'],
    ] as const) {
      await expect(
        inspectEarnDeployment(client(overrides) as never, profile, outputs),
      ).rejects.toThrow(message)
    }
  })

  test('accepts an engine handed off with its EarnVault operator and rejects a split handoff', async () => {
    const nominee = address('9')
    const handedOff = {
      [`${address('1')}.owner`]: nominee,
      [`${outputs.earnVault}.operator`]: nominee,
    }
    await expect(
      inspectEarnDeployment(client(handedOff) as never, profile, outputs),
    ).resolves.toMatchObject({ router: { status: 'ready' } })
    // The engine moved without the EarnVault operator, or to an unrelated account.
    for (const operator of [profile.owner, address('8')]) {
      await expect(
        inspectEarnDeployment(
          client({ ...handedOff, [`${outputs.earnVault}.operator`]: operator }) as never,
          profile,
          outputs,
        ),
      ).rejects.toThrow('Engine owner is')
    }
  })

  test('rejects pool bindings on a router without a pool', async () => {
    const sameAsset = parseEarnDeploymentProfile(
      {
        version: 1,
        id: 'router-inspection-test',
        chainId: 4217,
        owner: address('4'),
        engine: { kind: 'erc4626', address: address('1') },
        zone: { id: 1, enableEarnShare: true, router: { privateAsset: outputs.asset } },
      },
      { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
    )
    const bindings = {
      [`${outputs.earnRouter}.privateAsset`]: outputs.asset,
      [`${outputs.earnRouter}.pool`]: zeroAddress,
      [`${outputs.earnRouter}.customerId`]: zeroHash,
      [`${outputs.earnRouter}.privateAssetIsBase`]: false,
      // A pool-less router never needs a pool or liquidity read.
      [`${outputs.earnRouter}.liquidityStatus`]: new Error('unexpected liquidity read'),
    }
    for (const [overrides, message] of [
      [{ [`${outputs.earnRouter}.pool`]: address('7') }, 'router PropAMM pool'],
      [{ [`${outputs.earnRouter}.customerId`]: customerId }, 'Router customer ID'],
      [{ [`${outputs.earnRouter}.privateAsset`]: address('6') }, 'router private asset'],
    ] as const) {
      await expect(
        inspectEarnDeployment(client({ ...bindings, ...overrides }) as never, sameAsset, outputs),
      ).rejects.toThrow(message)
    }
  })
})
