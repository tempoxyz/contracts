import { getAbiItem, type Address } from 'viem'
import { describe, expect, test } from 'vitest'

import { earnFactoryAbi, erc4626EngineFactoryAbi, zoneRouterFactoryAbi } from '../abis/index.js'
import { parseEarnDeploymentProfile } from '../core/profile.js'
import { deployCore } from './earn/core/steps.js'
import { deployEngine } from './earn/engines/steps.js'
import { deploymentSteps } from './index.js'
import { deployZoneRouter } from './zone-router/steps.js'

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

describe('creationEvent', () => {
  test('identifies the EarnVault in the configured Earn factory creation event', () => {
    expect(deployCore.creationEvent!(profile, {})).toEqual({
      address: factories.earn,
      event: getAbiItem({ abi: earnFactoryAbi, name: 'EarnStackDeployed' }),
      argument: 'earnVault',
    })
  })

  test('identifies the engine in its kind-specific factory creation event', () => {
    expect(deployEngine.creationEvent!(profile, {})).toEqual({
      address: factories.erc4626Engine,
      event: getAbiItem({ abi: erc4626EngineFactoryAbi, name: 'ERC4626EngineDeployed' }),
      argument: 'engine',
    })
  })

  test('does not claim factory evidence for an existing engine', () => {
    const existing = { ...profile, engine: { kind: 'erc4626' as const, address: address('6') } }
    expect(deployEngine.enabled(existing)).toBe(false)
    expect(() => deployEngine.creationEvent!(existing, {})).toThrow('reuses an existing engine')
  })

  test('uses the deployed Zone router factory output when the profile names none', () => {
    expect(deployZoneRouter.creationEvent!(profile, { zoneRouterFactory: address('7') })).toEqual({
      address: address('7'),
      event: getAbiItem({ abi: zoneRouterFactoryAbi, name: 'RouterDeployed' }),
      argument: 'router',
    })
    expect(() => deployZoneRouter.creationEvent!(profile, {})).toThrow(
      'deployment output zoneRouterFactory is required',
    )
  })

  test('prefers the profile Zone router factory over a different output', () => {
    const named = { ...profile, zoneRouter: { ...profile.zoneRouter!, factory: address('8') } }
    expect(deployZoneRouter.creationEvent!(named, { zoneRouterFactory: address('7') })).toEqual({
      address: address('8'),
      event: getAbiItem({ abi: zoneRouterFactoryAbi, name: 'RouterDeployed' }),
      argument: 'router',
      source: { project: 'zone-router', contract: 'src/ZoneRouterFactory.sol:ZoneRouterFactory' },
    })
  })

  test('keeps direct deployments without factory creation metadata', () => {
    const direct = deploymentSteps.filter(
      (step) =>
        step.execution === 'foundry' &&
        step.id !== 'deploy-core' &&
        step.id !== 'deploy-engine' &&
        step.id !== 'deploy-zone-router',
    )
    expect(direct.length).toBeGreaterThan(0)
    for (const step of direct) {
      expect(step).not.toHaveProperty('creationEvent')
    }
  })
})
