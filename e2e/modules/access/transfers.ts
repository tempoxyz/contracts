import { encodeFunctionData, erc20Abi, type Address } from 'viem'

import { deposit, redeem } from '../../harness/support/public.js'
import { contributeDirectly } from '../rewards/actions.js'
import { mintVaultAsset, tokenBalance } from '../../harness/support/funding.js'
import {
  minimumOutput,
  previewEarnDeposit,
  previewEarnRedeem,
} from '../../harness/support/slippage.js'
import { expectRevertedWrite } from '../../harness/support/transactions.js'
import { assert, assertValueNotReducedBeyondOneBasisPoint } from '../../harness/support/utils.js'
import type { E2eCase } from '../../harness/case.js'
import {
  DEPOSIT,
  REWARD,
  protectedAccess,
  sendEarnShareCall,
  setOutsiderEligibility,
  submitEarnShareCall,
} from './shared.js'

const transfer = (to: Address, amount: bigint) =>
  encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [to, amount] })

export const accessTransferCases: readonly E2eCase[] = [
  {
    id: 'access-transfer-policy',
    description:
      'Direct and delegated EarnShare transfers succeed between eligible accounts and revert to an ineligible account without changing balances or allowance.',
    default: true,
    launch: true,
    coverage: { 'access-policy': ['positive', 'negative', 'rollback'] },
    preflight: protectedAccess,
    async run(context) {
      await mintVaultAsset(context, 2n * DEPOSIT)
      await setOutsiderEligibility(context, true)
      try {
        const position = await deposit(context, {
          assets: DEPOSIT,
          receiver: context.user.address,
        })
        const direct = position.earnShares / 2n
        const delegated = position.earnShares - direct
        await sendEarnShareCall(context, 'user', transfer(context.outsider.address, direct))
        await sendEarnShareCall(
          context,
          'user',
          encodeFunctionData({
            abi: erc20Abi,
            functionName: 'approve',
            args: [context.outsider.address, delegated],
          }),
        )
        await sendEarnShareCall(
          context,
          'outsider',
          encodeFunctionData({
            abi: erc20Abi,
            functionName: 'transferFrom',
            args: [context.user.address, context.outsider.address, delegated],
          }),
        )
        const received = await tokenBalance(
          context,
          context.contracts.earnShare,
          context.outsider.address,
        )
        assert(
          received >= position.earnShares,
          'eligible transfer paths delivered too little EarnShare',
        )
        await redeem(context, {
          actor: 'outsider',
          earnShares: position.earnShares,
          receiver: context.outsider.address,
        })
      } finally {
        await setOutsiderEligibility(context, false)
      }

      const position = await deposit(context, {
        assets: DEPOSIT,
        receiver: context.user.address,
      })
      const transferAmount = position.earnShares / 2n
      const allowance = () =>
        context.l1Public.readContract({
          address: context.contracts.earnShare,
          abi: erc20Abi,
          functionName: 'allowance',
          args: [context.user.address, context.operator.address],
        })
      const balances = () =>
        Promise.all([
          tokenBalance(context, context.contracts.earnShare, context.user.address),
          tokenBalance(context, context.contracts.earnShare, context.outsider.address),
        ])
      const [userBefore, outsiderBefore] = await balances()
      await expectRevertedWrite(
        context,
        () =>
          submitEarnShareCall(context, 'user', transfer(context.outsider.address, transferAmount)),
        'direct transfer to ineligible recipient unexpectedly succeeded',
      )
      await sendEarnShareCall(
        context,
        'user',
        encodeFunctionData({
          abi: erc20Abi,
          functionName: 'approve',
          args: [context.operator.address, transferAmount],
        }),
      )
      const allowanceBefore = await allowance()
      await expectRevertedWrite(
        context,
        () =>
          submitEarnShareCall(
            context,
            'operator',
            encodeFunctionData({
              abi: erc20Abi,
              functionName: 'transferFrom',
              args: [context.user.address, context.outsider.address, transferAmount],
            }),
          ),
        'delegated transfer to ineligible recipient unexpectedly succeeded',
      )
      const [userAfter, outsiderAfter] = await balances()
      assert(userAfter === userBefore, 'rejected transfer changed sender balance')
      assert(outsiderAfter === outsiderBefore, 'rejected transfer changed receiver balance')
      assert((await allowance()) === allowanceBefore, 'rejected transferFrom consumed allowance')
      await redeem(context, { earnShares: position.earnShares, receiver: context.user.address })
    },
  },
  {
    id: 'access-removed-holder',
    description:
      'A removed holder keeps a position whose value contributions do not reduce, but cannot transfer, deposit, or exit until it is re-added.',
    default: false,
    launch: true,
    coverage: {
      'access-policy': ['recovery'],
      'immediate-redeem': ['recovery'],
      'exact-withdraw': ['recovery'],
    },
    preflight: protectedAccess,
    async run(context) {
      await setOutsiderEligibility(context, true)
      try {
        await mintVaultAsset(context, DEPOSIT * 2n, 'outsider')
        const { earnShares } = await deposit(context, {
          actor: 'outsider',
          assets: DEPOSIT,
          receiver: context.outsider.address,
        })
        const valueBefore = await previewEarnRedeem(context, earnShares)
        await setOutsiderEligibility(context, false)
        await mintVaultAsset(context, REWARD, 'operator')
        await contributeDirectly(context, { assets: REWARD, actor: 'operator' })
        const valueAfter = await previewEarnRedeem(context, earnShares)
        // A configured 100% excess-return fee may consume the complete immediate contribution.
        // Eligibility removal must still leave the holder's fee-aware redemption value intact.
        assertValueNotReducedBeyondOneBasisPoint(
          valueAfter,
          valueBefore,
          'contribution accounting reduced the removed holder value',
        )
        const earn = context.actors.outsider.wallet.earn
        await expectRevertedWrite(
          context,
          () =>
            submitEarnShareCall(context, 'outsider', transfer(context.user.address, earnShares)),
          'removed holder unexpectedly transferred EarnShare',
        )
        const minimumEarnShares = minimumOutput(await previewEarnDeposit(context, DEPOSIT))
        await expectRevertedWrite(
          context,
          () =>
            earn.deposit({
              account: context.outsider,
              assetAmount: DEPOSIT,
              recipient: context.outsider.address,
              shareAmountMin: minimumEarnShares,
              vault: context.contracts.earnVault,
            }),
          'removed holder unexpectedly deposited again',
        )
        await expectRevertedWrite(
          context,
          () =>
            earn.withdrawExact({
              account: context.outsider,
              assetAmount: valueAfter / 3n,
              recipient: context.outsider.address,
              shareAmountMax: earnShares,
              vault: context.contracts.earnVault,
            }),
          'removed holder unexpectedly completed an exact withdrawal',
        )
        await expectRevertedWrite(
          context,
          () =>
            earn.redeem({
              account: context.outsider,
              assetAmountMin: minimumOutput(valueAfter),
              recipient: context.outsider.address,
              shareAmount: earnShares,
              vault: context.contracts.earnVault,
            }),
          'removed holder unexpectedly redeemed',
        )
        assert(
          (await tokenBalance(context, context.contracts.earnShare, context.outsider.address)) ===
            earnShares,
          'rejected transfer and exits changed the removed holder balance',
        )
      } finally {
        // Re-adding the holder restores its exit; later cases rely on it ending ineligible.
        await setOutsiderEligibility(context, true)
        try {
          const remaining = await tokenBalance(
            context,
            context.contracts.earnShare,
            context.outsider.address,
          )
          if (remaining > 0n) {
            await redeem(context, {
              actor: 'outsider',
              earnShares: remaining,
              receiver: context.outsider.address,
            })
          }
        } finally {
          await setOutsiderEligibility(context, false)
        }
      }
    },
  },
]
