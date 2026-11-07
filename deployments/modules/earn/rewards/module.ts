import type { Address } from 'viem'
import type { CapabilityModule } from '../../module.js'
import { assertBoostClaimDeadline } from './profile.js'
import { deployMerkleDistributor } from './steps.js'

/** Reward deployment checks run before any lifecycle broadcast, including core creation. */
export const rewardsModule = {
  async preflight(client, profile, outputs: Record<string, Address> = {}) {
    if (!profile.boostRewards) return
    if (
      outputs.earnMerkleRewardDistributor &&
      (await deployMerkleDistributor.satisfied(client, profile, outputs))
    )
      return
    await assertBoostClaimDeadline(client, profile)
  },
} satisfies CapabilityModule
