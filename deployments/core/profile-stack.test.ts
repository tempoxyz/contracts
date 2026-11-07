import { getAddress, toFunctionSelector, zeroAddress } from 'viem'
import { describe, expect, test } from 'vitest'
import { profileStack } from './profile-stack.js'
import { parseEarnDeploymentProfile } from './profile.js'
import type { EarnDeploymentRecord } from './record.js'

const address = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const [engine, vault, share, fees, asset, venue, owner, registry, teller, accountant, authority] =
  Array.from({ length: 11 }, (_, i) => address(i + 1))
const genesisHash = `0x${'11'.repeat(32)}` as const
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'stack-validation',
    chainId: 4217,
    owner,
    engine: { kind: 'veda', address: engine },
    core: { migrationMode: 'OperatorEnabled' },
  },
  { deployer: address(12) },
)
const record = {
  target: { chainId: 4217, genesisHash },
  addresses: { engine, earnVault: vault, earnShare: share, earnFees: fees, asset },
  source: {},
  generatedAt: '2026-01-01T00:00:00.000Z',
  deploymentBlock: '1',
  actions: {},
} as unknown as EarnDeploymentRecord
const environment = {
  id: 'test',
  tempoRpcUrl: 'https://example.com',
  explorerUrl: 'https://example.com',
}
const values: Record<string, unknown> = {
  [`${vault}.engine`]: engine,
  [`${vault}.asset`]: asset,
  [`${vault}.earnShare`]: share,
  [`${vault}.earnFees`]: fees,
  [`${vault}.operator`]: owner,
  [`${vault}.engineMigrationMode`]: 1,
  [`${engine}.asset`]: asset,
  [`${engine}.earnVault`]: vault,
  [`${engine}.vault`]: venue,
  [`${engine}.peripheryRegistry`]: registry,
  [`${engine}.teller`]: teller,
  [`${engine}.accountant`]: accountant,
  [`${engine}.queue`]: zeroAddress,
  [`${fees}.earnVault`]: vault,
  [`${fees}.earnShare`]: share,
  [`${registry}.engine`]: engine,
  [`${registry}.vault`]: venue,
  [`${registry}.baseAsset`]: asset,
  [`${accountant}.vault`]: venue,
  [`${accountant}.base`]: asset,
  [`${venue}.authority`]: authority,
}
function client(overrides: Record<string, unknown> = {}) {
  const reads: string[] = []
  const result = {
    getChainId: async () => overrides.chainId ?? 4217,
    getBlock: async () => ({
      hash: overrides.genesisHash === undefined ? genesisHash : overrides.genesisHash,
    }),
    getCode: async () => '0x01',
    readContract: async ({
      address: target,
      functionName,
      args,
    }: {
      address: string
      functionName: string
      args?: readonly unknown[]
    }) => {
      const key = `${getAddress(target)}.${functionName}`
      reads.push(key)
      if (key in overrides) return overrides[key]
      if (functionName === 'supportsInterface')
        return args?.[0] === toFunctionSelector('depositInKind(uint256,address)')
      if (key in values) return values[key]
      if (['name', 'symbol'].includes(functionName)) return 'Token'
      if (functionName === 'decimals') return 6
      throw new Error(`Unexpected read ${key}`)
    },
  }
  return { client: result as never, reads }
}
function project(overrides: Record<string, unknown> = {}) {
  return profileStack({ client: client(overrides).client, environment, profile, record })
}

describe('profileStack', () => {
  test('fences the record target before contract reads, including same-chain reset and missing genesis', async () => {
    for (const overrides of [
      { chainId: 42431 },
      { genesisHash: `0x${'22'.repeat(32)}` },
      { genesisHash: null },
    ]) {
      const rpc = client(overrides)
      await expect(
        profileStack({ client: rpc.client, environment, profile, record }),
      ).rejects.toThrow(/RPC (chain ID|genesis hash)/)
      expect(rpc.reads).toEqual([])
    }
  })
  test('advertises queued redemption only when the Veda engine has a queue', async () => {
    expect((await project()).capabilities.asyncRedeem).toBe(false)
    const queued = await project({ [`${engine}.queue`]: address(30) })
    expect(queued.capabilities.asyncRedeem).toBe(true)
    expect(queued.contracts.periphery?.queue).toBe(address(30))
  })
  test('projects cached Veda bindings without registry-version or canCall readiness reads', async () => {
    const rpc = client()
    await profileStack({ client: rpc.client, environment, profile, record })
    expect(rpc.reads).not.toContain(`${registry}.version`)
    expect(rpc.reads.some((key) => key.endsWith('.canCall'))).toBe(false)
    await expect(project({ [`${registry}.engine`]: address(99) })).rejects.toThrow(
      'registry engine',
    )
  })
  test('projects current engine and venue after a supported cross-kind migration', async () => {
    const migrated = address(20)
    const nextVenue = address(21)
    const overrides = {
      [`${vault}.engine`]: migrated,
      [`${migrated}.asset`]: asset,
      [`${migrated}.earnVault`]: vault,
      [`${migrated}.vault`]: nextVenue,
    }
    const stack = await project(overrides)
    expect(stack.contracts).toMatchObject({
      engine: migrated,
      creationEngine: engine,
      venue: nextVenue,
    })
    expect(stack.engineKind).toBe('erc4626')
    expect(stack.capabilities).toMatchObject({ asyncRedeem: false, inKindDeposit: true })
    expect(record.addresses.engine).toBe(engine)
    await expect(
      project({ ...overrides, [`${migrated}.supportsInterface`]: false }),
    ).rejects.toThrow('unknown or ambiguous')
    await expect(
      project({ ...overrides, [`${migrated}.peripheryRegistry`]: registry }),
    ).rejects.toThrow('unknown or ambiguous')
    for (const [key, value] of [
      [`${migrated}.asset`, address(99)],
      [`${migrated}.earnVault`, address(99)],
      [`${vault}.engineMigrationMode`, 0],
    ] as const)
      await expect(project({ ...overrides, [key]: value })).rejects.toThrow()
  })
})
