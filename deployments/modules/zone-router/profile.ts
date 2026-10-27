import {
  encodeAbiParameters,
  keccak256,
  zeroAddress,
  zeroHash,
  type AbiParameter,
  type Address,
  type Hex,
} from 'viem'

import { zoneRouterAbi } from '../../abis/index.js'
import {
  address,
  array,
  exactKeys,
  isBytes32,
  literal,
  object,
  positiveInteger,
  unique,
} from '../../core/parse.js'
import { required, requiredOutput, type ProfileSlice, type SliceProfile } from '../module.js'

/** Each op a `ZoneRouter` mode may enable, in callback-op order, with its `enabledOps` bit. */
export const zoneRouterOps = { deposit: 1, redeem: 2, spend: 4 } as const

export type ZoneRouterOp = keyof typeof zoneRouterOps

const opOrder = Object.keys(zoneRouterOps) as ZoneRouterOp[]

/**
 * The Earn binding of a router with Deposit or Redeem: the profile's own EarnVault and the private
 * asset, with the DirectPropAMM pool and customer ID that convert it unless it is the vault asset.
 */
export type ZoneRouterEarn =
  | { privateAsset: Address; pool: Address; customerId: Hex }
  | { privateAsset: Address; pool?: undefined; customerId?: undefined }

/**
 * One `ZoneRouter` mode and the factory that deploys it. The constructor's rules hold at parse time:
 * `earn` exactly when Deposit or Redeem is enabled, `settlers` exactly when Spend is.
 */
export type ZoneRouterIntent = {
  zoneId: number
  ops: ZoneRouterOp[]
  earn?: ZoneRouterEarn
  /** Settlers Spend may use; their order is part of the mode and so of the router's address. */
  settlers?: Address[]
  /** An existing `ZoneRouterFactory`; the lifecycle deploys one when omitted. */
  factory?: Address
}

/** The profile fields the router slice owns. */
export type ZoneRouterFields = { zoneRouter: ZoneRouterIntent | null }

type RouterProfile = SliceProfile<ZoneRouterFields>

// Immutable router and factory have no upgrade path. Bump when either's deployed runtime changes so
// reconciliation deploys a new factory and router instead of reusing the recorded ones.
const zoneRouterContractRelease = 1

/**
 * The `zoneRouter` slice: a `ZoneRouter` mode from `zone-router/`, the `ZoneRouterFactory` that deploys it
 * unless the profile names one, and the Portal of the Zone it serves. Each is optional periphery, so
 * a mode change deploys a new router through the same factory.
 */
export const zoneRouterModeProfile = {
  authoredKeys: ['zoneRouter'],
  parse: (root: Record<string, unknown>): ZoneRouterFields => ({
    zoneRouter:
      root.zoneRouter === undefined
        ? null
        : parseZoneRouter(
            object(root.zoneRouter, 'profile.json.zoneRouter'),
            'profile.json.zoneRouter',
          ),
  }),
  authored: (profile: RouterProfile) =>
    profile.zoneRouter ? { zoneRouter: profile.zoneRouter } : {},
  // Absent, it adds nothing, so profiles without a router keep their deployment intent hash.
  deploymentIntent: (profile: RouterProfile) =>
    profile.zoneRouter ? { zoneRouter: profile.zoneRouter } : {},
  components: {
    zoneRouterFactory: (profile: RouterProfile, deployment: string) =>
      profile.zoneRouter && profile.zoneRouter.factory === undefined
        ? { contractRelease: zoneRouterContractRelease, deployment }
        : null,
    zoneRouter: (profile: RouterProfile, deployment: string) =>
      profile.zoneRouter
        ? {
            contractRelease: zoneRouterContractRelease,
            deployment,
            earnVault: profile.zoneRouter.earn ? 'derived' : null,
            zoneRouter: profile.zoneRouter,
          }
        : null,
  },
  externalAddresses: { zoneRouterPortal: 'zoneRouter' },
  periphery: { zoneRouterFactory: 'zoneRouterFactory', zoneRouter: 'zoneRouter' },
} as const satisfies ProfileSlice<ZoneRouterFields>

/** The configured router, or a lifecycle error naming the module when the profile has none. */
export function configuredZoneRouter(profile: ZoneRouterFields) {
  return required(profile.zoneRouter ?? undefined, 'Zone router module')
}

/** The factory the router deploys through: the profile's, or the one the lifecycle deployed. */
export function zoneRouterFactory(profile: ZoneRouterFields, outputs: Record<string, Address>) {
  return configuredZoneRouter(profile).factory ?? requiredOutput(outputs, 'zoneRouterFactory')
}

