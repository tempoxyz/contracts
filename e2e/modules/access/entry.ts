import type { Hash } from 'viem'
import { deposit, depositIntoVenue, expectUnchanged, redeem } from '../../harness/support/public.js'
import { contributeDirectly } from '../rewards/actions.js'
import { earnVaultAbi } from '@tempoxyz/earn/abis'
import { mintVaultAsset, tokenBalance } from '../../harness/support/funding.js'
import {
  minimumOutput,
  previewEarnDeposit,
  previewEarnRedeem,
} from '../../harness/support/slippage.js'
import { expectRevertedWrite } from '../../harness/support/transactions.js'
import { assert, assertValueNotReducedBeyondOneBasisPoint } from '../../harness/support/utils.js'
import type { E2eCase } from '../../harness/case.js'
import type { E2eContext } from '../../harness/context.js'
import { DEPOSIT, REWARD, protectedAccess, setOutsiderEligibility } from './shared.js'

/** Requires `reject` to revert without changing the outsider's position or the vault's backing. */
function expectOutsiderUnchanged(context: E2eContext, label: string, reject: () => Promise<Hash>) {
  return expectUnchanged(
    context,
    label,
    () =>
      expectRevertedWrite(
        context,
        reject,
        `${label} unexpectedly minted to an ineligible receiver`,
      ),
    { owners: [context.outsider.address] },
  )
}

export const accessEntryCases: readonly E2eCase[] = [
  {
    id: 'access-receiver-policy',
    description:
      'Eligibility applies to the EarnShare receiver: an ineligible receiver cannot be minted EarnShare by itself, an eligible funder, or in-kind entry, while an ineligible funder can sponsor an eligible account.',
    default: false,
    launch: true,
    coverage: { 'access-policy': ['positive', 'negative', 'rollback', 'third-party'] },
    preflight: protectedAccess,
    async run(context) {
      await setOutsiderEligibility(context, false)
      await mintVaultAsset(context, 3n * DEPOSIT, 'outsider')
      await mintVaultAsset(context, DEPOSIT)
      const minEarnShares = minimumOutput(await previewEarnDeposit(context, DEPOSIT))
      const depositTo = (actor: 'outsider' | 'user') => () =>
        context.actors[actor].wallet.earn.deposit({
          account: context[actor],
          assetAmount: DEPOSIT,
          recipient: context.outsider.address,
          shareAmountMin: minEarnShares,
          vault: context.contracts.earnVault,
        })
      await expectOutsiderUnchanged(context, 'ineligible deposit', depositTo('outsider'))
      await expectOutsiderUnchanged(context, 'sponsored ineligible deposit', depositTo('user'))

      if (context.deployment.capabilities.inKindDeposit) {
        const venue = await depositIntoVenue(context, {
          actor: 'outsider',
          assets: DEPOSIT,
          receiver: context.outsider.address,
        })
        const expectedEarnShares = await context.l1Public.readContract({
          address: context.contracts.earnVault,
          abi: earnVaultAbi,
          functionName: 'convertEngineSharesToEarnShares',
          args: [venue.venueShares],
        })
        await expectOutsiderUnchanged(context, 'ineligible in-kind deposit', () =>
          context.actors.outsider.wallet.earn.depositShares({
            account: context.outsider,
            earnShareAmountMin: minimumOutput(expectedEarnShares),
            recipient: context.outsider.address,
            vault: context.contracts.earnVault,
            venueShareAmount: venue.venueShares,
            venueShareToken: context.contracts.venue,
          }),
        )
      }

      const sponsored = await deposit(context, {
        actor: 'outsider',
        assets: DEPOSIT,
        receiver: context.user.address,
      })
      assert(sponsored.earnShares > 0n, 'sponsored deposit minted no EarnShare')
      await redeem(context, { earnShares: sponsored.earnShares, receiver: context.user.address })
    },
  },
  {
    id: 'access-ineligible-contributor-does-not-earn',
    description:
      'An ineligible account may add backing through a permissionless contribution but receives no EarnShare or reward position.',
    default: true,
    launch: true,
    coverage: {
      'access-policy': ['negative'],
      rewards: ['negative'],
    },
    preflight: protectedAccess,
    async run(context) {
      await setOutsiderEligibility(context, false)
      await mintVaultAsset(context, DEPOSIT)
      const position = await deposit(context, {
        assets: DEPOSIT,
        receiver: context.user.address,
      })
      const eligibleValueBefore = await previewEarnRedeem(context, position.earnShares)
      const outsiderSharesBefore = await tokenBalance(
        context,
        context.contracts.earnShare,
        context.outsider.address,
      )
      await mintVaultAsset(context, REWARD, 'outsider')
      const contribution = await contributeDirectly(context, {
        assets: REWARD,
        actor: 'outsider',
      })
      const [eligibleValueAfter, outsiderSharesAfter] = await Promise.all([
        previewEarnRedeem(context, position.earnShares),
        tokenBalance(context, context.contracts.earnShare, context.outsider.address),
      ])
      assert(contribution.earnShareBalanceDelta === 0n, 'contributor received EarnShare')
      assert(
        outsiderSharesAfter === outsiderSharesBefore,
        'ineligible contributor gained an EarnShare position',
      )
      assert(contribution.engineShares > 0n, 'contribution added no managed engine backing')
      assertValueNotReducedBeyondOneBasisPoint(
        eligibleValueAfter,
        eligibleValueBefore,
        'contribution reduced the eligible holder position',
      )
      await redeem(context, { earnShares: position.earnShares, receiver: context.user.address })
    },
  },
]
