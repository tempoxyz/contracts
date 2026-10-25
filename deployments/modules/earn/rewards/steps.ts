import {
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  parseAbiParameters,
  type Address,
} from 'viem'

import {
  deployEarnContributionControllerScriptAbi,
  deployEarnMerkleRewardDistributorScriptAbi,
  earnContributionControllerAbi,
  earnMerkleRewardDistributorAbi,
} from '../../../abis/index.js'
import { profileDeploymentSalt, type EarnDeploymentProfile } from '../../../core/profile.js'
import {
  defineFoundryStep,
  deployedOutputs,
  deployerAuthority,
  required,
  requiredOutput,
} from '../../../../deployments/modules/module.js'
import { boostRewardsCampaignId, boostRewardsClaimDeadline } from './profile.js'

/**
 * The distributor's constructor arguments, which its deploy input, source verification, and
 * readback all derive from.
 */
function distributorArgs(profile: EarnDeploymentProfile, outputs: Record<string, Address>) {
  return {
    earnVault: requiredOutput(outputs, 'earnVault'),
    treasury: required(profile.boostRewards, 'boostRewards').treasury,
    campaignId: boostRewardsCampaignId(profile, profileDeploymentSalt(profile)),
    claimDeadline: Number(boostRewardsClaimDeadline(profile)),
    owner: profile.owner,
  }
}

export const deployMerkleDistributor = defineFoundryStep({
  id: 'deploy-merkle-distributor',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: 'Deploy the EarnShare Merkle distributor.',
  phase: 'deployment',
  intent: ['boostRewards'],
  script:
    'script/deploy/DeployEarnMerkleRewardDistributor.s.sol:DeployEarnMerkleRewardDistributorScript',
  enabled: (profile) => Boolean(profile.boostRewards),
  input: (profile, outputs, outputPath) =>
    encodeFunctionData({
      abi: deployEarnMerkleRewardDistributorScriptAbi,
      functionName: 'run',
      args: [
        {
          expectedChainId: BigInt(profile.chainId),
          ...distributorArgs(profile, outputs),
          outputPath,
        },
      ],
    }),
  source: {
    output: 'earnMerkleRewardDistributor',
    contract: 'src/rewards/EarnMerkleRewardDistributor.sol:EarnMerkleRewardDistributor',
    constructorArgs(profile, outputs) {
      const args = distributorArgs(profile, outputs)
      return encodeAbiParameters(
        parseAbiParameters(
          'address earnVault, address treasury, bytes32 campaignId, uint40 claimDeadline, address owner',
        ),
        [args.earnVault, args.treasury, args.campaignId, args.claimDeadline, args.owner],
      )
    },
    // Unspent EarnShare returns to the immutable treasury after the claim window.
    accessMember: {
      abi: earnMerkleRewardDistributorAbi,
      principals: {
        treasury: (profile) => required(profile.boostRewards, 'boostRewards').treasury,
      },
    },
  },
  async satisfied(client, profile, outputs) {
    if (!(await deployedOutputs(client, outputs, ['earnMerkleRewardDistributor']))) return false
    const address = requiredOutput(outputs, 'earnMerkleRewardDistributor')
    const read = <
      F extends
        | 'earnVault'
        | 'asset'
        | 'earnShare'
        | 'treasury'
        | 'campaignId'
        | 'claimDeadline'
        | 'owner',
    >(
      functionName: F,
    ) => client.readContract({ address, abi: earnMerkleRewardDistributorAbi, functionName })
    const [vault, asset, share, treasury, campaignId, claimDeadline, owner] = await Promise.all([
      read('earnVault'),
      read('asset'),
      read('earnShare'),
      read('treasury'),
      read('campaignId'),
      read('claimDeadline'),
      read('owner'),
    ])
    const expected = distributorArgs(profile, outputs)
    return (
      getAddress(vault) === expected.earnVault &&
      getAddress(asset) === requiredOutput(outputs, 'asset') &&
      getAddress(share) === requiredOutput(outputs, 'earnShare') &&
      getAddress(treasury) === expected.treasury &&
      campaignId.toLowerCase() === expected.campaignId.toLowerCase() &&
      claimDeadline === expected.claimDeadline &&
      getAddress(owner) === expected.owner
    )
  },
})

export const deployContributionController = defineFoundryStep({
  id: 'deploy-contribution-controller',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: 'Deploy the contribution controller.',
  phase: 'deployment',
  intent: ['targetYield'],
  script:
    'script/deploy/DeployEarnContributionController.s.sol:DeployEarnContributionControllerScript',
  enabled: (profile) => Boolean(profile.targetYield),
  input: (profile, outputs, outputPath) =>
    encodeFunctionData({
      abi: deployEarnContributionControllerScriptAbi,
      functionName: 'run',
      args: [
        {
          expectedChainId: BigInt(profile.chainId),
          earnVault: requiredOutput(outputs, 'earnVault'),
          owner: profile.owner,
          outputPath,
        },
      ],
    }),
  source: {
    output: 'earnContributionController',
    contract: 'src/rewards/EarnContributionController.sol:EarnContributionController',
    constructorArgs: (profile, outputs) =>
      encodeAbiParameters(parseAbiParameters('address earnVault, address owner'), [
        requiredOutput(outputs, 'earnVault'),
        profile.owner,
      ]),
  },
  async satisfied(client, profile, outputs) {
    if (!(await deployedOutputs(client, outputs, ['earnContributionController']))) return false
    const controller = requiredOutput(outputs, 'earnContributionController')
    const [vault, owner] = await Promise.all([
      client.readContract({
        address: controller,
        abi: earnContributionControllerAbi,
        functionName: 'earnVault',
      }),
      client.readContract({
        address: controller,
        abi: earnContributionControllerAbi,
        functionName: 'owner',
      }),
    ])
    return (
      getAddress(vault) === requiredOutput(outputs, 'earnVault') &&
      getAddress(owner) === profile.owner
    )
  },
})
