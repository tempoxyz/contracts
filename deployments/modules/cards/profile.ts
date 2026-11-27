import { concatHex, getContractAddress, keccak256, type Address, type Hex } from 'viem'

import { hostedEnvironment } from '../../chain/tempo.js'
import { address, exactKeys, isBytes32, literal, object } from '../../core/parse.js'
import { bridgeSpenderFactories } from '../../core/releases.js'
import { required, type ProfileSlice, type SliceProfile } from '../module.js'

/** The card providers the deployment lifecycle deploys programs for. */
export const cardProviders = ['bridge'] as const

/**
 * One card program: its provider contract, at its release address, and a `CardSpender` the released
 * `CardFactory` creates at the address the provider and program ID fix. For Bridge, the program pays
 * through `spenderFactory`'s clone for `spenderId`; the factory is the network's declared one.
 */
export type CardProgramIntent = {
  provider: (typeof cardProviders)[number]
  spenderFactory: Address
  spenderId: Hex
}

/** The profile fields the card slice owns. */
export type CardFields = { cards: CardProgramIntent | null }

type CardProfile = SliceProfile<CardFields>

/**
 * The `cards` slice: one card program, its own intent component: the program's provider contract and
 * its `CardSpender`. The released `ZoneRouterFactory` whose routers may call it and the released
 * `CardFactory` that creates it come from the release registry; the program step records them beside
 * it.
 */
export const cardsProfile = {
  authoredKeys: ['cards'],
  parse: (root: Record<string, unknown>, chainId: number): CardFields => ({
    cards:
      root.cards === undefined
        ? null
        : parseCards(root.cards, 'profile.json.cards', declaredSpenderFactory(chainId)),
  }),
  authored: (profile: CardProfile) =>
    profile.cards
      ? { cards: { provider: profile.cards.provider, spenderId: profile.cards.spenderId } }
      : {},
  // Absent, it adds nothing, so profiles without a program keep their deployment intent hash.
  deploymentIntent: (profile: CardProfile) => (profile.cards ? { cards: profile.cards } : {}),
  components: {
    cards: (profile: CardProfile, deployment: string) =>
      profile.cards ? { deployment, routerFactory: 'release', ...profile.cards } : null,
  },
  externalAddresses: { cardRouterFactory: 'cards', cardFactory: 'cards' },
  periphery: { cardProvider: 'cards', cardProgram: 'cards' },
} as const satisfies ProfileSlice<CardFields>

/** The configured program, or a lifecycle error naming the module when the profile has none. */
export function configuredCards(profile: CardFields) {
  return required(profile.cards ?? undefined, 'Card program module')
}

/** The network's declared Bridge `SpenderFactory`, or `null` where none is declared. */
export function declaredSpenderFactory(chainId: number) {
  const network = hostedEnvironment(chainId)?.id
  return network ? bridgeSpenderFactories[network] : null
}

/**
 * Parses an authored `cards` object. Only Bridge programs deploy here; `spenderFactory` is the
 * network's declared factory, which the profile never repeats.
 */
export function parseCards(
  value: unknown,
  path: string,
  spenderFactory: Address | null,
): CardProgramIntent {
  const cards = object(value, path)
  exactKeys(cards, path, ['provider', 'spenderId'])
  const provider = literal(cards.provider, `${path}.provider`, cardProviders)
  if (!isBytes32(cards.spenderId) || BigInt(cards.spenderId) === 0n)
    throw new Error(`${path}.spenderId must be a nonzero 32-byte hex string`)
  if (!spenderFactory)
    throw new Error(
      `${path} needs a Bridge SpenderFactory, and none is declared for this network (bridgeSpenderFactories in deployments/core/releases.ts)`,
    )
  return {
    provider,
    spenderFactory: address(spenderFactory, `${path}.spenderFactory`),
    spenderId: cards.spenderId.toLowerCase() as Hex,
  }
}

/**
 * The clone Bridge's `createSpender(spenderId)` creates: Solady's ERC1967 beacon proxy with the factory as
 * beacon and deployer. The "TS" handler rejects a program whose clone is any other address.
 */
export function canonicalBridgeClone(spenderFactory: Address, spenderId: Hex) {
  const initCode = concatHex([
    '0x60523d8160223d3973',
    spenderFactory,
    '0x60195155f3363d3d373d3d363d602036600436635c60da',
    '0x1b60e01b36527fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6c',
    '0xb3582b35133d50545afa5036515af43d6000803e604d573d6000fd5b3d6000f3',
  ])
  return getContractAddress({
    opcode: 'CREATE2',
    from: spenderFactory,
    salt: spenderId,
    bytecodeHash: keccak256(initCode),
  })
}
