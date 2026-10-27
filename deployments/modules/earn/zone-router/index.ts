import { erc20Abi, getAddress, zeroAddress, type Address, type PublicClient } from 'viem'
import { Addresses } from 'viem/tempo'

import { earnEngineBindingAbi, propAMMPoolAbi } from '../../../abis/index.js'
import { requireCode } from '../../../chain/inspect.js'
import { tempoApiRpcUrl } from '../../../chain/tempo.js'
import { inspectZone, missingZoneTokens, registeredZone } from '../../../chain/zone.js'
import {
  configuredEngineAddress,
  deploysEngine,
  profileEngineFactory,
  type EarnDeploymentProfile,
} from '../../../core/profile.js'
import {
  required,
  requiredOutput,
  type CapabilityModule,
} from '../../../../deployments/modules/module.js'
import { zoneRouterStackFields } from './catalog.js'
import { inspectRouterBinding, inspectRouterReadiness } from './inspection.js'
import { discoverZoneOutputs, isZoneSequencerOutput } from './outputs.js'
import { configuredZone, routerArgs, zoneIdentityAddresses } from './profile.js'

/**
 * The single-Zone router capability: an immutable `SingleZoneEarnRouter` bound to one canonical
 * Zone, its PropAMM conversion pool when the private asset differs from the vault asset, and the
 * Zone token and callback-gateway readiness the Portal administrator owns.
 */
export const zoneRouterModule: CapabilityModule = {
  preflight: preflightRouter,
  discover: (options) => discoverZoneOutputs({ ...options, requireLiveZone: options.requireLive }),
  liveCheck: { flag: 'zone', label: 'Zone', applies: (profile) => !!configuredZone(profile) },
  metadataOutput: isZoneSequencerOutput,
  // The Portal, Messenger, Outbox, and sequencers move EarnShare in and out of the Zone.
  accessPrincipals: (_profile, outputs) => [
    ...Object.keys(zoneIdentityAddresses).flatMap((key) => (outputs[key] ? [outputs[key]] : [])),
    ...Object.entries(outputs).flatMap(([key, value]) =>
      isZoneSequencerOutput(key) && value ? [value] : [],
    ),
  ],
  async stackAccessPrincipals(client, stack) {
    const zone = stack.network.zone
    if (!zone) return []
    return [
      zone.portal,
      zone.messenger,
      ...(await registeredZone(client, zone.id)).sequencers,
      getAddress(Addresses.zoneOutbox),
    ]
  },
  async inspect(client, profile, outputs) {
    const zone = configuredZone(profile)
    if (!zone) return undefined
    const router = requiredOutput(outputs, 'earnRouter')
    await requireCode(client, zone.pool ? { router, pool: zone.pool } : { router })
    const pool = await inspectRouterBinding(client, {
      ...routerArgs(profile, outputs),
      router,
      earnShare: requiredOutput(outputs, 'earnShare'),
      vaultAsset: requiredOutput(outputs, 'asset'),
    })
    const portal = requiredOutput(outputs, 'zonePortal')
    const tokens = zoneRouteTokens(profile, outputs)
    const [conversion, disabled, inactive] = await Promise.all([
      // A router whose private asset is the vault asset has no conversion to inspect or report.
      pool && pool !== zeroAddress ? inspectRouterReadiness(client, router, pool) : undefined,
      missingZoneTokens(client, portal, tokens),
      missingZoneTokens(client, portal, tokens, { depositsActive: true }),
    ])
    const zoneBlockers = [
      ...(disabled.length === 0
        ? []
        : [`Zone ${zone.id} has not enabled ${disabled.join(' and ')}`]),
      ...(inactive.length === 0 ? [] : [`Zone deposits are paused for ${inactive.join(' and ')}`]),
    ]
    return {
      ...(conversion && {
        router: {
          label: 'Router conversion',
          status: conversion.status,
          blockers: conversion.blockers,
          // Inventory in token base units.
          details: {
            depositInventory: conversion.depositLiquidity?.toString() ?? null,
            redeemInventory: conversion.redeemLiquidity?.toString() ?? null,
          },
        },
      }),
      zoneTokens: {
        label: 'Zone tokens',
        status: zoneBlockers.length === 0 ? 'ready' : 'blocked',
        blockers: zoneBlockers,
      },
    }
  },
  /** The network's Zone with its live sequencers, once the record's Zone identity still matches. */
  async stack({ client, environment, profile, record }) {
    const zone = configuredZone(profile)
    if (!zone) return {}
    const live = await inspectZone({ id: zone.id, chainId: zone.chainId, l1Client: client })
    const addresses = record.addresses as Record<string, Address>
    const portal = requiredOutput(addresses, 'zonePortal')
    const messenger = requiredOutput(addresses, 'zoneMessenger')
    if (live.portal !== portal || live.messenger !== messenger) {
      throw new Error(`Profile ${profile.id} deployment record has stale Zone identity`)
    }
    return zoneRouterStackFields(
      {
        name: environment.id,
        id: zone.id,
        chainId: zone.chainId,
        rpcUrl: tempoApiRpcUrl(zone.chainId),
        portal,
        messenger,
        sequencers: live.sequencers,
      },
      {
        earnRouter: requiredOutput(addresses, 'earnRouter'),
        privateAsset: zone.privateAsset,
      },
    )
  },
}

