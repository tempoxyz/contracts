import {
  ContractFunctionZeroDataError,
  decodeFunctionData,
  getAddress,
  type Address,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { describe, expect, test, vi } from 'vitest'

import { zonePortalAbi } from '../../../abis/index.js'
import { zoneFactoryAddress, zoneMessengerAddress } from '../../../chain/zone.js'
import { parseEarnDeploymentProfile } from '../../../core/profile.js'
import { presentEarnDeploymentPlan } from '../../../core/plan.js'
import {
  zoneRouterModeProfile,
  routerReleaseIntent as modeReleaseIntent,
} from '../../zone-router/profile.js'
import { zoneRouterProfile, routerReleaseIntent } from './profile.js'
import {
  canAdministerZone,
  enableZoneTokens,
  registerZoneGateway,
  zoneAdministrator,
} from './steps.js'
import { requireRouterProvenance } from './provenance.js'
import { oracleFreshness } from './inspection.js'
import { preflightRouterRoute } from './index.js'

vi.mock(import('./provenance.js'), () => ({ requireRouterProvenance: vi.fn() }))

const address = (value: string) => getAddress(`0x${value.padStart(40, '0')}`)
const key = `0x${'3'.repeat(64)}` as const
const account = privateKeyToAccount(key)
const portal = address('8')
const router = address('9')
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'zone-guards',
    chainId: 42431,
    engine: { kind: 'veda', address: address('1') },
    zone: { id: 7, enableEarnShare: true, router: { privateAsset: address('6') } },
    zoneRouter: { zoneId: 7, ops: ['deposit'], earn: { privateAsset: address('6') } },
  },
  { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
)
const options = {
  environment: { ZONE_ADMIN_PRIVATE_KEY: key },
  profile,
  rpcUrl: 'https://rpc.invalid',
  outputs: { zonePortal: portal, earnRouter: router, earnVault: address('e') },
}

function dependencies(overrides: Record<string, unknown> = {}, role = 0) {
  const reads: Record<string, unknown> = {
    zones: { zoneId: 7, portal, sequencers: [address('a')] },
    zoneFactory: zoneFactoryAddress,
    zoneId: 7,
    messenger: zoneMessengerAddress,
    encryptionKeyCount: 1n,
    sequencerCount: 1n,
    sequencerAt: address('b'),
    admin: account.address,
    isGatewayOpen: true,
    isAccessEnforced: true,
    ...overrides,
  }
  const readContract = vi.fn(
    async ({ functionName, args }: { functionName: string; args?: unknown[] }) => {
      if (functionName === 'hasRole') return args?.[1] === role
      if (!(functionName in reads)) throw new ContractFunctionZeroDataError({ functionName })
      const value = reads[functionName]
      if (value instanceof Error) throw value
      return value
    },
  )
  const sendTransactionSync = vi.fn(async () => ({
    status: 'success',
    transactionHash: `0x${'a'.repeat(64)}`,
    logs: [],
  }))
  const client = {
    account,
    chain: { id: 42431 },
    getTransactionCount: async () => 0,
    readContract,
    sendTransactionSync,
  }
  return {
    client,
    sendTransactionSync,
    authorityClient: (() => client) as never,
    fundFromFaucet: vi.fn() as never,
  }
}

