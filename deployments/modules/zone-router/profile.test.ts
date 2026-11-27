import {
  encodeAbiParameters,
  getAddress,
  keccak256,
  parseAbiParameters,
  zeroAddress,
  zeroHash,
} from 'viem'
import { describe, expect, test, vi } from 'vitest'

import {
  authoredProfile,
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  parseEarnDeploymentProfile as parseProfile,
} from '../../core/profile.js'
import {
  zoneRouterConstructorArgs,
  zoneRouterFactory,
  zoneRouterMode,
  zoneRouterModeHash,
} from './profile.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as `0x${string}`

/** The ZoneRouterFactory the mocked registry records on moderato; mainnet keeps the real (empty) entry. */
const releasedFactory = vi.hoisted(() => '0x0000000000000000000000000000000000000fac' as const)

vi.mock('../../core/releases.js', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../core/releases.js')>()
  return {
    ...actual,
    releasedContract: vi.fn(
      (chainId: number, key: Parameters<typeof actual.releasedContract>[1]) =>
        chainId === 42431 && key === 'zoneRouterFactory'
          ? releasedFactory
          : actual.releasedContract(chainId, key),
    ),
  }
})
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
  card: { zoneId: 7, ops: ['spend'], spenders: [address('5e771e'), address('5e772e')] },
  cardAndEarn: {
    zoneId: 7,
    ops: ['deposit', 'redeem', 'spend'],
    earn: { privateAsset: address('a'), pool: address('b'), customerId },
    spenders: [address('5e771e')],
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
      { ops: ['spend'], spenders: [address('5')] },
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
      'Spend without spenders',
      { zoneId: 7, ops: ['spend'] },
      'zoneRouter.spenders is required with spend',
    ],
    [
      'spenders without Spend',
      { ...presets.earn, spenders: [address('5')] },
      'zoneRouter.spenders is not supported without spend',
    ],
    [
      'an empty spender list',
      { ...presets.card, spenders: [] },
      'zoneRouter.spenders must list at least one spender',
    ],
    [
      'a zero spender',
      { ...presets.card, spenders: [zeroAddress] },
      'zoneRouter.spenders[0] must be a nonzero address',
    ],
    [
      'a repeated spender',
      { ...presets.card, spenders: [address('5'), address('5')] },
      'Duplicate profile.json.zoneRouter.spenders spender',
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
      'a factory, which only the release deploys',
      { ...presets.card, factory: address('fac') },
      'zoneRouter.factory is not supported',
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
      spenders: [address('5e771e')],
    })
    const encoded = encodeAbiParameters(
      parseAbiParameters(
        '(uint32 zoneId, uint8 enabledOps, address earnVault, address privateAsset, address pool, bytes32 customerId, address[] spenders)',
      ),
      [mode],
    )
    expect(zoneRouterConstructorArgs(mode)).toBe(encoded)
    expect(zoneRouterModeHash(mode)).toBe(keccak256(encoded))
  })

  test('binds nothing but spenders in a Spend mode, and no spenders in an Earn mode', () => {
    expect(zoneRouterMode(parse(presets.card), outputs)).toEqual({
      zoneId: 7,
      enabledOps: 4,
      earnVault: zeroAddress,
      privateAsset: zeroAddress,
      pool: zeroAddress,
      customerId: zeroHash,
      spenders: presets.card.spenders,
    })
    expect(zoneRouterMode(parse(presets.sameAssetEarn), outputs)).toMatchObject({
      enabledOps: 3,
      earnVault: outputs.earnVault,
      pool: zeroAddress,
      customerId: zeroHash,
      spenders: [],
    })
  })

  test('keeps the intent of profiles without a router and hashes no factory component', () => {
    const without = componentDeploymentIntentHashes(parse())
    expect(without).toMatchObject({ zoneRouter: null })
    expect(without).not.toHaveProperty('zoneRouterFactory')

    const card = parse(presets.card)
    const moreSpenders = parse({ ...presets.card, spenders: [address('5e771e')] })
    const cardHashes = componentDeploymentIntentHashes(card)
    const changed = componentDeploymentIntentHashes(moreSpenders)
    expect(cardHashes).not.toHaveProperty('zoneRouterFactory')
    expect(cardHashes.zoneRouter).toEqual(expect.any(String))
    expect(changed.zoneRouter).not.toBe(cardHashes.zoneRouter)
    expect(changed.core).toBe(without.core)
    expect(deploymentIntentHash(card)).not.toBe(deploymentIntentHash(moreSpenders))
  })

  test('deploys through the recorded factory, else the released one', () => {
    const earn = parse(presets.sameAssetEarn)
    expect(zoneRouterFactory(earn, outputs)).toBe(outputs.zoneRouterFactory)
    expect(zoneRouterFactory(earn, { earnVault: outputs.earnVault })).toBe(releasedFactory)
  })

  test('deploys a Spend router only through the factory its spenders bind', () => {
    const card = parse(presets.card)
    expect(zoneRouterFactory(card, outputs)).toBe(outputs.zoneRouterFactory)
    expect(() => zoneRouterFactory(card, { earnVault: outputs.earnVault })).toThrow(
      'The ZoneRouterFactory zoneRouter.spenders bind is unresolved; rerun once every spender answers ROUTER_FACTORY',
    )
  })

  test('fails naming the release when the registry has no ZoneRouterFactory', () => {
    const mainnet = parseProfile(
      { ...base, chainId: 4217, zoneRouter: presets.sameAssetEarn },
      { deployer: address('3'), factories: { earn: address('4'), erc4626Engine: address('1') } },
    )
    expect(() => zoneRouterFactory(mainnet, {})).toThrow(
      'No zoneRouterFactory release on mainnet; run pnpm release mainnet and record its registry entry first',
    )
  })
})
