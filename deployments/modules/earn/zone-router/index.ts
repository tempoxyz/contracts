import { erc20Abi, getAddress, zeroAddress, type Address, type PublicClient } from 'viem'
import { Addresses } from 'viem/tempo'

import { earnEngineBindingAbi, earnVaultAbi, propAMMPoolAbi } from '../../../abis/index.js'
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
import { zoneStackFields } from './stack.js'
import { discoverZoneOutputs, isZoneSequencerOutput } from './outputs.js'
import { configuredZone, privateRoute, zoneIdentityAddresses } from './profile.js'

/**
 * The Zone capability: the canonical Zone a deployment targets, its discovered Portal, Messenger and
 * sequencers, and the EarnShare enablement its Portal administrator owns. Routing into the Zone is
 * the Zone router mode's (`zoneRouter`).
 */
export const zoneModule: CapabilityModule = {
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
    const portal = requiredOutput(outputs, 'zonePortal')
    const tokens = zoneTokens(outputs)
    const [disabled, inactive] = await Promise.all([
      missingZoneTokens(client, portal, tokens),
      missingZoneTokens(client, portal, tokens, { depositsActive: true }),
    ])
    const blockers = [
      ...(disabled.length === 0
        ? []
        : [`Zone ${zone.id} has not enabled ${disabled.join(' and ')}`]),
      ...(inactive.length === 0 ? [] : [`Zone deposits are paused for ${inactive.join(' and ')}`]),
    ]
    return {
      zoneTokens: {
        label: 'Zone tokens',
        status: blockers.length === 0 ? 'ready' : 'blocked',
        blockers,
      },
    }
  },
  /**
   * The network's Zone with its live sequencers, once the record's Zone identity still matches, and
   * any Earn-mode ZoneRouter on it.
   */
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
    // An Earn-mode ZoneRouter with Deposit and Redeem on this Zone carries the stack's private mode.
    const router = privateRoute(profile)
    return zoneStackFields(
      {
        name: environment.id,
        id: zone.id,
        chainId: zone.chainId,
        rpcUrl: tempoApiRpcUrl(zone.chainId),
        portal,
        messenger,
        sequencers: live.sequencers,
      },
      router && {
        zoneRouter: requiredOutput(addresses, 'zoneRouter'),
        privateAsset: router.privateAsset,
      },
    )
  },
}

/** The tokens the Zone must enable, labeled for readiness reports: the profile's EarnShare. */
export function zoneTokens(outputs: Record<string, Address>): [label: string, token: Address][] {
  return [['EarnShare', requiredOutput(outputs, 'earnShare')]]
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
  zone: {
    privateAsset: Address
    pool?: Address | undefined
    path: string
    earnShare?: Address | undefined
  },
) {
  if (zone.earnShare && getAddress(zone.earnShare) === getAddress(zone.privateAsset))
    throw new Error(`${zone.path}.privateAsset cannot be this vault's EarnShare`)
  await requireCode(client, {
    'Zone private asset': zone.privateAsset,
    ...(zone.pool ? { 'PropAMM pool': zone.pool } : {}),
  })
  // An existing bound engine exposes the exact share the router constructor forbids as input.
  const engine = configuredEngineAddress(profile)
  if (engine) {
    const vault = await client.readContract({
      address: engine,
      abi: earnEngineBindingAbi,
      functionName: 'earnVault',
    })
    if (getAddress(vault) !== zeroAddress) {
      const share = await client.readContract({
        address: vault,
        abi: earnVaultAbi,
        functionName: 'earnShare',
      })
      if (getAddress(share) === getAddress(zone.privateAsset))
        throw new Error(`${zone.path}.privateAsset cannot be this vault's EarnShare`)
    }
  }
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
