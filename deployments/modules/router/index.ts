import { getAddress, zeroAddress, type Address, type PublicClient } from 'viem'
import { Addresses } from 'viem/tempo'

import { zoneRouterAbi, zoneRouterFactoryAbi } from '../../abis/index.js'
import { requireCode } from '../../chain/inspect.js'
import { rpcClient } from '../../chain/runtime.js'
import {
  missingZoneTokens,
  registeredZone,
  zoneCallbackGatewayRegistered,
  zoneGatewayDepositsAdmitted,
} from '../../chain/zone.js'
import type { EarnDeploymentProfile } from '../../core/profile.js'
import { stackAddress } from '../../core/stack.js'
import { preflightRouterRoute } from '../earn/zone-router/index.js'
import { inspectRouterReadiness } from '../earn/zone-router/inspection.js'
import { requiredOutput, type CapabilityModule, type CapabilityReadiness } from '../module.js'
import { inspectZoneRouterBinding } from './inspection.js'
import { zoneRouterFactory, zoneRouterMode, zoneRouterModeHash } from './profile.js'
import { zoneRouterTokens } from './steps.js'

/**
 * The Zone router capability: a `ZoneRouter` mode deployed through a `ZoneRouterFactory` (the
 * profile's, or one it deploys), its PropAMM admission when its Earn binding converts, and the
 * token and callback-gateway readiness its Zone's Portal administrator owns.
 */
export const zoneRouterModeModule: CapabilityModule = {
  preflight: preflightZoneRouter,
  // The Factory-registered Portal, Messenger and sequencers of the router's Zone, read from the L1.
  async discover({ profile, rpcUrl }) {
    if (!profile.zoneRouter) return undefined
    const zone = await registeredZone(rpcClient(rpcUrl), profile.zoneRouter.zoneId)
    return {
      zoneRouterPortal: zone.portal,
      zoneRouterMessenger: zone.messenger,
      ...Object.fromEntries(
        zone.sequencers.map((sequencer, index) => [`zoneRouterSequencer${index}`, sequencer]),
      ),
    }
  },
  metadataOutput: isZoneRouterMetadataOutput,
  // The Portal, Messenger, Outbox and sequencers move EarnShare in and out of the router's Zone.
  accessPrincipals: (profile, outputs) =>
    profile.zoneRouter
      ? Object.entries(outputs)
          .flatMap(([key, value]) =>
            (key === 'zoneRouterPortal' || isZoneRouterMetadataOutput(key)) && value ? [value] : [],
          )
          .concat(getAddress(Addresses.zoneOutbox))
      : [],
  async stackAccessPrincipals(client, stack) {
    const router = stackAddress(stack, 'zoneRouter')
    if (!router) return []
    const zoneId = await client.readContract({
      address: router,
      abi: zoneRouterAbi,
      functionName: 'allowedZoneId',
    })
    const zone = await registeredZone(client, Number(zoneId))
    return [zone.portal, zone.messenger, ...zone.sequencers, getAddress(Addresses.zoneOutbox)]
  },
  async inspect(client, profile, outputs) {
    if (!profile.zoneRouter) return undefined
    const router = requiredOutput(outputs, 'zoneRouter')
    const factory = zoneRouterFactory(profile, outputs)
    const portal = requiredOutput(outputs, 'zoneRouterPortal')
    await requireCode(client, { 'Zone router': router, ZoneRouterFactory: factory })
    const mode = zoneRouterMode(profile, outputs)
    await inspectZoneRouterBinding(client, {
      router,
      factory,
      mode,
      earnShare: requiredOutput(outputs, 'earnShare'),
      vaultAsset: requiredOutput(outputs, 'asset'),
    })
    const earn = profile.zoneRouter.earn
    const [gateway, depositsBack, disabled, inactive, conversion] = await Promise.all([
      zoneCallbackGatewayRegistered(client, portal, router),
      zoneGatewayDepositsAdmitted(client, portal, router),
      earn ? missingZoneTokens(client, portal, zoneRouterTokens(profile, outputs)) : [],
      earn
        ? missingZoneTokens(client, portal, zoneRouterTokens(profile, outputs), {
            depositsActive: true,
          })
        : [],
      earn?.pool ? inspectRouterReadiness(client, router, earn.pool) : undefined,
    ])
    const zoneId = profile.zoneRouter.zoneId
    const blockers = [
      ...(gateway ? [] : [`Zone ${zoneId} has not registered the router as a callback gateway`]),
      ...(depositsBack
        ? []
        : [
            `Zone ${zoneId} enforces access with open gateways and has not admitted the router as an account`,
          ]),
      ...(disabled.length === 0
        ? []
        : [`Zone ${zoneId} has not enabled ${disabled.join(' and ')}`]),
      ...(inactive.length === 0 ? [] : [`Zone deposits are paused for ${inactive.join(' and ')}`]),
    ]
    const report: Record<string, CapabilityReadiness> = {
      zoneRouter: {
        label: 'Zone router',
        status: blockers.length === 0 ? 'ready' : 'blocked',
        blockers,
        details: { modeHash: zoneRouterModeHash(mode), factory },
      },
    }
    if (conversion) {
      report.zoneRouterConversion = {
        label: 'Zone router conversion',
        status: conversion.status,
        blockers: conversion.blockers,
        // Inventory in token base units.
        details: {
          depositInventory: conversion.depositLiquidity?.toString() ?? null,
          redeemInventory: conversion.redeemLiquidity?.toString() ?? null,
        },
      }
    }
    return report
  },
}

/** Discovered Zone principals of the router's Zone, kept out of the deployment record. */
function isZoneRouterMetadataOutput(key: string) {
  return key === 'zoneRouterMessenger' || /^zoneRouterSequencer\d+$/.test(key)
}

/**
 * Before any key is used: the Zone is registered (discovery reads it), every settler and a named
 * factory hold code and the factory answers as one, and an Earn binding's route matches the vault
 * asset as `ZoneRouter`'s constructor requires.
 */
async function preflightZoneRouter(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  profile: EarnDeploymentProfile,
) {
  const router = profile.zoneRouter
  if (!router) return
  await requireCode(client, {
    ...Object.fromEntries(
      (router.settlers ?? []).map((settler, index) => [`settler ${index}`, settler]),
    ),
    ...(router.factory ? { ZoneRouterFactory: router.factory } : {}),
  } as Record<string, Address>)
  if (router.factory) {
    await client.readContract({
      address: router.factory,
      abi: zoneRouterFactoryAbi,
      functionName: 'isRouter',
      args: [zeroAddress],
    })
  }
  if (router.earn) {
    await preflightRouterRoute(client, profile, {
      privateAsset: router.earn.privateAsset,
      pool: router.earn.pool,
      path: 'zoneRouter.earn',
    })
  }
}
