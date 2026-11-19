import { getAddress, type Address } from 'viem'

import { zoneChainId } from '../../../chain/tempo.js'
import { zoneMessengerAddress, type ZoneIdentity } from '../../../chain/zone.js'
import { address, exactKeys, object, positiveInteger } from '../../../core/parse.js'
import {
  type ProfileSlice,
  type SliceProfile,
  type TargetSlice,
} from '../../../../deployments/modules/module.js'
import type { ZoneRouterFields } from '../../zone-router/profile.js'
import type { ZoneStack } from './stack.js'

/** The authored Zone a deployment targets; its Portal enables the profile's EarnShare. */
export type ZoneIntent = {
  id: number
  chainId: number
  enableEarnShare: true
}

/** The profile fields the Zone slice owns. */
export type ZoneFields = { zone: ZoneIntent | null }

/** The Zone identity a deployment record targets; sequencers are live state, not identity. */
export type ZoneTarget = Omit<ZoneIdentity, 'sequencers'>

type ZoneProfile = SliceProfile<ZoneFields>

/** Recorded Zone identity addresses, discovered from the canonical Factory rather than deployed. */
export const zoneIdentityAddresses = {
  zonePortal: 'zone',
  zoneMessenger: 'zone',
  zoneOutbox: 'zone',
} as const

/** The record target's `zone`: the configured Zone and its discovered Portal and Messenger. */
const zoneTarget: TargetSlice<'zone', ZoneTarget, ZoneFields> = {
  key: 'zone',
  component: 'zone',
  discover(profile, outputs) {
    const zone = configuredZone(profile)
    if (!zone) return undefined
    const portal = outputs.zonePortal
    const messenger = outputs.zoneMessenger
    if (!portal || !messenger) throw new Error('Discovered Zone identity is incomplete')
    return {
      id: zone.id,
      chainId: zone.chainId,
      portal: getAddress(portal),
      messenger: getAddress(messenger),
    }
  },
  parse(value, path, profile) {
    const zone = profile && configuredZone(profile)
    if (value === undefined) {
      if (zone) throw new Error(`${path} is required`)
      return undefined
    }
    if (profile && !zone) throw new Error(`${path} is not supported without a profile Zone`)
    const target = object(value, path)
    exactKeys(target, path, ['id', 'chainId', 'portal', 'messenger'])
    const parsed = {
      id: positiveInteger(target.id, `${path}.id`),
      chainId: positiveInteger(target.chainId, `${path}.chainId`),
      portal: address(target.portal, `${path}.portal`),
      messenger: address(target.messenger, `${path}.messenger`),
    }
    if (
      zone &&
      (parsed.id !== zone.id ||
        parsed.chainId !== zone.chainId ||
        parsed.messenger !== zoneMessengerAddress)
    )
      throw new Error(`${path} does not match the profile's Zone`)
    return parsed
  },
  same(left, right) {
    return (
      (!left && !right) ||
      (left !== undefined &&
        right !== undefined &&
        left.id === right.id &&
        left.chainId === right.chainId &&
        getAddress(left.portal) === getAddress(right.portal) &&
        getAddress(left.messenger) === getAddress(right.messenger))
    )
  },
  checkAddresses(addresses, value, path) {
    if (!value) return
    if (addresses.zonePortal !== getAddress(value.portal))
      throw new Error(`${path}.addresses.zonePortal does not match target.zone.portal`)
    if (addresses.zoneMessenger !== getAddress(value.messenger))
      throw new Error(`${path}.addresses.zoneMessenger does not match target.zone.messenger`)
  },
}

/**
 * The `zone` slice: the authored Zone, the `zone` intent component and record target, the Zone
 * identity it discovers, and the network's Zone stack field.
 */
export const zoneProfile = {
  authoredKeys: ['zone'],
  parse: (root: Record<string, unknown>, chainId: number): ZoneFields => ({
    zone:
      root.zone === undefined
        ? null
        : parseZone(object(root.zone, 'profile.json.zone'), chainId, 'profile.json.zone'),
  }),
  authored: (profile: ZoneProfile) => {
    if (!profile.zone) return {}
    // The Zone chain ID derives from the parent chain and Zone ID; it is never authored.
    const { chainId: _chainId, ...zone } = profile.zone
    return { zone }
  },
  deploymentIntent: (profile: ZoneProfile) =>
    profile.zone ? { zone: profile.zone } : { zone: null },
  components: {
    zone: (profile: ZoneProfile, deployment: string) =>
      profile.zone ? { deployment, zone: profile.zone } : null,
  },
  externalAddresses: zoneIdentityAddresses,
  // Protocol precompiles are authenticated functionally and intentionally have no runtime bytecode.
  codeless: (key: string, value: Address) =>
    key === 'zoneOutbox' || (key === 'zoneMessenger' && getAddress(value) === zoneMessengerAddress),
  target: zoneTarget,
  capabilities: {
    privateRouting: earnModeOnZone,
    routerSwaps: earnModeOnZone,
  },
  // Type-only: declares the stack fields `zoneStackFields` fills.
  stack: {} as ZoneStack,
} as const satisfies ProfileSlice<ZoneFields>

/** The configured Zone, or `undefined` when the profile targets none. */
export function configuredZone(profile: ZoneFields) {
  return profile.zone ?? undefined
}

function parseZone(value: Record<string, unknown>, parentChainId: number, path: string) {
  exactKeys(value, path, ['id', 'enableEarnShare'])
  const id = positiveInteger(value.id, `${path}.id`)
  if (id > 4_294_967_295) throw new Error(`${path}.id must fit uint32`)
  if (value.enableEarnShare !== true) throw new Error(`${path}.enableEarnShare must be true`)
  const zone: ZoneIntent = { id, chainId: zoneChainId(parentChainId, id), enableEarnShare: true }
  return zone
}

/** Whether an Earn-mode ZoneRouter routes private deposits and redemptions into the profile's Zone. */
function earnModeOnZone(profile: ZoneProfile & Partial<ZoneRouterFields>) {
  return (
    profile.zone !== null &&
    profile.zoneRouter?.zoneId === profile.zone.id &&
    !!profile.zoneRouter.earn
  )
}
