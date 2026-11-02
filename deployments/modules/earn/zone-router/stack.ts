import type { Address } from 'viem'

import type { ZoneIdentity } from '../../../chain/zone.js'
import type { ModeConfiguration } from '../../../core/stack.js'

/** The private mode: its availability plus the one private asset that enters and leaves the Zone. */
type PrivateModeConfiguration = ModeConfiguration & { privateAsset: Address }

/** A stack network's Zone: its canonical identity plus how to reach it. */
export type ZoneConfiguration = ZoneIdentity & {
  name: string
  rpcUrl: string
}

/** The router's optional stack fields: the network's Zone, the router, and the private mode. */
export type ZoneRouterStack = {
  network: { zone: ZoneConfiguration }
  contracts: { earnRouter: Address }
  modes: { private: PrivateModeConfiguration }
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
