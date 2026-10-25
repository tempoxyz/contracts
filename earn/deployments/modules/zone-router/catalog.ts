import type { Address } from 'viem'

import type { ZoneIdentity } from '../../chain/zone.js'
import type { ModeConfiguration } from '../../core/stack.js'
import {
  array,
  checksummedAddress,
  exactKeys,
  nonemptyString,
  object,
  parseMode,
  positiveInteger,
  unique,
  url,
} from '../../core/parse.js'
import type { ProfileSlice } from '../module.js'

/** The private mode: its availability plus the one private asset that enters and leaves the Zone. */
type PrivateModeConfiguration = ModeConfiguration & { privateAsset: Address }

function parsePrivateMode(value: unknown, path: string): PrivateModeConfiguration {
  const mode = object(value, path)
  return {
    ...parseMode(value, path, ['privateAsset']),
    privateAsset: checksummedAddress(mode.privateAsset, `${path}.privateAsset`),
  }
}

/** A stack network's Zone: its canonical identity plus how to reach it. */
export type ZoneConfiguration = ZoneIdentity & {
  name: string
  rpcUrl: string
}

/** Parses a catalog network's Zone: its canonical identity plus a credential-free RPC URL. */
function parseZoneConfiguration(value: unknown, path: string): ZoneConfiguration {
  const zone = object(value, path)
  exactKeys(zone, path, ['name', 'id', 'chainId', 'rpcUrl', 'portal', 'messenger', 'sequencers'])
  const sequencers = array(zone.sequencers, `${path}.sequencers`).map((sequencer, index) =>
    checksummedAddress(sequencer, `${path}.sequencers[${index}]`),
  )
  if (sequencers.length === 0) throw new Error(`${path}.sequencers must not be empty`)
  unique(sequencers, `${path} sequencer`)
  return {
    name: nonemptyString(zone.name, `${path}.name`),
    id: positiveInteger(zone.id, `${path}.id`),
    chainId: positiveInteger(zone.chainId, `${path}.chainId`),
    rpcUrl: url(zone.rpcUrl, `${path}.rpcUrl`),
    portal: checksummedAddress(zone.portal, `${path}.portal`),
    messenger: checksummedAddress(zone.messenger, `${path}.messenger`),
    sequencers,
  }
}

/**
 * A stack's router fields: the network's Zone and, with a router, the router and the private mode
 * whose one private asset both enters and leaves the Zone.
 */
export function zoneRouterStackFields(
  zone: ZoneConfiguration,
  router?: { earnRouter: Address; privateAsset: Address },
) {
  return {
    network: { zone },
    contracts: router ? { earnRouter: router.earnRouter } : {},
    modes: router
      ? {
          private: {
            availability: 'available' as const,
            privateAsset: router.privateAsset,
          },
        }
      : {},
  }
}

/**
 * The router's fields of a published stack: the network's Zone, the router, and the private mode.
 * A privately routed stack needs all three.
 */
export const zoneRouterStack = {
  network: { zone: parseZoneConfiguration },
  contracts: { earnRouter: (value: unknown, path: string) => checksummedAddress(value, path) },
  modes: { private: parsePrivateMode },
  validate(stack, network, fail) {
    const { capabilities, contracts, modes } = stack
    if (capabilities.privateRouting && !modes.private) {
      fail('enables privateRouting without a private mode')
    }
    if (capabilities.privateRouting && !contracts.earnRouter) {
      fail('enables privateRouting without an EarnRouter')
    }
    if (capabilities.privateRouting && !network.zone) {
      fail('enables privateRouting without a network Zone target')
    }
    if (capabilities.routerSwaps && !capabilities.privateRouting) {
      fail('enables routerSwaps without privateRouting')
    }
    if (
      (modes.private as PrivateModeConfiguration | undefined)?.availability === 'available' &&
      !capabilities.privateRouting
    ) {
      fail('has available private mode without privateRouting')
    }
  },
} as const satisfies NonNullable<ProfileSlice['stack']>