describe('Zone admission guards', () => {
  test.each([
    [true, true, 0, false],
    [true, true, 2, true],
    [true, true, 3, false],
    [true, false, 0, true],
    [false, true, 0, false],
    [false, true, 3, true],
    [false, true, 2, false],
  ])(
    'checks both callback and deposit admission (open=%s access=%s role=%s)',
    async (open, access, role, ready) => {
      const runtime = dependencies({ isGatewayOpen: open, isAccessEnforced: access }, role)
      await expect(
        registerZoneGateway.satisfied(runtime.client as never, profile, options.outputs),
      ).resolves.toBe(ready)
    },
  )

  test.each([
    [true, 3, ['setGateway', 'setAllowedAccount']],
    [false, 2, ['setAllowedAccount', 'setGateway']],
  ] as const)('moves the old role atomically (open=%s)', async (open, role, expected) => {
    const runtime = dependencies({ isGatewayOpen: open }, role)
    await registerZoneGateway.execute(options, runtime)
    expect(runtime.sendTransactionSync).toHaveBeenCalledOnce()
    const calls = (
      runtime.sendTransactionSync.mock.calls[0] as unknown as [
        { calls: { to: Address; data: Hex }[] },
      ]
    )[0].calls
    expect(
      calls.map((call) => decodeFunctionData({ abi: zonePortalAbi, data: call.data })),
    ).toEqual([
      { functionName: expected[0], args: [router, false] },
      { functionName: expected[1], args: [router, true] },
    ])
  })

  test('checks the recovered router implementation before any role grant', async () => {
    const runtime = dependencies({ isGatewayOpen: false })
    const error = new Error('noncanonical router')
    vi.mocked(requireRouterProvenance).mockRejectedValueOnce(error)
    await expect(
      registerZoneGateway.execute(
        {
          ...options,
          outputs: {
            ...options.outputs,
            earnVault: address('e'),
          },
        },
        runtime,
      ),
    ).rejects.toBe(error)
    expect(runtime.sendTransactionSync).not.toHaveBeenCalled()
  })

  test('keeps all five Zone administration steps as handoffs until authority is proven', () => {
    const plan = presentEarnDeploymentPlan(profile, options.environment)
    const admin = plan.filter((step) => step.authority === 'zone-administrator')
    expect(admin).toHaveLength(5)
    expect(admin.every((step) => step.execution === 'handoff')).toBe(true)
    expect(enableZoneTokens.probeSigner).toBeTypeOf('function')
    expect(registerZoneGateway.probeSigner).toBeTypeOf('function')
  })

  test.each([
    [{ admin: account.address }, true],
    [{ admin: address('5afe'), getOwners: [account.address], getThreshold: 1n }, true],
    [{ admin: address('5afe'), getOwners: [address('7')], getThreshold: 1n }, false],
    [{ admin: address('5afe'), getOwners: [account.address], getThreshold: 2n }, false],
    [{ admin: address('5afe') }, false],
  ])('proves only the actual administrator %s', async (reads, proven) => {
    await expect(canAdministerZone(options, 7, dependencies(reads))).resolves.toBe(proven)
  })

  test('propagates Safe read transport failures from probing and execution', async () => {
    const error = new Error('RPC unavailable')
    const runtime = dependencies({ admin: address('5afe'), getOwners: error, getThreshold: 1n })
    await expect(canAdministerZone(options, 7, runtime)).rejects.toBe(error)
    await expect(zoneAdministrator(options, runtime)).rejects.toBe(error)
    expect(runtime.sendTransactionSync).not.toHaveBeenCalled()
  })
})

