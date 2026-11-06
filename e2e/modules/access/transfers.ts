import { encodeFunctionData, erc20Abi, type Address } from 'viem'

import { deposit, redeem, withdrawExact } from '../../harness/support/public.js'
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
  withEarnShareAllowance,
  withOutsiderEligibility,
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
      await withOutsiderEligibility(context, true, async () => {
        await mintVaultAsset(context, 2n * DEPOSIT)
        const position = await deposit(context, {
          assets: DEPOSIT,
          receiver: context.user.address,
        })
        const before = await tokenBalance(
          context,
          context.contracts.earnShare,
          context.outsider.address,
        )
        const direct = position.earnShares / 2n
        const delegated = position.earnShares - direct
        await sendEarnShareCall(context, 'user', transfer(context.outsider.address, direct))
        await withEarnShareAllowance(context, context.outsider.address, delegated, () =>
          sendEarnShareCall(
            context,
            'outsider',
            encodeFunctionData({
              abi: erc20Abi,
              functionName: 'transferFrom',
              args: [context.user.address, context.outsider.address, delegated],
            }),
          ),
        )
        const received = await tokenBalance(
          context,
          context.contracts.earnShare,
          context.outsider.address,
        )
        assert(
          received - before === position.earnShares,
          'eligible transfer paths delivered the wrong EarnShare amount',
        )
        await redeem(context, {
          actor: 'outsider',
          earnShares: position.earnShares,
          receiver: context.outsider.address,
        })
        await setOutsiderEligibility(context, false)

        const rejected = await deposit(context, {
          assets: DEPOSIT,
          receiver: context.user.address,
        })
        const transferAmount = rejected.earnShares / 2n
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
            submitEarnShareCall(
              context,
              'user',
              transfer(context.outsider.address, transferAmount),
            ),
          'direct transfer to ineligible recipient unexpectedly succeeded',
        )
        await withEarnShareAllowance(
          context,
          context.operator.address,
          transferAmount,
          async () => {
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
            assert(
              (await allowance()) === allowanceBefore,
              'rejected transferFrom consumed allowance',
            )
            await redeem(context, {
              earnShares: rejected.earnShares,
              receiver: context.user.address,
            })
          },
        )
      })
    },
  },
  {
    id: 'access-removed-holder',
    requiredCapabilities: ['redeem'],
    description:
      'A removed holder keeps its contribution-backed position, cannot transfer, deposit, or exit, then recovers exact withdrawal and redemption after re-admission.',
    default: false,
    launch: true,
    coverage: {
      'access-policy': ['recovery'],
      'immediate-redeem': ['recovery'],
      'exact-withdraw': ['recovery'],
    },
    preflight: protectedAccess,
    async run(context) {
      await withOutsiderEligibility(context, true, async () => {
        const initialShares = await tokenBalance(
          context,
          context.contracts.earnShare,
          context.outsider.address,
        )
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
          // A 100% excess-return fee can consume the contribution, but not existing holder value.
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
          // A separate receiver keeps fee-token gas out of the measured asset delta.
          const receiver = context.user.address
          if (context.deployment.capabilities.exactWithdraw) {
            const assets = valueAfter / 3n
            assert(
              assets > 0n && earnShares > 0n,
              'recovery requires nonzero assets and share bound',
            )
            await expectRevertedWrite(
              context,
              () =>
                earn.withdrawExact({
                  account: context.outsider,
                  assetAmount: assets,
                  recipient: receiver,
                  shareAmountMax: earnShares,
                  vault: context.contracts.earnVault,
                }),
              'removed holder unexpectedly completed an exact withdrawal',
            )
          }
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
              initialShares + earnShares,
            'rejected transfer and exits changed the removed holder balance',
          )
          await setOutsiderEligibility(context, true)
          const assetsBefore = await tokenBalance(context, context.assets.base, receiver)
          const remaining = await (async () => {
            if (!context.deployment.capabilities.exactWithdraw) return earnShares
            const assets = valueAfter / 3n
            assert(
              assets > 0n && earnShares > 0n,
              'recovery requires nonzero assets and share bound',
            )
            const recovered = await withdrawExact(context, {
              actor: 'outsider',
              assets,
              maxEarnShares: earnShares,
              receiver,
            })
            const [assetsAfter, sharesAfter] = await Promise.all([
              tokenBalance(context, context.assets.base, receiver),
              tokenBalance(context, context.contracts.earnShare, context.outsider.address),
            ])
            const burned = initialShares + earnShares - sharesAfter
            assert(
              assetsAfter - assetsBefore === assets,
              'recovered exact withdrawal delivered the wrong assets',
            )
            assert(
              burned > 0n && burned <= earnShares,
              'recovered exact withdrawal violated its share bound',
            )
            assert(
              burned === recovered.earnSharesBurned,
              'recovered exact withdrawal burn differs from its event',
            )
            return earnShares - burned
          })()
          assert(remaining > 0n, 'exact withdrawal left no position to prove redeem recovery')
          const assetsBeforeRedeem = await tokenBalance(context, context.assets.base, receiver)
          await redeem(context, {
            actor: 'outsider',
            earnShares: remaining,
            receiver,
          })
          assert(
            (await tokenBalance(context, context.contracts.earnShare, context.outsider.address)) ===
              initialShares,
            'recovered redemption did not burn the remaining test position',
          )
          assert(
            (await tokenBalance(context, context.assets.base, receiver)) > assetsBeforeRedeem,
            'recovered redemption delivered no assets',
          )
        } finally {
          // Recovery assertions belong above; cleanup only returns this case's residual position.
          await setOutsiderEligibility(context, true)
          const remaining = await tokenBalance(
            context,
            context.contracts.earnShare,
            context.outsider.address,
          )
          if (remaining > initialShares) {
            await redeem(context, {
              actor: 'outsider',
              earnShares: remaining - initialShares,
              receiver: context.outsider.address,
            })
          }
        }
      })
    },
  },
]
