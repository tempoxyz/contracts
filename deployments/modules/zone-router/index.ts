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
import { transferPolicyId } from '../earn/access-policy/profile.js'
import { preflightRouterRoute } from '../earn/zone-router/index.js'
import { inspectRouterReadiness } from '../earn/zone-router/inspection.js'
import { configuredZone } from '../earn/zone-router/profile.js'
import { requiredOutput, type CapabilityModule, type CapabilityReadiness } from '../module.js'
import {
  inspectZoneRouterBinding,
  nonMemberSpenders,
  readZoneRouterSpenders,
  spenderProvenanceBlockers,
  spenderRouterFactory,
} from './inspection.js'
import { zoneRouterFactory, zoneRouterMode, zoneRouterModeHash } from './profile.js'
import { spenderReleases } from './releases.js'
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
  // The Portal, Messenger, Outbox and sequencers move EarnShare in and out of the router's Zone, and
  // the mode's spenders receive it from the router when the Portal enables it.
  accessPrincipals: (profile, outputs) =>
    profile.zoneRouter
      ? Object.entries(outputs)
          .flatMap(([key, value]) =>
            (key === 'zoneRouterPortal' || isZoneRouterMetadataOutput(key)) && value ? [value] : [],
          )
          .concat(getAddress(Addresses.zoneOutbox))
          .concat(enablesEarnShare(profile) ? (profile.zoneRouter.spenders ?? []) : [])
      : [],
  async stackAccessPrincipals(client, stack) {
    const router = stackAddress(stack, 'zoneRouter')
    if (!router) return []
    const [zoneId, spenders, enabledOps] = await Promise.all([
      client.readContract({ address: router, abi: zoneRouterAbi, functionName: 'allowedZoneId' }),
      readZoneRouterSpenders(client, router),
      client.readContract({ address: router, abi: zoneRouterAbi, functionName: 'enabledOps' }),
    ])
    const zone = await registeredZone(client, Number(zoneId))
    // Protect intended EarnShare routes during onboarding, without pinning unrelated Spend-only modes.
    const needsSpenders =
      spenders.length !== 0 &&
      ((enabledOps & 3) !== 0 ||
        stack.network?.zone?.id === Number(zoneId) ||
        (await missingZoneTokens(client, zone.portal, [['EarnShare', stack.contracts.earnShare]]))
          .length === 0)
    return [
      zone.portal,
      zone.messenger,
      ...zone.sequencers,
      getAddress(Addresses.zoneOutbox),
      ...(needsSpenders ? spenders : []),
    ]
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
      portal,
      mode,
      earnShare: requiredOutput(outputs, 'earnShare'),
      vaultAsset: requiredOutput(outputs, 'asset'),
    })
    const earn = profile.zoneRouter.earn
    const earnShare = requiredOutput(outputs, 'earnShare')
    const policyId = transferPolicyId(profile)
    const [gateway, depositsBack, disabled, inactive, conversion, earnShareMissing, provenance] =
      await Promise.all([
        zoneCallbackGatewayRegistered(client, portal, router),
        zoneGatewayDepositsAdmitted(client, portal, router),
        earn ? missingZoneTokens(client, portal, zoneRouterTokens(profile, outputs)) : [],
        earn
          ? missingZoneTokens(client, portal, zoneRouterTokens(profile, outputs), {
              depositsActive: true,
            })
          : [],
        earn?.pool ? inspectRouterReadiness(client, router, earn.pool) : undefined,
        missingZoneTokens(client, portal, [['EarnShare', earnShare]]),
        spenderProvenanceBlockers(client, { factory, spenders: mode.spenders }, spenderReleases),
      ])
    // EarnShare spends move shares through each spender, which a protected EarnShare must then admit.
    const nonMembers =
      policyId !== undefined && earnShareMissing.length === 0
        ? await nonMemberSpenders(client, { policyId, spenders: mode.spenders })
        : []
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
    if (mode.spenders.length !== 0) {
      const spenderBlockers = [
        ...provenance,
        ...nonMembers.map(
          (spender) =>
            `Spender ${spender} is not a member of EarnShare's TIP-403 policy ${policyId}, so EarnShare spends through it bounce`,
        ),
      ]
      report.zoneRouterSpenders = {
        label: 'Zone router spenders',
        status: spenderBlockers.length === 0 ? 'ready' : 'blocked',
        blockers: spenderBlockers,
      }
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

/**
 * Whether the profile has the router's Portal enable EarnShare: through this mode's Earn binding, or
 * through the single-Zone router on the same Zone. Inspection reads the Portal itself.
 */
function enablesEarnShare(profile: EarnDeploymentProfile) {
  const router = profile.zoneRouter
  return (
    router !== null && (router.earn !== undefined || configuredZone(profile)?.id === router.zoneId)
  )
}

/** Discovered Zone principals of the router's Zone, kept out of the deployment record. */
function isZoneRouterMetadataOutput(key: string) {
  return key === 'zoneRouterMessenger' || /^zoneRouterSequencer\d+$/.test(key)
}

/**
 * Before any key is used: the Zone is registered (discovery reads it), every spender and a named
 * factory hold code and the factory answers as one, every spender takes `spendFrom` from that factory's
 * routers, and an Earn binding's route matches the vault asset as `ZoneRouter`'s constructor requires.
 */
async function preflightZoneRouter(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address> = {},
) {
  const router = profile.zoneRouter
  if (!router) return
  await requireCode(client, {
    ...Object.fromEntries(
      (router.spenders ?? []).map((spender, index) => [`spender ${index}`, spender]),
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
  // A spender refuses `spendFrom` from any other factory's router, so a router through a factory this
  // deployment creates could never spend through a spender already bound to another.
  for (const [index, spender] of (router.spenders ?? []).entries()) {
    const bound = await spenderRouterFactory(client, spender)
    const path = `zoneRouter.spenders[${index}] ${spender}`
    if (!bound) throw new Error(`${path} reports no ROUTER_FACTORY`)
    if (!router.factory) {
      throw new Error(
        `${path} takes spendFrom only from routers of ZoneRouterFactory ${bound}; set zoneRouter.factory to it`,
      )
    }
    if (bound !== getAddress(router.factory)) {
      throw new Error(
        `${path} takes spendFrom only from routers of ZoneRouterFactory ${bound}, not zoneRouter.factory ${router.factory}`,
      )
    }
  }
  if (router.earn) {
    await preflightRouterRoute(client, profile, {
      privateAsset: router.earn.privateAsset,
      pool: router.earn.pool,
      path: 'zoneRouter.earn',
      earnShare: outputs.earnShare,
    })
  }
}
