import { BaseError, getAddress, zeroAddress, type Address, type PublicClient } from 'viem'
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
import { profileCardProgram } from '../cards/steps.js'
import { requiredOutput, type CapabilityModule, type CapabilityReadiness } from '../module.js'
import {
  inspectZoneRouterBinding,
  nonMemberSpenders,
  readZoneRouterSpenders,
  spenderProvenanceBlockers,
  spenderRouterFactory,
} from './inspection.js'
import { zoneRouterFactory, zoneRouterMode, zoneRouterModeHash } from './profile.js'
import { routerFactoryRelease, spenderReleases } from './releases.js'
import {
  enablesEarnShare,
  missingZoneRouterSeeds,
  zoneRouterSeedNotes,
  zoneRouterSeedPlan,
} from './seeds.js'
import { zoneRouterTokens } from './steps.js'

/**
 * The Zone router capability: a `ZoneRouter` mode deployed through the released `ZoneRouterFactory`,
 * its PropAMM admission when its Earn binding converts, and the token and callback-gateway readiness
 * its Zone's Portal administrator owns.
 */
export const zoneRouterModeModule: CapabilityModule = {
  preflight: preflightZoneRouter,
  // The Factory-registered Portal, Messenger and sequencers of the router's Zone, read from the L1.
  // A Spend router's factory is the one its spenders bind, which they keep across mode changes.
  async discover({ profile, rpcUrl }) {
    if (!profile.zoneRouter) return undefined
    const client = rpcClient(rpcUrl)
    const zone = await registeredZone(client, profile.zoneRouter.zoneId)
    // Discovery only names the factory; preflight refuses spenders it cannot resolve, so verifying a
    // recorded router never depends on today's CardFactory.
    const bound = await spenderBoundFactory(client, profile).catch(() => undefined)
    return {
      ...(bound ? { zoneRouterFactory: bound } : {}),
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
    // Seed units and Portal allowances only save callback gas, so their absence never blocks a route,
    // and neither does a failed read of them.
    const seedDetails: Record<string, string> = await (async () => {
      try {
        const seedPlan = await zoneRouterSeedPlan(client, profile, outputs)
        const missingSeeds = zoneRouterSeedNotes(
          seedPlan,
          await missingZoneRouterSeeds(client, seedPlan),
        )
        const details: Record<string, string> = {}
        if (missingSeeds.length > 0) details.missing = missingSeeds.join('; ')
        if (seedPlan.notes.length > 0) details.withheld = seedPlan.notes.join('; ')
        return details
      } catch (error) {
        // viem's short message names the failure without the request URL, which may carry credentials.
        return {
          unread:
            error instanceof BaseError
              ? error.shortMessage
              : 'seed state could not be read from the chain',
        }
      }
    })()
    report.zoneRouterSeeds = {
      label: 'Zone router seeds',
      status: 'ready',
      blockers: [],
      ...(Object.keys(seedDetails).length > 0 ? { details: seedDetails } : {}),
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
 * The ZoneRouterFactory each listed spender takes spends from, in order: a forthcoming card program's
 * from the released CardFactory, every other spender's own `ROUTER_FACTORY` (undefined when it reports
 * none).
 */
async function spenderFactories(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address> = {},
) {
  // The card program deploys before the router: the recorded one, which a failed broadcast may have
  // left without code, or else the one the released CardFactory predicts.
  const cardProgram =
    outputs.cardProgram && outputs.cardRouterFactory
      ? {
          program: getAddress(outputs.cardProgram),
          routerFactory: getAddress(outputs.cardRouterFactory),
        }
      : await profileCardProgram(client, profile)
  const forthcoming = (spender: Address) =>
    cardProgram !== undefined && getAddress(spender) === cardProgram.program
  const factories = await Promise.all(
    (profile.zoneRouter?.spenders ?? []).map((spender) =>
      forthcoming(spender) ? cardProgram!.routerFactory : spenderRouterFactory(client, spender),
    ),
  )
  return { forthcoming, factories }
}

/**
 * The factory a Spend router deploys through: the one every spender binds, since a spender refuses
 * any other factory's routers; undefined without spenders or when they disagree.
 */
async function spenderBoundFactory(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address> = {},
) {
  if (!profile.zoneRouter?.spenders?.length) return undefined
  const { factories } = await spenderFactories(client, profile, outputs)
  const [first] = factories
  return first && factories.every((factory) => factory === first) ? first : undefined
}

/**
 * Before any key is used: the Zone is registered (discovery reads it), the router's factory (recorded,
 * else the one its spenders bind, else the released one, which must be this build's) and every spender
 * hold code and the factory answers as one, every spender takes `spendFrom` from that factory's
 * routers, and an Earn binding's route matches the vault asset as `ZoneRouter`'s constructor requires.
 */
async function preflightZoneRouter(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address> = {},
) {
  const router = profile.zoneRouter
  if (!router) return
  const { forthcoming, factories } = await spenderFactories(client, profile, outputs)
  const bound = await spenderBoundFactory(client, profile, outputs)
  const factory = outputs.zoneRouterFactory ?? bound ?? zoneRouterFactory(profile, outputs)
  // A spender refuses `spendFrom` from any other factory's router.
  for (const [index, spender] of (router.spenders ?? []).entries()) {
    const path = `zoneRouter.spenders[${index}] ${spender}`
    const spenderFactory = factories[index]
    if (!spenderFactory) throw new Error(`${path} reports no ROUTER_FACTORY`)
    if (spenderFactory !== getAddress(factory)) {
      throw new Error(
        `${path} takes spendFrom only from routers of ZoneRouterFactory ${spenderFactory}, not the router's ${factory}`,
      )
    }
  }
  if (!outputs.zoneRouterFactory) {
    // A router not deployed yet is source verified against this build, so only this build's factory
    // can create one; a registry naming another build's factory would also replace routers forever.
    const expected = routerFactoryRelease.address()
    if (getAddress(factory) !== expected)
      throw new Error(
        bound
          ? `zoneRouter.spenders bind ZoneRouterFactory ${factory}, not this build's ${expected}, so a new router through it could not be source verified; list spenders bound to this build's release factory`
          : `Released ZoneRouterFactory ${factory} is not this build's ${expected}; run pnpm release and record its registry entry first`,
      )
  }
  await requireCode(client, {
    ...Object.fromEntries(
      (router.spenders ?? [])
        .map((spender, index) => [`spender ${index}`, spender] as const)
        .filter(([, spender]) => !forthcoming(spender)),
    ),
    ZoneRouterFactory: factory,
  } as Record<string, Address>)
  await client.readContract({
    address: factory,
    abi: zoneRouterFactoryAbi,
    functionName: 'isRouter',
    args: [zeroAddress],
  })
  if (router.earn) {
    await preflightRouterRoute(client, profile, {
      privateAsset: router.earn.privateAsset,
      pool: router.earn.pool,
      path: 'zoneRouter.earn',
      earnShare: outputs.earnShare,
    })
  }
}
