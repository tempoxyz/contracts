import { getAbiItem, type Address } from 'viem'
import { describe, expect, test, vi } from 'vitest'

import { earnFactoryAbi, erc4626EngineFactoryAbi, zoneRouterFactoryAbi } from '../abis/index.js'
import { parseEarnDeploymentProfile } from '../core/profile.js'
import * as Releases from '../core/releases.js'
import { deployCore } from './earn/core/steps.js'
import { deployEngine } from './earn/engines/steps.js'
import { deploymentSteps } from './index.js'
import { deployZoneRouter } from './zone-router/steps.js'

// The registry has no ZoneRouterFactory release yet; each test names the one it releases.
const released = vi.hoisted(() => ({ zoneRouterFactory: undefined as `0x${string}` | undefined }))
vi.mock(import('../core/releases.js'), async (original) => {
  const actual = await original()
  return {
    ...actual,
    releasedContract: vi.fn(
      (chainId: number, key: Parameters<typeof actual.releasedContract>[1]) => {
        // Mainnet releases only what the test sets, whatever the committed registry holds.
        if (chainId !== 4217) return actual.releasedContract(chainId, key)
        const address = key === 'zoneRouterFactory' ? released.zoneRouterFactory : undefined
        if (!address) throw actual.missingRelease(chainId, key)
        return address
      },
    ),
  }
})

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}` as Address
const factories = { earn: address('1'), erc4626Engine: address('2') }

const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'creation-event-test',
    chainId: 4217,
    engine: { kind: 'erc4626', venue: address('3') },
    zoneRouter: { zoneId: 7, ops: ['spend'], spenders: [address('4')] },
  },
  { deployer: address('5'), factories },
)

/** A router without spenders, which alone may deploy through the registry's released factory. */
const earnRouterProfile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'creation-event-earn-router-test',
    chainId: 4217,
    engine: { kind: 'erc4626', venue: address('3') },
    zoneRouter: { zoneId: 7, ops: ['deposit'], earn: { privateAsset: address('9') } },
  },
  { deployer: address('5'), factories },
)

describe('creationEvent', () => {
  test('identifies the EarnVault in the configured Earn factory creation event', () => {
    expect(deployCore.creationEvent!(profile, {})).toEqual({
      address: factories.earn,
      event: getAbiItem({ abi: earnFactoryAbi, name: 'EarnStackDeployed' }),
      argument: 'earnVault',
      output: 'earnVault',
    })
  })

  test('identifies the engine in its kind-specific factory creation event', () => {
    expect(deployEngine.creationEvent!(profile, {})).toEqual({
      address: factories.erc4626Engine,
      event: getAbiItem({ abi: erc4626EngineFactoryAbi, name: 'ERC4626EngineDeployed' }),
      argument: 'engine',
      output: 'engine',
    })
  })

  test('does not claim factory evidence for an existing engine', () => {
    const existing = { ...profile, engine: { kind: 'erc4626' as const, address: address('6') } }
    expect(deployEngine.enabled(existing)).toBe(false)
    expect(() => deployEngine.creationEvent!(existing, {})).toThrow('reuses an existing engine')
  })

  test('identifies the router in the released Zone router factory creation event', () => {
    released.zoneRouterFactory = address('8')
    try {
      expect(deployZoneRouter.creationEvent!(earnRouterProfile, {})).toEqual({
        address: address('8'),
        event: getAbiItem({ abi: zoneRouterFactoryAbi, name: 'RouterDeployed' }),
        argument: 'router',
        output: 'zoneRouter',
        // The released factory is admitted as an existing source-verified contract.
        source: { contract: 'src/zone/ZoneRouterFactory.sol:ZoneRouterFactory' },
      })
      expect(Releases.releasedContract).toHaveBeenCalledWith(4217, 'zoneRouterFactory')
    } finally {
      released.zoneRouterFactory = undefined
    }
  })

  test('keeps a recorded Zone router factory output over the registry', () => {
    released.zoneRouterFactory = address('8')
    try {
      expect(deployZoneRouter.creationEvent!(profile, { zoneRouterFactory: address('7') })).toEqual(
        {
          address: address('7'),
          event: getAbiItem({ abi: zoneRouterFactoryAbi, name: 'RouterDeployed' }),
          argument: 'router',
          output: 'zoneRouter',
          source: { contract: 'src/zone/ZoneRouterFactory.sol:ZoneRouterFactory' },
        },
      )
    } finally {
      released.zoneRouterFactory = undefined
    }
  })

  test('refuses a Zone router without a released or recorded factory', () => {
    expect(() => deployZoneRouter.creationEvent!(earnRouterProfile, {})).toThrow(
      'No zoneRouterFactory release on mainnet; run pnpm release mainnet and record its registry entry first',
    )
  })

  test('refuses a Spend router whose spenders bind no recorded factory, even with a release', () => {
    released.zoneRouterFactory = address('8')
    try {
      expect(() => deployZoneRouter.creationEvent!(profile, {})).toThrow(
        'The ZoneRouterFactory zoneRouter.spenders bind is unresolved; rerun once every spender answers ROUTER_FACTORY',
      )
    } finally {
      released.zoneRouterFactory = undefined
    }
  })

  test('keeps direct deployments without factory creation metadata', () => {
    const direct = deploymentSteps.filter(
      (step) =>
        step.execution === 'foundry' &&
        step.id !== 'deploy-core' &&
        step.id !== 'deploy-engine' &&
        step.id !== 'deploy-zone-router' &&
        step.id !== 'deploy-card-program',
    )
    expect(direct.length).toBeGreaterThan(0)
    for (const step of direct) {
      expect(step).not.toHaveProperty('creationEvent')
    }
  })
})
