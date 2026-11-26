import type { Address, Hex } from 'viem'

import { hostedEnvironment, type HostedEnvironmentId } from '../../chain/tempo.js'
import { address, exactKeys, isBytes32, literal, object } from '../../core/parse.js'
import { required, type ProfileSlice, type SliceProfile } from '../module.js'

/**
 * Bridge's `SpenderFactory` on each hosted network: the one declaration of it, read by every profile's
 * card program on that network and by the card release, which deploys its "TS" handler. `null` until
 * a network has one; a profile there cannot declare a Bridge program.
 */
export const bridgeSpenderFactories: Readonly<Record<HostedEnvironmentId, Address | null>> = {
  moderato: null,
  mainnet: null,
}

/** The card providers the deployment lifecycle deploys programs for. */
export const cardProviders = ['bridge'] as const

/**
 * One card program: a `CardSpender` and its provider contract, which the release `CardFactory`
 * creates at the address the provider and program ID fix. For Bridge, the program pays through
 * `spenderFactory`'s clone for `spenderId`; the factory is the network's declared one.
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
 * The `cards` slice: one card program, its own intent component. The release `ZoneRouterFactory`
 * whose routers may call it, the release `CardFactory` and the program's provider contract are
 * deterministic release contracts the program step records beside it, identified by their address.
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
  externalAddresses: { cardRouterFactory: 'cards', cardFactory: 'cards', cardProvider: 'cards' },
  periphery: { cardProgram: 'cards' },
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
      `${path} needs a Bridge SpenderFactory, and none is declared for this network (bridgeSpenderFactories in deployments/modules/cards/profile.ts)`,
    )
  return {
    provider,
    spenderFactory: address(spenderFactory, `${path}.spenderFactory`),
    spenderId: cards.spenderId.toLowerCase() as Hex,
  }
}