/** The router's tokens, which both enter and leave the Zone, labeled for readiness reports. */
export function zoneRouteTokens(
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
): [label: string, token: Address][] {
  return [
    ['EarnShare', requiredOutput(outputs, 'earnShare')],
    ['private asset', required(configuredZone(profile), 'single-Zone router module').privateAsset],
  ]
}

/**
 * The router's private asset and pool must hold code, and its constructor accepts a pool trading
 * exactly the private asset and vault asset, or no pool when the private asset is the vault asset.
 */
async function preflightRouter(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  profile: EarnDeploymentProfile,
) {
  const zone = configuredZone(profile)
  if (!zone) return
  await preflightRouterRoute(client, profile, {
    privateAsset: zone.privateAsset,
    pool: zone.pool,
    path: 'zone.router',
  })
}

/**
 * Checks one Earn router route against the profile's vault asset before deployment: the private
 * asset and pool hold code, and the pool trades exactly the private asset and vault asset with equal
 * decimals, or there is no pool and the private asset is the vault asset. `path` names the route's
 * authored object in errors.
 */
export async function preflightRouterRoute(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  profile: EarnDeploymentProfile,
  zone: { privateAsset: Address; pool?: Address | undefined; path: string },
) {
  await requireCode(client, {
    'Zone private asset': zone.privateAsset,
    ...(zone.pool ? { 'PropAMM pool': zone.pool } : {}),
  })
  // The engine's asset, or the asset of the venue its factory will provision it from.
  const vaultAsset = deploysEngine(profile)
    ? await profileEngineFactory(profile).venueAsset(client, profile.engine.venue)
    : await client.readContract({
        address: required(configuredEngineAddress(profile), 'engine.address'),
        abi: earnEngineBindingAbi,
        functionName: 'asset',
      })
  const conversion = zone.pool === undefined ? undefined : { pool: zone.pool }
  if (!conversion) {
    if (getAddress(vaultAsset) !== zone.privateAsset) {
      throw new Error(
        `Router private asset ${zone.privateAsset} is not the vault asset ${vaultAsset}; configure ${zone.path}.pool and ${zone.path}.customerId to convert it`,
      )
    }
    return
  }
  const [base, quote] = await Promise.all([
    client.readContract({
      address: conversion.pool,
      abi: propAMMPoolAbi,
      functionName: 'baseToken',
    }),
    client.readContract({
      address: conversion.pool,
      abi: propAMMPoolAbi,
      functionName: 'quoteToken',
    }),
  ])
  const pair = [getAddress(base), getAddress(quote)].sort()
  const expected = [zone.privateAsset, getAddress(vaultAsset)].sort()
  if (pair[0] !== expected[0] || pair[1] !== expected[1] || expected[0] === expected[1]) {
    throw new Error(
      `PropAMM pool ${conversion.pool} trades ${base}/${quote}; expected private asset ${zone.privateAsset} and vault asset ${vaultAsset}`,
    )
  }
  const [privateDecimals, vaultDecimals] = await Promise.all([
    client.readContract({ address: zone.privateAsset, abi: erc20Abi, functionName: 'decimals' }),
    client.readContract({
      address: getAddress(vaultAsset),
      abi: erc20Abi,
      functionName: 'decimals',
    }),
  ])
  if (privateDecimals !== vaultDecimals) {
    throw new Error(
      `Router private asset has ${privateDecimals} decimals but the vault asset has ${vaultDecimals}`,
    )
  }
}
