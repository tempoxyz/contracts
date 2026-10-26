import type { Address } from 'viem'

import {
  address,
  array,
  bps,
  exactKeys,
  nonnegativeInteger,
  object,
  positiveBps,
  positiveInteger,
  unique,
} from '../../../core/parse.js'

export type FixedAnnualRate = { bps: number }
export type AnnualRate =
  | { bps: number }
  | {
      morphoVault: Address
      staleAfterSeconds: number
      minBps: number
      maxBps: number
    }

export type TargetYieldProfile = {
  startTimestamp: number
  endTimestamp: number
  intervalSeconds: number
  annualRate: AnnualRate
  funding: Array<{ wallet: Address } & ({ upToAnnualRate: FixedAnnualRate } | { remainder: true })>
}
export type BoostRewardsProfile = {
  startTimestamp: number
  endTimestamp: number
  intervalSeconds: number
  targetAnnualRateBps: number
  perUserPrincipalCapAssets: string
  totalPrincipalCapAssets: string
  treasury: Address
  funding: { wallet: Address }
  excludedAddresses: Address[]
}

/**
 * The single canonical authored rewards document.
 *
 * Deployment profiles embed these fields at their root, while the internal administration API
 * accepts this object directly. Runtime bindings, signer authority, campaign identifiers, and
 * deployment provenance are deliberately derived rather than authored in either path.
 */
export type RewardConfiguration = {
  targetYield?: TargetYieldProfile
  boostRewards?: BoostRewardsProfile
}

export function parseRewardConfiguration(value: unknown, path = 'rewards'): RewardConfiguration {
  const source = object(value, path)
  exactKeys(source, path, [], ['targetYield', 'boostRewards'])
  const result: RewardConfiguration = {
    ...(source.targetYield === undefined
      ? {}
      : { targetYield: parseTargetYield(source.targetYield, `${path}.targetYield`) }),
    ...(source.boostRewards === undefined
      ? {}
      : { boostRewards: parseBoostRewards(source.boostRewards, `${path}.boostRewards`) }),
  }
  if (!result.targetYield && !result.boostRewards) {
    throw new Error(`${path} must define targetYield or boostRewards`)
  }
  return result
}

function parseTargetYield(value: unknown, path = 'profile.json.targetYield'): TargetYieldProfile {
  const source = object(value, path)
  exactKeys(source, path, [
    'startTimestamp',
    'endTimestamp',
    'intervalSeconds',
    'annualRate',
    'funding',
  ])
  const startTimestamp = timestamp(source.startTimestamp, `${path}.startTimestamp`)
  const endTimestamp = timestamp(source.endTimestamp, `${path}.endTimestamp`)
  const intervalSeconds = interval(source.intervalSeconds, `${path}.intervalSeconds`)
  if (endTimestamp <= startTimestamp || (endTimestamp - startTimestamp) % intervalSeconds !== 0)
    throw new Error(`${path} must contain whole positive intervals`)
  if (!Array.isArray(source.funding) || source.funding.length < 1)
    throw new Error(`${path}.funding must contain at least one funding source`)
  const funding = source.funding.map((entry, index) => {
    const itemPath = `${path}.funding[${index}]`
    const item = object(entry, itemPath)
    const hasRate = 'upToAnnualRate' in item
    const hasRemainder = 'remainder' in item
    if (hasRate === hasRemainder)
      throw new Error(`${itemPath} must define exactly one of upToAnnualRate or remainder`)
    exactKeys(item, itemPath, hasRate ? ['wallet', 'upToAnnualRate'] : ['wallet', 'remainder'])
    const common = {
      wallet: address(item.wallet, `${itemPath}.wallet`),
    }
    if (hasRate)
      return {
        ...common,
        upToAnnualRate: parseFixedAnnualRate(item.upToAnnualRate, `${itemPath}.upToAnnualRate`),
      }
    if (item.remainder !== true) throw new Error(`${itemPath}.remainder must be true`)
    return { ...common, remainder: true as const }
  })
  const remainders = funding.filter((entry) => 'remainder' in entry)
  if (remainders.length !== 1 || funding.at(-1) !== remainders[0])
    throw new Error(`${path}.funding must end with exactly one remainder source`)
  unique(
    funding.map((entry) => entry.wallet),
    `${path}.funding wallet`,
  )
  return {
    startTimestamp,
    endTimestamp,
    intervalSeconds,
    annualRate: parseAnnualRate(source.annualRate, `${path}.annualRate`),
    funding,
  }
}

