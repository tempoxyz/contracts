import { authoredProfile } from '@tempoxyz/contracts/deployments/node'
import { engineDefinitions } from '@tempoxyz/contracts/deployments'
import {
  parseEarnDeploymentProfile,
  type EarnDeploymentProfile,
} from '@tempoxyz/contracts/deployments/operations'
import type { Address } from 'viem'

import { localEngines } from '../engines/index.js'
import type { AccessKind, EngineKind } from './types.js'

type AuthoredProfile = ReturnType<typeof authoredProfile>
type ZoneRouterEarn = NonNullable<EarnDeploymentProfile['zoneRouter']>['earn'] & {}

/** Disposable replacements for a profile's chain-specific dependencies. */
export type LocalTargets = {
  chainId: number
  deployer: Address
  factories: EarnDeploymentProfile['factories']
  /** The local venue, or the local engine when the profile binds an existing one. */
  venueOrEngine: Address
  /** The local whitelist that stands in for the profile's TIP-403 policy. */
  policyId?: bigint | undefined
  zoneId: number
  /** The Earn binding of the Earn-mode ZoneRouter a profile with a Zone deploys on it. */
  router: ZoneRouterEarn
}

const rewardInterval = 300

/** Access each variant deploys unless a consumer asks for open access. */
export const variantAccess: AccessKind = 'tip403-whitelist'

/**
 * The profile each local variant deploys when no profile is supplied: fees on, both reward
 * contracts, and a Zone. Principals are the disposable accounts.
 */
export function variantProfile(options: {
  access: AccessKind
  deployer: Address
  engineKind: EngineKind
  now: number
  revenueShareRecipient: Address
}): AuthoredProfile {
  const start = Math.floor(options.now / rewardInterval) * rewardInterval
  // The Merkle claim deadline is the end plus 30 days: one year after deployment.
  const end = start + 335 * 24 * 60 * 60
  const window = { startTimestamp: start, endTimestamp: end, intervalSeconds: rewardInterval }
  return {
    version: 1,
    id: options.engineKind,
    chainId: 0,
    engine: localEngines[options.engineKind].profileEngine(options.deployer),
    core: {
      migrationMode: 'OperatorEnabled',
      emergencyGuardian: options.deployer,
      asyncJanitor: options.deployer,
      fees: {
        fixed: [
          { recipient: options.deployer, rateBps: 25 },
          { recipient: options.revenueShareRecipient, rateBps: 500 },
        ],
        excess: { recipient: options.deployer, annualTargetRateBps: 300, rateBps: 5_000 },
      },
    },
    ...(options.access === 'tip403-whitelist' ? { tip403PolicyId: '2' } : {}),
    zone: { id: 1, enableEarnShare: true },
    targetYield: {
      ...window,
      annualRate: { bps: 500 },
      funding: [{ wallet: options.deployer, remainder: true }],
    },
    boostRewards: {
      ...window,
      targetAnnualRateBps: 100,
      perUserPrincipalCapAssets: '1000000000000',
      totalPrincipalCapAssets: '1000000000000',
      treasury: options.revenueShareRecipient,
      funding: { wallet: options.revenueShareRecipient },
      excludedAddresses: [],
    },
  }
}

/** Whether the authored profile restricts EarnShare transfers to a TIP-403 whitelist. */
export function isProtected(profile: AuthoredProfile) {
  return profile.tip403PolicyId !== undefined
}

/**
 * Retargets an authored profile at the disposable chain. Only external dependencies change: chain,
 * venue or engine, TIP-403 policy, and Zone ID. Core settings, principals, and rewards are deployed
 * as authored. A profile with a Zone also gets an Earn-mode ZoneRouter on it over `local.router`.
 */
export function localizeProfile(source: AuthoredProfile, local: LocalTargets) {
  assertLocalProfile(source)
  const { tip403PolicyId: _policy, zone, ...rest } = source
  const engine = localEngines[source.engine.kind].profileEngine(local.venueOrEngine)
  if ('venue' in engine && !('venue' in source.engine)) {
    throw new Error(
      `Profile ${source.id} binds an existing ${engineDefinitions[engine.kind].label} engine; local runs need a venue`,
    )
  }
  if (isProtected(source) !== (local.policyId !== undefined)) {
    throw new Error(`Profile ${source.id} access does not match the local policy`)
  }
  const authored = {
    ...rest,
    chainId: local.chainId,
    engine,
    ...(local.policyId === undefined ? {} : { tip403PolicyId: local.policyId.toString() }),
    ...(zone
      ? {
          zone: { id: local.zoneId, enableEarnShare: zone.enableEarnShare },
          zoneRouter: { zoneId: local.zoneId, ops: ['deposit', 'redeem'], earn: local.router },
        }
      : {}),
  }
  return parseEarnDeploymentProfile(authored, {
    allowEphemeralChain: true,
    deployer: local.deployer,
    factories: local.factories,
  })
}

/**
 * The PATHUSD stack: the primary profile's core and access, no rewards, and a router over
 * `local.router`, which binds PATHUSD with no pool.
 */
export function sameAssetProfile(primary: EarnDeploymentProfile, local: LocalTargets) {
  const {
    targetYield: _targetYield,
    boostRewards: _boostRewards,
    zoneRouter: _zoneRouter,
    ...source
  } = authoredProfile(primary)
  return localizeProfile(
    {
      ...source,
      id: `${primary.id}-same-asset`,
      engine: localEngines.erc4626.profileEngine(local.venueOrEngine),
      zone: { id: local.zoneId, enableEarnShare: true },
    },
    local,
  )
}

/** Refuses chain-specific spender graphs that do not yet have disposable replacements. */
export function assertLocalProfile(profile: {
  id: string
  zoneRouter?: AuthoredProfile['zoneRouter'] | null
}) {
  if (profile.zoneRouter) {
    throw new Error(
      `Profile ${profile.id} uses zoneRouter; local replacement of its factory, spenders, and conversion routes is not supported`,
    )
  }
}
