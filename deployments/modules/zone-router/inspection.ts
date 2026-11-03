import {
  getAddress,
  isAddress,
  parseAbi,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'
import { Abis, Addresses } from 'viem/tempo'

import { zoneRouterAbi, zoneRouterFactoryAbi } from '../../abis/index.js'
import { InspectionMismatchError, equalAddress } from '../../chain/inspect.js'
import { isBytes32 } from '../../core/parse.js'
import { inspectRouterBinding } from '../earn/zone-router/inspection.js'
import type { ZoneRouterMode } from './profile.js'

/** A `ZoneRouter` the profile expects: its factory, its exact mode, and the stack it converts into. */
export type ExpectedZoneRouter = {
  router: Address
  factory: Address
  mode: ZoneRouterMode
  /** The profile's EarnShare and vault asset, which an Earn mode binds; ignored otherwise. */
  earnShare: Address
  vaultAsset: Address
}

/**
 * Checks that `factory` deployed `router` for exactly `mode` (`isRouter` and `predict`) and that every
 * immutable the router reports matches the mode: Zone, ops, spenders in order, and the Earn binding
 * with its pool orientation, or no binding at all. Mismatches throw `InspectionMismatchError`.
 */
export async function inspectZoneRouterBinding(
  client: Pick<PublicClient, 'readContract'>,
  expected: ExpectedZoneRouter,
) {
  const { router, factory, mode } = expected
  const [deployed, predicted, enabledOps, spenders] = await Promise.all([
    client.readContract({
      address: factory,
      abi: zoneRouterFactoryAbi,
      functionName: 'isRouter',
      args: [router],
    }),
    client.readContract({
      address: factory,
      abi: zoneRouterFactoryAbi,
      functionName: 'predict',
      args: [mode],
    }),
    client.readContract({ address: router, abi: zoneRouterAbi, functionName: 'enabledOps' }),
    client.readContract({ address: router, abi: zoneRouterAbi, functionName: 'spenders' }),
  ])
  if (!deployed) {
    throw new InspectionMismatchError(
      `ZoneRouterFactory ${factory} did not deploy router ${router}`,
    )
  }
  equalAddress(predicted, router, 'router for the profile mode')
  if (enabledOps !== mode.enabledOps) {
    throw new InspectionMismatchError(`Router ops are ${enabledOps}, expected ${mode.enabledOps}`)
  }
  if (
    spenders.length !== mode.spenders.length ||
    spenders.some((spender, index) => getAddress(spender) !== getAddress(mode.spenders[index]!))
  ) {
    throw new InspectionMismatchError(
      `Router spenders are [${spenders.join(', ')}], expected [${mode.spenders.join(', ')}]`,
    )
  }
  // Zone, vault, private asset, and route; a mode without Earn ops binds zero for each.
  const earns = getAddress(mode.earnVault) !== zeroAddress
  await inspectRouterBinding(client, {
    router,
    zoneId: mode.zoneId,
    earnVault: mode.earnVault,
    earnShare: earns ? expected.earnShare : zeroAddress,
    vaultAsset: earns ? expected.vaultAsset : zeroAddress,
    privateAsset: mode.privateAsset,
    route: { pool: mode.pool, customerId: mode.customerId },
  })
}

/**
 * The release addresses a spender's provenance is checked against: the release `CardFactory` for programs
 * bound to a `ZoneRouterFactory`, and the release `SendSpender` with given constructor arguments.
 */
export type SpenderReleases = {
  cardFactory(routerFactory: Address): Address
  sendSpender(args: {
    routerFactory: Address
    convertVault: Address
    pool: Address
    customerId: Hex
  }): Address
}

const spenderAbi = parseAbi([
  'function ROUTER_FACTORY() view returns (address)',
  'function PROVIDER() view returns (address)',
  'function convertVault() view returns (address)',
  'function pool() view returns (address)',
  'function customerId() view returns (bytes32)',
])
const cardFactoryAbi = parseAbi(['function isDeployed(address program) view returns (bool)'])

/** The `ZoneRouterFactory` whose routers `spender` takes `spendFrom` from, or undefined when it reports none. */
export async function spenderRouterFactory(
  client: Pick<PublicClient, 'readContract'>,
  spender: Address,
) {
  const value: unknown = await client
    .readContract({ address: spender, abi: spenderAbi, functionName: 'ROUTER_FACTORY' })
    .catch(() => undefined)
  return typeof value === 'string' && isAddress(value) ? getAddress(value) : undefined
}

/**
 * Why each spender a router lists may be unsafe to rely on, empty when none: every spender must take
 * `spendFrom` only from routers of the router's own factory (`ROUTER_FACTORY`), and be a `CardSpender`
 * the release `CardFactory` for that factory deployed or the release `SendSpender` for its settings.
 */
export async function spenderProvenanceBlockers(
  client: Pick<PublicClient, 'readContract'>,
  expected: { factory: Address; spenders: readonly Address[] },
  releases: SpenderReleases,
) {
  // A contract without one of these getters reads as undefined rather than failing inspection.
  const read = (
    address: Address,
    functionName: (typeof spenderAbi)[number]['name'],
  ): Promise<unknown> =>
    client.readContract({ address, abi: spenderAbi, functionName }).catch(() => undefined)
  const readAddress = async (
    address: Address,
    functionName: (typeof spenderAbi)[number]['name'],
  ) => {
    const value = await read(address, functionName)
    return typeof value === 'string' && isAddress(value) ? getAddress(value) : undefined
  }
  const factory = getAddress(expected.factory)
  const blockers = await Promise.all(
    expected.spenders.map(async (spender): Promise<string | undefined> => {
      const routerFactory = await spenderRouterFactory(client, spender)
      if (!routerFactory) {
        return `Spender ${spender} reports no ROUTER_FACTORY, so it may take spendFrom from any caller`
      }
      if (routerFactory !== factory) {
        return `Spender ${spender} takes spendFrom only from routers of ZoneRouterFactory ${routerFactory}, not the router's ${factory}`
      }
      try {
        if (await readAddress(spender, 'PROVIDER')) {
          const cardFactory = releases.cardFactory(factory)
          const deployed = await client
            .readContract({
              address: cardFactory,
              abi: cardFactoryAbi,
              functionName: 'isDeployed',
              args: [spender],
            })
            .catch(() => false)
          return deployed
            ? undefined
            : `Spender ${spender} is not a CardSpender the release CardFactory ${cardFactory} deployed`
        }
        const [convertVault, pool, customerId] = await Promise.all([
          readAddress(spender, 'convertVault'),
          readAddress(spender, 'pool'),
          read(spender, 'customerId'),
        ])
        if (!convertVault || !pool || !isBytes32(customerId)) {
          return `Spender ${spender} is neither a CardSpender nor a SendSpender`
        }
        const release = releases.sendSpender({
          routerFactory: factory,
          convertVault,
          pool,
          customerId,
        })
        return getAddress(release) === spender
          ? undefined
          : `Spender ${spender} is not the release SendSpender for its settings, which is at ${release}`
      } catch (error) {
        // The release addresses come from this checkout's builds; without them provenance is unknown.
        return `Spender ${spender} provenance is unknown: ${error instanceof Error ? error.message : String(error)}`
      }
    }),
  )
  return blockers.filter((blocker) => blocker !== undefined)
}

/**
 * The spenders a protected EarnShare's TIP-403 policy does not authorize. A spend of EarnShare moves it
 * from the router to the spender and on, so each spender of a router whose Portal enables EarnShare
 * must be a member, or those spends bounce.
 */
export async function nonMemberSpenders(
  client: Pick<PublicClient, 'readContract'>,
  options: { policyId: bigint; spenders: readonly Address[] },
) {
  const authorized = await Promise.all(
    options.spenders.map((spender) =>
      client.readContract({
        address: Addresses.tip403Registry,
        abi: Abis.tip403Registry,
        functionName: 'isAuthorized',
        args: [options.policyId, spender],
      }),
    ),
  )
  return options.spenders.filter((_, index) => !authorized[index])
}
