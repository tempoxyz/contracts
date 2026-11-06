import { getAddress } from 'viem'
import { describe, expect, test } from 'vitest'
import { parseEarnDeploymentProfile } from '../../../core/profile.js'
import { rewardsModule } from './module.js'
import { boostRewardsCampaignId, boostRewardsClaimDeadline } from './profile.js'
import { profileDeploymentSalt } from '../../../core/profile.js'
import { deployContributionController, deployMerkleDistributor } from './steps.js'

const address = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'rewards-validation',
    chainId: 4217,
    owner: address(1),
    engine: { kind: 'erc4626', address: address(2) },
    boostRewards: {
      startTimestamp: 100,
      endTimestamp: 220,
      intervalSeconds: 60,
      targetAnnualRateBps: 300,
      perUserPrincipalCapAssets: '100',
      totalPrincipalCapAssets: '1000',
      treasury: address(3),
      funding: { wallet: address(4) },
    },
  },
  { deployer: address(5) },
)
const outputs = {
  asset: address(6),
  earnVault: address(7),
  earnShare: address(8),
  earnContributionController: address(9),
  earnMerkleRewardDistributor: address(10),
}
const deadline = BigInt(boostRewardsClaimDeadline(profile))
const values = {
  asset: outputs.asset,
  earnVault: outputs.earnVault,
  earnShare: outputs.earnShare,
  treasury: profile.boostRewards!.treasury,
  owner: profile.owner,
  claimDeadline: Number(deadline),
  campaignId: boostRewardsCampaignId(profile, profileDeploymentSalt(profile)),
}
function client(timestamp: bigint, overrides: Record<string, unknown> = {}) {
  return {
    getBlock: async () => ({ timestamp }),
    getCode: async () => '0x01',
    readContract: async ({ functionName }: { functionName: string }) => {
      if (functionName in overrides) return overrides[functionName]
      if (functionName in values) return values[functionName as keyof typeof values]
      throw new Error(`Unexpected read ${functionName}`)
    },
  } as never
}

describe('reward deployment validation', () => {
  test('rejects expired claims in preflight and again before distributor deployment', async () => {
    for (const timestamp of [deadline, deadline + 1n]) {
      await expect(rewardsModule.preflight(client(timestamp), profile, {})).rejects.toThrow(
        'expired',
      )
      await expect(
        deployMerkleDistributor.satisfied(client(timestamp), profile, {}),
      ).rejects.toThrow('expired')
    }
    await expect(
      rewardsModule.preflight(client(deadline - 1n), profile, {}),
    ).resolves.toBeUndefined()
    await expect(
      deployMerkleDistributor.satisfied(client(deadline - 1n), profile, {}),
    ).resolves.toBe(false)
  })
  test('keeps already-deployed historical rewards verifiable after the deadline', async () => {
    await expect(
      rewardsModule.preflight(client(deadline + 1n), profile, outputs),
    ).resolves.toBeUndefined()
    await expect(
      deployMerkleDistributor.satisfied(client(deadline + 1n), profile, outputs),
    ).resolves.toBe(true)
  })
  test('checks the contribution controller immutable asset as well as vault and owner', async () => {
    await expect(
      deployContributionController.satisfied(client(1n), profile, outputs),
    ).resolves.toBe(true)
    await expect(
      deployContributionController.satisfied(client(1n, { asset: address(99) }), profile, outputs),
    ).resolves.toBe(false)
  })
})
