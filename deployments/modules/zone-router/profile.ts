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
import { releasedContract } from '../../core/releases.js'
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
 * One `ZoneRouter` mode, which the released `ZoneRouterFactory` deploys. The constructor's rules hold
 * at parse time: `earn` exactly when Deposit or Redeem is enabled, `spenders` exactly when Spend is.
 */
export type ZoneRouterIntent = {
  zoneId: number
  ops: ZoneRouterOp[]
  earn?: ZoneRouterEarn
  /** Spenders Spend may use; their order is part of the mode and so of the router's address. */
  spenders?: Address[]
}

/** The profile fields the router slice owns. */
export type ZoneRouterFields = { zoneRouter: ZoneRouterIntent | null }

type RouterProfile = SliceProfile<ZoneRouterFields>

// Fixed for existing records' intent hashes: never change them. Code identity decides router replacement.
const legacyModeIntent = { zoneRouterContractRelease: 2 } as const
const legacyComponentIntent = { contractRelease: 2 } as const

/**
 * The `zoneRouter` slice: a `ZoneRouter` mode from `zone-router/`, deployed through the released
 * `ZoneRouterFactory` (from the release registry, recorded beside it), and the Portal of the Zone it
 * serves. A mode change deploys a new router through the same factory.
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
    profile.zoneRouter ? { zoneRouter: profile.zoneRouter, ...legacyModeIntent } : {},
  components: {
    zoneRouter: (profile: RouterProfile, deployment: string) =>
      profile.zoneRouter
        ? {
            ...legacyComponentIntent,
            deployment,
            earnVault: profile.zoneRouter.earn ? 'derived' : null,
            zoneRouter: profile.zoneRouter,
          }
        : null,
  },
  externalAddresses: { zoneRouterPortal: 'zoneRouter', zoneRouterFactory: 'zoneRouter' },
  periphery: { zoneRouter: 'zoneRouter' },
} as const satisfies ProfileSlice<ZoneRouterFields>

/** The configured router, or a lifecycle error naming the module when the profile has none. */
export function configuredZoneRouter(profile: ZoneRouterFields) {
  return required(profile.zoneRouter ?? undefined, 'Zone router module')
}

/**
 * The factory the router deploys through: the recorded one, which discovery sets for a Spend router to
 * the one its spenders bind, or for any other router not deployed yet the released
 * `ZoneRouterFactory` from the registry, which a profile never creates.
 */
export function zoneRouterFactory(profile: RouterProfile, outputs: Record<string, Address>) {
  const router = configuredZoneRouter(profile)
  if (outputs.zoneRouterFactory) return outputs.zoneRouterFactory
  // A Spend router through any other factory could never spend, so it never falls back.
  if (router.spenders?.length)
    throw new Error(
      'The ZoneRouterFactory zoneRouter.spenders bind is unresolved; rerun once every spender answers ROUTER_FACTORY',
    )
  return releasedContract(profile.chainId, 'zoneRouterFactory')
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
    spenders: router.spenders ?? [],
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
  exactKeys(value, path, ['zoneId', 'ops'], ['earn', 'spenders'])
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
  if (spends !== (value.spenders !== undefined)) {
    throw new Error(
      spends
        ? `${path}.spenders is required with spend`
        : `${path}.spenders is not supported without spend`,
    )
  }
  const spenders =
    value.spenders === undefined
      ? undefined
      : array(value.spenders, `${path}.spenders`).map((spender, index) =>
          address(spender, `${path}.spenders[${index}]`),
        )
  if (spenders) {
    if (spenders.length === 0) throw new Error(`${path}.spenders must list at least one spender`)
    unique(spenders, `${path}.spenders spender`)
  }
  return {
    zoneId,
    ops,
    ...(value.earn === undefined
      ? {}
      : { earn: parseEarn(object(value.earn, `${path}.earn`), `${path}.earn`) }),
    ...(spenders ? { spenders } : {}),
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
