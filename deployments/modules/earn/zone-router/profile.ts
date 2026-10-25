import { getAddress, zeroAddress, zeroHash, type Address, type Hex } from 'viem'

import { zoneChainId } from '../../../chain/tempo.js'
import { zoneMessengerAddress, type ZoneIdentity } from '../../../chain/zone.js'
import { address, exactKeys, isBytes32, object, positiveInteger } from '../../../core/parse.js'
import {
  required,
  requiredOutput,
  type ProfileSlice,
  type SliceProfile,
  type TargetSlice,
} from '../../../../deployments/modules/module.js'
import { zoneRouterStack } from './catalog.js'

/** The authored single-Zone router: the Zone it serves and how its private asset converts. */
export type ZoneRouterIntent = {
  id: number
  chainId: number
  enableEarnShare: true
  router: ZoneRouterProfile
}

/**
 * The router's private asset and, when it differs from the vault asset, its conversion pool. A
 * router whose private asset is the vault asset omits both `pool` and `customerId`.
 */
export type ZoneRouterProfile =
  | {
      privateAsset: Address
      /** DirectPropAMM pool that converts the private asset and vault asset at par. */
      pool: Address
      /** Nonzero pool route and trade-memo identifier. */
      customerId: Hex
    }
  | { privateAsset: Address; pool?: undefined; customerId?: undefined }

/** The profile fields the router slice owns. */
export type ZoneRouterFields = { zone: ZoneRouterIntent | null }

/** The Zone identity a deployment record targets; sequencers are live state, not identity. */
export type ZoneTarget = Omit<ZoneIdentity, 'sequencers'>

type ZoneProfile = SliceProfile<ZoneRouterFields>

/** Recorded Zone identity addresses, discovered from the canonical Factory rather than deployed. */
export const zoneIdentityAddresses = {
  zonePortal: 'zone',
  zoneMessenger: 'zone',
  zoneOutbox: 'zone',
} as const

/** The record target's `zone`: the configured Zone and its discovered Portal and Messenger. */
const zoneTarget: TargetSlice<'zone', ZoneTarget, ZoneRouterFields> = {
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
 * The `zone` slice: authored Zone router intent, the `zone` intent component and record target,
 * the Zone identity it discovers and the router it deploys, and its private-routing stack fields.
 */
export const zoneRouterProfile = {
  authoredKeys: ['zone'],
  parse: (root: Record<string, unknown>, chainId: number): ZoneRouterFields => ({
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
  deploymentIntent: (profile: ZoneProfile) => ({ zone: profile.zone }),
  components: {
    zone: (profile: ZoneProfile, deployment: string) =>
      profile.zone ? { deployment, zone: profile.zone } : null,
  },
  externalAddresses: zoneIdentityAddresses,
  addresses: { earnRouter: 'zone' },
  // Protocol precompiles are authenticated functionally and intentionally have no runtime bytecode.
  codeless: (key: string, value: Address) =>
    key === 'zoneOutbox' || (key === 'zoneMessenger' && getAddress(value) === zoneMessengerAddress),
  target: zoneTarget,
  capabilities: {
    privateRouting: (profile: ZoneProfile) => profile.zone !== null,
    routerSwaps: (profile: ZoneProfile) => profile.zone !== null,
  },
  stack: zoneRouterStack,
} as const satisfies ProfileSlice<ZoneRouterFields>

/** Flattened operational view of the configured Zone router. */
export function configuredZone(profile: ZoneRouterFields) {
  if (!profile.zone) return undefined
  const { router, ...zone } = profile.zone
  return { ...zone, ...router }
}

/**
 * The router's constructor arguments, which its deploy input, source verification, and binding
 * checks all derive from. A zero pool and customer ID deploy a router whose private asset is the
 * vault asset.
 */
export function routerArgs(profile: ZoneRouterFields, outputs: Record<string, Address>) {
  const zone = required(configuredZone(profile), 'single-Zone router module')
  return {
    zoneId: zone.id,
    earnVault: requiredOutput(outputs, 'earnVault'),
    privateAsset: zone.privateAsset,
    route: { pool: zone.pool ?? zeroAddress, customerId: zone.customerId ?? zeroHash },
  }
}

/** The configured router's conversion pool, or `undefined` when its private asset is the vault asset. */
export function configuredRouterPool(profile: ZoneRouterFields) {
  const router = profile.zone?.router
  return router?.pool === undefined
    ? undefined
    : { pool: router.pool, customerId: router.customerId }
}

function parseZone(value: Record<string, unknown>, parentChainId: number, path: string) {
  exactKeys(value, path, ['id', 'enableEarnShare', 'router'])
  const routerValue = object(value.router, `${path}.router`)
  exactKeys(routerValue, `${path}.router`, ['privateAsset'], ['pool', 'customerId'])
  const id = positiveInteger(value.id, `${path}.id`)
  if (id > 4_294_967_295) throw new Error(`${path}.id must fit uint32`)
  const privateAsset = address(routerValue.privateAsset, `${path}.router.privateAsset`)
  // Omitting both describes a router whose private asset is the vault asset; reconciliation checks that.
  if ((routerValue.pool === undefined) !== (routerValue.customerId === undefined)) {
    throw new Error(
      `${path}.router.pool and ${path}.router.customerId must be set or omitted together`,
    )
  }
  const router: ZoneRouterProfile =
    routerValue.pool === undefined
      ? { privateAsset }
      : {
          privateAsset,
          pool: address(routerValue.pool, `${path}.router.pool`),
          customerId: nonzeroBytes32(routerValue.customerId, `${path}.router.customerId`),
        }
  if (value.enableEarnShare !== true) throw new Error(`${path}.enableEarnShare must be true`)
  const zone: ZoneRouterIntent = {
    id,
    chainId: zoneChainId(parentChainId, id),
    enableEarnShare: true,
    router,
  }
  return zone
}

function nonzeroBytes32(value: unknown, path: string): Hex {
  if (!isBytes32(value) || BigInt(value) === 0n)
    throw new Error(`${path} must be a nonzero 32-byte hex string`)
  return value.toLowerCase() as Hex
}
