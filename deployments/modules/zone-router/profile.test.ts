import {
  encodeAbiParameters,
  getAddress,
  keccak256,
  parseAbiParameters,
  zeroAddress,
  zeroHash,
} from 'viem'
import { describe, expect, test } from 'vitest'

import {
  authoredProfile,
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  parseEarnDeploymentProfile as parseProfile,
} from '../../core/profile.js'
import { zoneRouterConstructorArgs, zoneRouterMode, zoneRouterModeHash } from './profile.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as `0x${string}`
const customerId = `0x${'c'.repeat(64)}` as const

const base = {
  version: 1,
  id: 'zone-router-test',
  chainId: 42431,
  engine: { kind: 'erc4626', venue: address('2') },
}

/** The table's presets: Earn, card (Spend), and card with Earn on one Zone. */
const presets = {
  earn: {
    zoneId: 7,
    ops: ['deposit', 'redeem'],
    earn: { privateAsset: address('a'), pool: address('b'), customerId },
  },
  sameAssetEarn: { zoneId: 7, ops: ['deposit', 'redeem'], earn: { privateAsset: address('a') } },
  card: { zoneId: 7, ops: ['spend'], settlers: [address('5e771e'), address('5e772e')] },
  cardAndEarn: {
    zoneId: 7,
    ops: ['deposit', 'redeem', 'spend'],
    earn: { privateAsset: address('a'), pool: address('b'), customerId },
    settlers: [address('5e771e')],
    factory: address('fac'),
  },
}

function parse(zoneRouter?: unknown) {
  return parseProfile(zoneRouter === undefined ? base : { ...base, zoneRouter }, {
    deployer: address('3'),
    factories: { earn: address('4'), erc4626Engine: address('1') },
  })
}

const outputs = { earnVault: address('e'), zoneRouterFactory: address('f') }