describe('oracleFreshness', () => {
  test.each([
    [101n, 'future'],
    [0n, 'stale'],
    [39n, 'stale'],
    [40n, undefined],
    [99n, undefined],
    [100n, undefined],
  ] as const)('reports timestamp %s honestly', async (updatedAt, reason) => {
    const client = {
      getBlock: async () => ({ number: 7n, timestamp: 100n }),
      readContract: async ({ functionName }: { functionName: string }) =>
        ({ oracle: address('4'), maxOracleAge: 60n, latestPrice: [1n, updatedAt] })[functionName],
    }
    const result = await oracleFreshness(client as never, address('5'))
    if (reason) expect(result).toContain(reason)
    else expect(result).toBeUndefined()
  })

  test('pins pool configuration and the report to the timestamp block when the head advances', async () => {
    const pool = address('5')
    const oracle = address('4')
    const readContract = vi.fn(
      async ({ functionName, blockNumber }: { functionName: string; blockNumber?: bigint }) => {
        // Latest has advanced to block 8, including a changed pool configuration and current report.
        const snapshot = blockNumber === 7n
        return {
          oracle: snapshot ? oracle : address('6'),
          maxOracleAge: snapshot ? 60n : 0n,
          latestPrice: [1n, snapshot ? 100n : 101n],
        }[functionName]
      },
    )
    const client = { getBlock: async () => ({ number: 7n, timestamp: 100n }), readContract }
    await expect(oracleFreshness(client as never, pool)).resolves.toBeUndefined()
    expect(readContract.mock.calls.map(([call]) => call.blockNumber)).toEqual([7n, 7n, 7n])
    expect(readContract).toHaveBeenLastCalledWith(
      expect.objectContaining({ address: oracle, functionName: 'latestPrice', blockNumber: 7n }),
    )
  })

  test('refuses a block without a number rather than silently falling back to latest', async () => {
    const readContract = vi.fn(
      async ({ functionName }: { functionName: string }) =>
        ({
          oracle: address('4'),
          maxOracleAge: 60n,
          latestPrice: [1n, 100n],
        })[functionName],
    )
    await expect(
      oracleFreshness(
        { getBlock: async () => ({ timestamp: 100n }), readContract } as never,
        address('5'),
      ),
    ).resolves.toBe('oracle freshness is unavailable')
    expect(readContract).not.toHaveBeenCalled()
  })

  test('does not retry unavailable snapshot state against a newer head', async () => {
    const readContract = vi.fn(async () => {
      throw new Error('historical state unavailable')
    })
    await expect(
      oracleFreshness(
        { getBlock: async () => ({ number: 7n, timestamp: 100n }), readContract } as never,
        address('5'),
      ),
    ).resolves.toBe('oracle freshness is unavailable')
    expect(readContract).toHaveBeenCalledTimes(2)
    for (const [call] of readContract.mock.calls as unknown as [{ blockNumber?: bigint }][])
      expect(call.blockNumber).toBe(7n)
  })
})

describe('preflightRouterRoute', () => {
  test('rejects a recovered factory-deployed share before any route read', async () => {
    const getCode = vi.fn()
    const readContract = vi.fn()
    await expect(
      preflightRouterRoute({ getCode, readContract } as never, profile, {
        privateAsset: address('6'),
        earnShare: address('6'),
        path: 'zone.router',
      }),
    ).rejects.toThrow("privateAsset cannot be this vault's EarnShare")
    expect(getCode).not.toHaveBeenCalled()
    expect(readContract).not.toHaveBeenCalled()
  })

  test('rejects the existing vault share before pool or deployment writes', async () => {
    const client = {
      getCode: async () => '0x6080',
      readContract: async ({ functionName }: { functionName: string }) => {
        if (functionName === 'earnVault') return address('e')
        if (functionName === 'earnShare') return address('6')
        throw new Error(`Unexpected read ${functionName}`)
      },
    }
    await expect(
      preflightRouterRoute(client as never, profile, {
        privateAsset: address('6'),
        path: 'zone.router',
      }),
    ).rejects.toThrow("privateAsset cannot be this vault's EarnShare")
  })
})

describe('router release intent', () => {
  test('preserves existing release records and changes the intent on a release bump', () => {
    expect(zoneRouterModeProfile.deploymentIntent(profile)).toEqual({
      zoneRouter: profile.zoneRouter,
    })
    expect(zoneRouterModeProfile.components.zoneRouter(profile, 'deployment')).toHaveProperty(
      'contractRelease',
      1,
    )
    expect(zoneRouterProfile.deploymentIntent(profile)).toEqual({ zone: profile.zone })
    expect(zoneRouterProfile.components.zone(profile, 'deployment')).toEqual({
      deployment: 'deployment',
      zone: profile.zone,
    })
    expect(modeReleaseIntent(2)).toEqual({ zoneRouterContractRelease: 2 })
    expect(routerReleaseIntent(2)).toEqual({ routerContractRelease: 2 })
    expect(modeReleaseIntent(3)).not.toEqual(modeReleaseIntent(2))
    expect(routerReleaseIntent(3)).not.toEqual(routerReleaseIntent(2))
  })
})
