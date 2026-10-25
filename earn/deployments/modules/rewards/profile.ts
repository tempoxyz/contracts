import { concat, keccak256, stringToHex } from 'viem'

import type { CoreProfile } from '../../core/profile.js'
import type { ProfileSlice, SliceProfile } from '../module.js'
import { parseRewardConfiguration, type RewardConfiguration } from './schema.js'

type RewardsProfile = SliceProfile<RewardConfiguration>

// Immutable reward periphery has no upgrade path. Bump only the affected release when its deployed
// runtime changes so profile reconciliation replaces that component without touching core custody.
const targetYieldContractRelease = 2
const boostRewardsContractRelease = 5

/**
 * The reward slice: `targetYield` deploys the contribution controller and `boostRewards` the Merkle
 * distributor, each its own intent component. Offchain economics stay out of the intent hashes.
 */
export const rewardsProfile = {
  authoredKeys: ['targetYield', 'boostRewards'],
  parse: (root: Record<string, unknown>): RewardConfiguration =>
    root.targetYield === undefined && root.boostRewards === undefined
      ? {}
      : parseRewardConfiguration(
          {
            ...(root.targetYield === undefined ? {} : { targetYield: root.targetYield }),
            ...(root.boostRewards === undefined ? {} : { boostRewards: root.boostRewards }),
          },
          'profile.json',
        ),
  authored: (profile: RewardsProfile) => ({
    ...(profile.targetYield ? { targetYield: profile.targetYield } : {}),
    ...(profile.boostRewards ? { boostRewards: profile.boostRewards } : {}),
  }),
  deploymentIntent: (profile: RewardsProfile, deployment: string) => ({
    ...(!profile.targetYield && !profile.boostRewards ? { rewards: null } : {}),
    ...(profile.targetYield
      ? { targetYield: { contractRelease: targetYieldContractRelease } }
      : {}),
    ...(profile.boostRewards
      ? {
          boostRewards: {
            contractRelease: boostRewardsContractRelease,
            treasury: profile.boostRewards.treasury,
            campaignId: boostRewardsCampaignId(profile, deployment),
            claimDeadline: boostRewardsClaimDeadline(profile),
          },
        }
      : {}),
  }),
  components: {
    targetYield: (profile: RewardsProfile, deployment: string) =>
      profile.targetYield
        ? {
            contractRelease: targetYieldContractRelease,
            deployment,
            earnVault: 'derived',
            owner: profile.owner,
          }
        : null,
    boostRewards: (profile: RewardsProfile, deployment: string) =>
      profile.boostRewards
        ? {
            contractRelease: boostRewardsContractRelease,
            deployment,
            earnVault: 'derived',
            owner: profile.owner,
            treasury: profile.boostRewards.treasury,
            campaignId: boostRewardsCampaignId(profile, deployment),
            claimDeadline: boostRewardsClaimDeadline(profile),
          }
        : null,
  },
  periphery: {
    earnContributionController: 'targetYield',
    earnMerkleRewardDistributor: 'boostRewards',
  },
  privilegedPrincipals: (profile: RewardsProfile) =>
    profile.boostRewards ? [['reward treasury', profile.boostRewards.treasury] as const] : [],
  validate(profile: RewardsProfile) {
    const target = profile.targetYield
    const boost = profile.boostRewards
    if (!target || !boost) return
    if (target.startTimestamp > boost.startTimestamp)
      throw new Error('profile.json.targetYield must start no later than boostRewards')
    if (target.endTimestamp < boost.endTimestamp)
      throw new Error('profile.json.targetYield must end no earlier than boostRewards')
    if (
      (boost.startTimestamp - target.startTimestamp) % target.intervalSeconds !== 0 ||
      (boost.endTimestamp - target.startTimestamp) % target.intervalSeconds !== 0
    ) {
      throw new Error('profile.json.boostRewards boundaries must align to targetYield intervals')
    }
  },
} as const satisfies ProfileSlice<RewardConfiguration>

/** The Merkle campaign ID, derived from the chain and the profile's deployment salt. */
export function boostRewardsCampaignId(profile: Pick<CoreProfile, 'chainId'>, deployment: string) {
  return keccak256(
    concat([
      stringToHex('tempo-earn-boost-rewards-v1'),
      stringToHex(String(profile.chainId)),
      stringToHex(deployment),
    ]),
  )
}

/** Unclaimed boost rewards return to the treasury 30 days after the program ends. */
export function boostRewardsClaimDeadline(profile: Pick<CoreProfile, 'id'> & RewardConfiguration) {
  if (!profile.boostRewards) throw new Error(`Deployment profile ${profile.id} has no boostRewards`)
  return String(profile.boostRewards.endTimestamp + 30 * 24 * 60 * 60)
}