function parseBoostRewards(
  value: unknown,
  path = 'profile.json.boostRewards',
): BoostRewardsProfile {
  const source = object(value, path)
  exactKeys(
    source,
    path,
    [
      'startTimestamp',
      'endTimestamp',
      'intervalSeconds',
      'targetAnnualRateBps',
      'perUserPrincipalCapAssets',
      'totalPrincipalCapAssets',
      'treasury',
      'funding',
    ],
    ['excludedAddresses'],
  )
  const startTimestamp = timestamp(source.startTimestamp, `${path}.startTimestamp`)
  const endTimestamp = timestamp(source.endTimestamp, `${path}.endTimestamp`)
  const intervalSeconds = interval(source.intervalSeconds, `${path}.intervalSeconds`)
  if (endTimestamp <= startTimestamp || (endTimestamp - startTimestamp) % intervalSeconds !== 0)
    throw new Error(`${path} must contain whole positive intervals`)
  const funding = object(source.funding, `${path}.funding`)
  exactKeys(funding, `${path}.funding`, ['wallet'])
  const excludedAddresses = (
    source.excludedAddresses === undefined
      ? []
      : array(source.excludedAddresses, `${path}.excludedAddresses`)
  ).map((value, index) => address(value, `${path}.excludedAddresses[${index}]`))
  unique(excludedAddresses, `${path}.excludedAddresses entry`)
  const perUserPrincipalCapAssets = positiveUint(
    source.perUserPrincipalCapAssets,
    `${path}.perUserPrincipalCapAssets`,
  )
  const totalPrincipalCapAssets = positiveUint(
    source.totalPrincipalCapAssets,
    `${path}.totalPrincipalCapAssets`,
  )
  if (BigInt(perUserPrincipalCapAssets) > BigInt(totalPrincipalCapAssets))
    throw new Error(`${path}.perUserPrincipalCapAssets must not exceed totalPrincipalCapAssets`)
  return {
    startTimestamp,
    endTimestamp,
    intervalSeconds,
    targetAnnualRateBps: positiveBps(source.targetAnnualRateBps, `${path}.targetAnnualRateBps`),
    perUserPrincipalCapAssets,
    totalPrincipalCapAssets,
    treasury: address(source.treasury, `${path}.treasury`),
    funding: {
      wallet: address(funding.wallet, `${path}.funding.wallet`),
    },
    excludedAddresses,
  }
}

function parseAnnualRate(value: unknown, path: string): AnnualRate {
  const source = object(value, path)
  if ('bps' in source) {
    exactKeys(source, path, ['bps'])
    return { bps: positiveBps(source.bps, `${path}.bps`) }
  }
  exactKeys(source, path, ['morphoVault', 'staleAfterSeconds', 'minBps', 'maxBps'])
  const minBps = bps(source.minBps, `${path}.minBps`)
  const maxBps = bps(source.maxBps, `${path}.maxBps`)
  if (minBps > maxBps) throw new Error(`${path}.minBps must not exceed maxBps`)
  return {
    morphoVault: address(source.morphoVault, `${path}.morphoVault`),
    staleAfterSeconds: positiveInteger(source.staleAfterSeconds, `${path}.staleAfterSeconds`),
    minBps,
    maxBps,
  }
}

function parseFixedAnnualRate(value: unknown, path: string): FixedAnnualRate {
  const source = object(value, path)
  exactKeys(source, path, ['bps'])
  return { bps: positiveBps(source.bps, `${path}.bps`) }
}

function timestamp(value: unknown, path: string) {
  return nonnegativeInteger(value, path)
}
function interval(value: unknown, path: string) {
  const result = positiveInteger(value, path)
  if (result < 60 || result > 300) throw new Error(`${path} must be between 60 and 300`)
  return result
}
function positiveUint(value: unknown, path: string) {
  if (typeof value !== 'string' || !/^[1-9][0-9]*$/.test(value))
    throw new Error(`${path} must be a positive unsigned decimal string`)
  if (BigInt(value) >= 1n << 256n) throw new Error(`${path} exceeds uint256`)
  return value
}
