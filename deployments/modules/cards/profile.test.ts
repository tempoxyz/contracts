import { getAddress, type Address, type Hex } from 'viem'
import { describe, expect, test } from 'vitest'

import { deploymentAddressKeysForProfile } from '../../core/record.js'
import {
  authoredProfile,
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  parseEarnDeploymentProfile,
} from '../../core/profile.js'
import { cardsProfile, declaredSpenderFactory, parseCards } from './profile.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as Address
const spenderId = `0x${'5'.repeat(64)}` as Hex
const factory = address('bf')
const base = {
  version: 1,
  id: 'cards-test',
  chainId: 42431,
  engine: { kind: 'erc4626', venue: address('2') },
}
const options = {
  deployer: address('3'),
  factories: { earn: address('4'), erc4626Engine: address('1') },
}
const profile = parseEarnDeploymentProfile(base, options)
const withCards = (
  cards = { provider: 'bridge' as const, spenderFactory: factory, spenderId },
) => ({
  ...profile,
  cards,
})

describe('cards profile', () => {
  test("parses a Bridge program, taking the network's declared SpenderFactory", () => {
    expect(
      parseCards(
        { provider: 'bridge', spenderId: spenderId.toUpperCase().replace('0X', '0x') },
        'cards',
        factory,
      ),
    ).toEqual({ provider: 'bridge', spenderFactory: factory, spenderId })
  })

  test.each([
    [
      'an unknown key',
      { provider: 'bridge', spenderId, routerFactory: address('9') },
      'cards.routerFactory is not supported',
    ],
    [
      'a repeated SpenderFactory',
      { provider: 'bridge', spenderId, spenderFactory: factory },
      'cards.spenderFactory is not supported',
    ],
    ['a missing provider', { spenderId }, 'cards.provider is required'],
    ['a missing program ID', { provider: 'bridge' }, 'cards.spenderId is required'],
    ['Rain', { provider: 'rain', spenderId }, 'cards.provider must be one of bridge'],
    [
      'a zero program ID',
      { provider: 'bridge', spenderId: `0x${'0'.repeat(64)}` },
      'cards.spenderId must be a nonzero 32-byte hex string',
    ],
    [
      'a short program ID',
      { provider: 'bridge', spenderId: '0x1234' },
      'cards.spenderId must be a nonzero 32-byte hex string',
    ],
    ['an array', [], 'cards must be an object'],
  ])('refuses %s', (_, value, message) => {
    expect(() => parseCards(value, 'cards', factory)).toThrow(message)
  })

  test('refuses a program on a network that declares no SpenderFactory', () => {
    expect(declaredSpenderFactory(42431)).toBeNull()
    expect(declaredSpenderFactory(1337)).toBeNull()
    expect(() =>
      parseEarnDeploymentProfile({ ...base, cards: { provider: 'bridge', spenderId } }, options),
    ).toThrow(
      'profile.json.cards needs a Bridge SpenderFactory, and none is declared for this network',
    )
  })

  test('authors only the provider and program ID', () => {
    expect(authoredProfile(withCards())).toMatchObject({ cards: { provider: 'bridge', spenderId } })
    expect((authoredProfile(withCards()) as { cards: object }).cards).not.toHaveProperty(
      'spenderFactory',
    )
    expect(authoredProfile(profile)).not.toHaveProperty('cards')
  })

  test('adds nothing to the hashes of a profile without a program', () => {
    expect(cardsProfile.deploymentIntent(profile)).toEqual({})
    expect(componentDeploymentIntentHashes(profile).cards).toBeNull()
    expect(deploymentAddressKeysForProfile(profile)).not.toContain('cardProgram')
  })

  test('a program changes only its own component', () => {
    const before = componentDeploymentIntentHashes(profile)
    const after = componentDeploymentIntentHashes(withCards())
    const changed = (left: object, right: object) =>
      Object.keys(left).filter(
        (key) => left[key as keyof typeof left] !== right[key as keyof typeof right],
      )
    expect(changed(before, after)).toEqual(['cards'])
    expect(deploymentIntentHash(withCards())).not.toBe(deploymentIntentHash(profile))
    const otherProgram = componentDeploymentIntentHashes(
      withCards({ provider: 'bridge', spenderFactory: factory, spenderId: `0x${'6'.repeat(64)}` }),
    )
    expect(changed(after, otherProgram)).toEqual(['cards'])
    const otherFactory = componentDeploymentIntentHashes(
      withCards({ provider: 'bridge', spenderFactory: address('bfbf'), spenderId }),
    )
    expect(changed(after, otherFactory)).toEqual(['cards'])
    expect(deploymentAddressKeysForProfile(withCards())).toEqual(
      expect.arrayContaining(['cardRouterFactory', 'cardFactory', 'cardProvider', 'cardProgram']),
    )
  })
})
