import { Abis } from 'viem/tempo'
import type { Address } from 'viem'
import { accrueFees, deposit, redeem } from '../../harness/support/public.js'
import { contributeDirectly } from '../rewards/actions.js'
import { mintVaultAsset, tokenBalance } from '../../harness/support/funding.js'
import { previewEarnRedeem } from '../../harness/support/slippage.js'
import { expectRevertedWrite, write } from '../../harness/support/transactions.js'
import { assert, assertValueNotReducedBeyondOneBasisPoint } from '../../harness/support/utils.js'
import type { E2eCase, LaunchFeature } from '../../harness/case.js'
import type { E2eContext } from '../../harness/context.js'

const DEPOSIT = 1_000_000n
const GROWTH = 100_000n

function claimable(context: E2eContext, account: Address) {
  return context.l1Public.readContract({
    address: context.contracts.earnFees,
    abi: Abis.earnFees,
    functionName: 'claimableEarnShares',
    args: [account],
  })
}

export const launchFeatures: Record<string, LaunchFeature> = {
  fees: {
    dimensions: ['positive', 'negative', 'rollback'],
    applies: ({ feesActive }) => feesActive,
  },
}

export const cases: readonly E2eCase[] = [
  {
    id: 'fees-waterfall',
    requiresActiveFees: true,
    description:
      'Contributed growth applies the configured fee waterfall without reducing holder value, its recipient claims exactly its ledger, and claims without or above a ledger roll back.',
    default: false,
    launch: true,
    coverage: { fees: ['positive', 'negative', 'rollback'] },
    async run(context) {
      const { earnFees, earnShare } = context.contracts
      const recipients = [context.operator.address, context.operations.revenueShareRecipient]
      await mintVaultAsset(context, DEPOSIT + GROWTH)
      const position = await deposit(context, { assets: DEPOSIT, receiver: context.user.address })
      const holderValueBefore = await previewEarnRedeem(context, position.earnShares)
      const feesBefore = await Promise.all(recipients.map((account) => claimable(context, account)))

      await contributeDirectly(context, { assets: GROWTH })
      const projectedValue = await previewEarnRedeem(context, position.earnShares)
      assertValueNotReducedBeyondOneBasisPoint(
        projectedValue,
        holderValueBefore,
        'configured waterfall reduced holder value',
      )
      await accrueFees(context)
      assert(
        (await previewEarnRedeem(context, position.earnShares)) === projectedValue,
        'fee-aware preview changed when fees crystallized',
      )
      const feesAfter = await Promise.all(recipients.map((account) => claimable(context, account)))
      const accrued = feesAfter.map((after, index) => after - feesBefore[index]!)
      assert(
        accrued.some((delta) => delta > 0n),
        'configured recipients accrued no fee EarnShare',
      )

      // The operator signs its own claim; otherwise the revenue-share recipient is the E2E user.
      const [claimant, wallet] =
        accrued[0]! > 0n
          ? [context.operator.address, context.actors.operator.wallet]
          : [context.operations.revenueShareRecipient, context.actors.user.wallet]
      const claim = accrued[0]! > 0n ? accrued[0]! : accrued[1]!
      const claimedBefore = await tokenBalance(context, earnShare, claimant)
      await write(wallet, {
        address: earnFees,
        abi: Abis.earnFees,
        functionName: 'claim',
        args: [claimant, claim],
      })
      assert(
        (await tokenBalance(context, earnShare, claimant)) - claimedBefore === claim,
        'fee recipient claim transferred the wrong amount',
      )

      const ledgerState = () =>
        Promise.all([
          tokenBalance(context, earnShare, earnFees),
          tokenBalance(context, earnShare, context.outsider.address),
          tokenBalance(context, earnShare, context.operator.address),
          claimable(context, context.outsider.address),
          claimable(context, context.operator.address),
        ])
      const before = await ledgerState()
      assert(before[3] === 0n, 'ordinary account unexpectedly has claimable fee EarnShare')
      await expectRevertedWrite(
        context,
        () =>
          context.actors.outsider.wallet.writeContract({
            address: earnFees,
            abi: Abis.earnFees,
            functionName: 'claim',
            args: [context.outsider.address, 1n],
          }),
        'account without fees unexpectedly claimed a fee share',
      )
      await expectRevertedWrite(
        context,
        () =>
          context.actors.operator.wallet.writeContract({
            address: earnFees,
            abi: Abis.earnFees,
            functionName: 'claim',
            args: [context.operator.address, before[4] + 1n],
          }),
        'fee recipient unexpectedly overclaimed its ledger',
      )
      const after = await ledgerState()
      assert(
        after.every((value, index) => value === before[index]),
        'rejected fee claims moved fee EarnShare or changed a ledger',
      )
      await redeem(context, { earnShares: position.earnShares, receiver: context.user.address })
    },
  },
]