describe('zoneRouter profile', () => {
  test.each(Object.entries(presets))(
    '%s parses and round-trips through its authored form',
    (_, preset) => {
      const profile = parse(preset)
      expect(profile.zoneRouter).toEqual(preset)
      const authored = JSON.parse(JSON.stringify(authoredProfile(profile))) as unknown
      expect(
        parseProfile(authored, { deployer: profile.deployer, factories: profile.factories }),
      ).toEqual(profile)
    },
  )

  test.each([
    [
      'an unknown key',
      { ...presets.card, router: address('1') },
      'zoneRouter.router is not supported',
    ],
    [
      'a missing Zone',
      { ops: ['spend'], settlers: [address('5')] },
      'zoneRouter.zoneId is required',
    ],
    ['Zone 0', { ...presets.card, zoneId: 0 }, 'zoneRouter.zoneId must be'],
    [
      'a Zone beyond uint32',
      { ...presets.card, zoneId: 2 ** 32 },
      'zoneRouter.zoneId must fit uint32',
    ],
    ['no ops', { ...presets.card, ops: [] }, 'zoneRouter.ops must enable at least one op'],
    [
      'an unknown op',
      { ...presets.card, ops: ['send'] },
      'zoneRouter.ops[0] must be one of deposit, redeem, spend',
    ],
    [
      'a repeated op',
      { ...presets.card, ops: ['spend', 'spend'] },
      'Duplicate profile.json.zoneRouter.ops op: spend',
    ],
    [
      'ops out of order',
      { ...presets.cardAndEarn, ops: ['spend', 'deposit', 'redeem'] },
      'must be listed in deposit, redeem, spend order',
    ],
    [
      'Deposit without an Earn binding',
      { zoneId: 7, ops: ['deposit'] },
      'zoneRouter.earn is required with deposit or redeem',
    ],
    [
      'Redeem without an Earn binding',
      { zoneId: 7, ops: ['redeem'] },
      'zoneRouter.earn is required with deposit or redeem',
    ],
    [
      'an Earn binding without Earn ops',
      { ...presets.card, earn: presets.earn.earn },
      'zoneRouter.earn is not supported without deposit or redeem',
    ],
    [
      'Spend without settlers',
      { zoneId: 7, ops: ['spend'] },
      'zoneRouter.settlers is required with spend',
    ],
    [
      'settlers without Spend',
      { ...presets.earn, settlers: [address('5')] },
      'zoneRouter.settlers is not supported without spend',
    ],
    [
      'an empty settler list',
      { ...presets.card, settlers: [] },
      'zoneRouter.settlers must list at least one settler',
    ],
    [
      'a zero settler',
      { ...presets.card, settlers: [zeroAddress] },
      'zoneRouter.settlers[0] must be a nonzero address',
    ],
    [
      'a repeated settler',
      { ...presets.card, settlers: [address('5'), address('5')] },
      'Duplicate profile.json.zoneRouter.settlers settler',
    ],
    [
      'a zero private asset',
      { ...presets.earn, earn: { privateAsset: zeroAddress } },
      'zoneRouter.earn.privateAsset must be a nonzero address',
    ],
    [
      'a pool without a customer ID',
      { ...presets.earn, earn: { privateAsset: address('a'), pool: address('b') } },
      'must be set or omitted together',
    ],
    [
      'a customer ID without a pool',
      { ...presets.earn, earn: { privateAsset: address('a'), customerId } },
      'must be set or omitted together',
    ],
    [
      'a zero customer ID',
      { ...presets.earn, earn: { ...presets.earn.earn, customerId: zeroHash } },
      'zoneRouter.earn.customerId must be a nonzero 32-byte hex string',
    ],
    [
      'a zero pool',
      { ...presets.earn, earn: { ...presets.earn.earn, pool: zeroAddress } },
      'zoneRouter.earn.pool must be a nonzero address',
    ],
    [
      'an unknown Earn key',
      { ...presets.earn, earn: { ...presets.earn.earn, earnVault: address('e') } },
      'zoneRouter.earn.earnVault is not supported',
    ],
    [
      'a zero factory',
      { ...presets.card, factory: zeroAddress },
      'zoneRouter.factory must be a nonzero address',
    ],
  ])('rejects %s', (_, zoneRouter, message) => {
    expect(() => parse(zoneRouter)).toThrow(message)
  })

  test('encodes the mode exactly as ZoneRouter.Mode, salted by its hash', () => {
    const profile = parse(presets.cardAndEarn)
    const mode = zoneRouterMode(profile, outputs)
    expect(mode).toEqual({
      zoneId: 7,
      enabledOps: 7,
      earnVault: outputs.earnVault,
      privateAsset: address('a'),
      pool: address('b'),
      customerId,
      settlers: [address('5e771e')],
    })
    const encoded = encodeAbiParameters(
      parseAbiParameters(
        '(uint32 zoneId, uint8 enabledOps, address earnVault, address privateAsset, address pool, bytes32 customerId, address[] settlers)',
      ),
      [mode],
    )
    expect(zoneRouterConstructorArgs(mode)).toBe(encoded)
    expect(zoneRouterModeHash(mode)).toBe(keccak256(encoded))
  })

  test('binds nothing but settlers in a Spend mode, and no settlers in an Earn mode', () => {
    expect(zoneRouterMode(parse(presets.card), outputs)).toEqual({
      zoneId: 7,
      enabledOps: 4,
      earnVault: zeroAddress,
      privateAsset: zeroAddress,
      pool: zeroAddress,
      customerId: zeroHash,
      settlers: presets.card.settlers,
    })
    expect(zoneRouterMode(parse(presets.sameAssetEarn), outputs)).toMatchObject({
      enabledOps: 3,
      earnVault: outputs.earnVault,
      pool: zeroAddress,
      customerId: zeroHash,
      settlers: [],
    })
  })

  test('keeps the intent of profiles without a router and isolates the factory from the mode', () => {
    const without = componentDeploymentIntentHashes(parse())
    expect(without).toMatchObject({ zoneRouterFactory: null, zoneRouter: null })

    const card = parse(presets.card)
    const moreSettlers = parse({ ...presets.card, settlers: [address('5e771e')] })
    const cardHashes = componentDeploymentIntentHashes(card)
    const changed = componentDeploymentIntentHashes(moreSettlers)
    expect(cardHashes.zoneRouterFactory).toEqual(expect.any(String))
    expect(changed.zoneRouterFactory).toBe(cardHashes.zoneRouterFactory)
    expect(changed.zoneRouter).not.toBe(cardHashes.zoneRouter)
    expect(changed.core).toBe(without.core)
    expect(deploymentIntentHash(card)).not.toBe(deploymentIntentHash(moreSettlers))

    // A named factory is the profile's, not a component the lifecycle deploys.
    const named = componentDeploymentIntentHashes(
      parse({ ...presets.card, factory: address('fac') }),
    )
    expect(named.zoneRouterFactory).toBeNull()
    expect(named.zoneRouter).not.toBe(cardHashes.zoneRouter)
  })
})
