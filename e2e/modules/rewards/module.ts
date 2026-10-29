import { deposit, redeem } from '../../harness/support/public.js'
import { contributeDirectly, fundRewards } from './actions.js'
import { earnContributionControllerAbi, earnVaultAbi } from '@tempoxyz/contracts/abis'
import {
  E2ePrerequisiteError,
  assert,
  assertValueNotReducedBeyondOneBasisPoint,
} from '../../harness/support/utils.js'
import { mintVaultAsset, tokenBalance } from '../../harness/support/funding.js'
import { previewEarnRedeem } from '../../harness/support/slippage.js'
import { expectRevertedWrite, write } from '../../harness/support/transactions.js'
import type { E2eCase, LaunchFeature } from '../../harness/case.js'
import type { E2eActor, E2eContext } from '../../harness/context.js'

const DEPOSIT = 1_000_000n
const REWARD = 100_000n

export const launchFeatures: Record<string, LaunchFeature> = {
  rewards: {
    dimensions: ['positive', 'negative', 'authorization', 'recovery'],
    applies: ({ periphery }) => periphery.earnContributionController !== undefined,
  },
}

function setActive(context: E2eContext, actor: E2eActor, active: boolean) {
  return context.actors[actor].wallet.writeContract({
    address: context.operations.earnContributionController!,
    abi: earnContributionControllerAbi,
    functionName: 'setActive',
    args: [active],
  })
}

export const cases: readonly E2eCase[] = [
  {
    id: 'rewards-controller',
    description:
      'Only the reward owner pauses orchestration; paused funding reverts without moving assets while permissionless contributions stay live, an unavailable provider funds zero without breaking Earn, and funding resumes once unpaused.',
    default: false,
    launch: true,
    requiredPeriphery: ['earnContributionController'],
    coverage: { rewards: ['positive', 'negative', 'authorization', 'recovery'] },
    async preflight(context) {
      const active = await context.l1Public.readContract({
        address: context.operations.earnContributionController!,
        abi: earnContributionControllerAbi,
        functionName: 'active',
      })
      if (!active) throw new E2ePrerequisiteError('EarnContributionController is already paused')
    },
    async run(context) {
      await mintVaultAsset(context, DEPOSIT + REWARD * 2n)
      const setup = await deposit(context, { assets: DEPOSIT, receiver: context.user.address })
      await expectRevertedWrite(
        context,
        () => setActive(context, 'user', false),
        'non-owner unexpectedly paused EarnContributionController',
      )
      try {
        await write(context.actors.operator.wallet, {
          address: context.operations.earnContributionController!,
          abi: earnContributionControllerAbi,
          functionName: 'setActive',
          args: [false],
        })
        const [valueBefore, funderBefore] = await Promise.all([
          previewEarnRedeem(context, setup.earnShares),
          tokenBalance(context, context.assets.base, context.user.address),
        ])
        await expectRevertedWrite(
          context,
          () =>
            context.actors.operator.wallet.writeContract({
              address: context.operations.earnContributionController!,
              abi: earnContributionControllerAbi,
              functionName: 'fund',
              args: [context.user.address, REWARD, setup.earnShares],
            }),
          'paused reward controller unexpectedly accepted funding',
        )
        const [valueAfterPaused, funderAfter] = await Promise.all([
          previewEarnRedeem(context, setup.earnShares),
          tokenBalance(context, context.assets.base, context.user.address),
        ])
        assert(valueAfterPaused === valueBefore, 'paused funding changed holder value')
        assert(funderAfter === funderBefore, 'paused funding moved provider assets')

        const direct = await contributeDirectly(context, { assets: REWARD })
        assert(direct.engineShares > 0n, 'reward pause blocked direct contribution')
        assertValueNotReducedBeyondOneBasisPoint(
          await previewEarnRedeem(context, setup.earnShares),
          valueAfterPaused,
          'direct contribution accounting reduced holder value',
        )
      } finally {
        await write(context.actors.operator.wallet, {
          address: context.operations.earnContributionController!,
          abi: earnContributionControllerAbi,
          functionName: 'setActive',
          args: [true],
        })
      }

      const totalEarnShares = () =>
        context.l1Public.readContract({
          address: context.contracts.earnVault,
          abi: earnVaultAbi,
          functionName: 'totalEarnShares',
        })
      const supplyBefore = await totalEarnShares()
      const unavailable = await fundRewards(context, {
        funder: '0x0000000000000000000000000000000000000001',
        requestedAssets: REWARD,
        approveFunder: false,
      })
      assert(unavailable.funded === 0n, 'unavailable provider unexpectedly funded rewards')
      assert(
        (await totalEarnShares()) === supplyBefore,
        'failed reward attempt changed EarnShare supply',
      )

      const valueBeforeFunding = await previewEarnRedeem(context, setup.earnShares)
      const funded = await fundRewards(context, {
        funder: context.user.address,
        requestedAssets: REWARD,
      })
      assert(funded.funded === REWARD, 'resumed reward controller did not fully fund')
      assertValueNotReducedBeyondOneBasisPoint(
        await previewEarnRedeem(context, setup.earnShares),
        valueBeforeFunding,
        'reward funding reduced holder value',
      )
      await redeem(context, { earnShares: setup.earnShares, receiver: context.user.address })
    },
  },
]