/** The router's `ZoneRouter.Mode`, from which its constructor arguments and address derive. */
export function zoneRouterMode(profile: ZoneRouterFields, outputs: Record<string, Address>) {
  const router = configuredZoneRouter(profile)
  return {
    zoneId: router.zoneId,
    enabledOps: router.ops.reduce((mask, op) => mask | zoneRouterOps[op], 0),
    earnVault: router.earn ? requiredOutput(outputs, 'earnVault') : zeroAddress,
    privateAsset: router.earn?.privateAsset ?? zeroAddress,
    pool: router.earn?.pool ?? zeroAddress,
    customerId: router.earn?.customerId ?? zeroHash,
    settlers: router.settlers ?? [],
  }
}

export type ZoneRouterMode = ReturnType<typeof zoneRouterMode>

const constructorInputs = (
  zoneRouterAbi.find((item) => item.type === 'constructor') as { inputs: readonly AbiParameter[] }
).inputs

/** `abi.encode(mode)`: the router's constructor arguments, whose hash is its CREATE2 salt. */
export function zoneRouterConstructorArgs(mode: ZoneRouterMode): Hex {
  return encodeAbiParameters(constructorInputs, [mode])
}

/** The mode hash `ZoneRouterFactory` salts with and emits in `RouterDeployed`. */
export function zoneRouterModeHash(mode: ZoneRouterMode): Hex {
  return keccak256(zoneRouterConstructorArgs(mode))
}

function parseZoneRouter(value: Record<string, unknown>, path: string): ZoneRouterIntent {
  exactKeys(value, path, ['zoneId', 'ops'], ['earn', 'settlers', 'factory'])
  const zoneId = positiveInteger(value.zoneId, `${path}.zoneId`)
  if (zoneId > 4_294_967_295) throw new Error(`${path}.zoneId must fit uint32`)
  const ops = array(value.ops, `${path}.ops`).map((op, index) =>
    literal(op, `${path}.ops[${index}]`, opOrder),
  )
  if (ops.length === 0) throw new Error(`${path}.ops must enable at least one op`)
  unique(ops, `${path}.ops op`)
  if (ops.some((op, index) => index > 0 && opOrder.indexOf(op) < opOrder.indexOf(ops[index - 1]!)))
    throw new Error(`${path}.ops must be listed in ${opOrder.join(', ')} order`)

  const earns = ops.includes('deposit') || ops.includes('redeem')
  if (earns !== (value.earn !== undefined)) {
    throw new Error(
      earns
        ? `${path}.earn is required with deposit or redeem`
        : `${path}.earn is not supported without deposit or redeem`,
    )
  }
  const spends = ops.includes('spend')
  if (spends !== (value.settlers !== undefined)) {
    throw new Error(
      spends
        ? `${path}.settlers is required with spend`
        : `${path}.settlers is not supported without spend`,
    )
  }
  const settlers =
    value.settlers === undefined
      ? undefined
      : array(value.settlers, `${path}.settlers`).map((settler, index) =>
          address(settler, `${path}.settlers[${index}]`),
        )
  if (settlers) {
    if (settlers.length === 0) throw new Error(`${path}.settlers must list at least one settler`)
    unique(settlers, `${path}.settlers settler`)
  }
  return {
    zoneId,
    ops,
    ...(value.earn === undefined
      ? {}
      : { earn: parseEarn(object(value.earn, `${path}.earn`), `${path}.earn`) }),
    ...(settlers ? { settlers } : {}),
    ...(value.factory === undefined ? {} : { factory: address(value.factory, `${path}.factory`) }),
  }
}

function parseEarn(value: Record<string, unknown>, path: string): ZoneRouterEarn {
  exactKeys(value, path, ['privateAsset'], ['pool', 'customerId'])
  const privateAsset = address(value.privateAsset, `${path}.privateAsset`)
  // Omitting both binds a private asset that is the vault asset; preflight checks that.
  if ((value.pool === undefined) !== (value.customerId === undefined))
    throw new Error(`${path}.pool and ${path}.customerId must be set or omitted together`)
  if (value.pool === undefined) return { privateAsset }
  if (!isBytes32(value.customerId) || BigInt(value.customerId) === 0n)
    throw new Error(`${path}.customerId must be a nonzero 32-byte hex string`)
  return {
    privateAsset,
    pool: address(value.pool, `${path}.pool`),
    customerId: value.customerId.toLowerCase() as Hex,
  }
}
