import { erc20Abi } from 'viem'
import { Abis, Addresses } from 'viem/tempo'

import type { E2eCase } from '../../harness/case.js'
import { requireE2eZone, type E2eContext } from '../../harness/context.js'
import { redeem } from '../../harness/support/public.js'
import { expectContractRevert } from '../../harness/support/transactions.js'
import {
  assert,
  E2ePrerequisiteError,
  TIMEOUT_MS,
  ZONE_CASE_AMOUNT,
} from '../../harness/support/utils.js'
import { readAccessStatus } from '@tempoxyz/earn/deployments/operations'
import { protectedAccessConfiguration } from '../access/shared.js'
import {
  refundsToSelf,
  zoneBalance,
  zoneDeposit,
  zoneDepositExpectRecipientBounce,
  zoneRedeem,
} from './actions.js'
import { ensureZoneReady } from './readiness.js'

const AMOUNT = ZONE_CASE_AMOUNT

/** The protected policy is live, the user is eligible, and the outsider stays ineligible. */
async function requireProtectedZoneAccess(context: E2eContext) {
  requireE2eZone(context)
  await ensureZoneReady(context)
  const { access } = protectedAccessConfiguration(context)
  const policyId = BigInt(access.transferPolicyId)
  const registry = { address: Addresses.tip403Registry, abi: Abis.tip403Registry } as const
  const [policy, eligibleUser, outsider] = await Promise.all([
    context.l1Public.readContract({ ...registry, functionName: 'policyData', args: [policyId] }),
    context.l1Public.readContract({
      ...registry,
      functionName: 'isAuthorized',
      args: [policyId, context.user.address],
    }),
    readAccessStatus(context.l1Public, context.deployment, context.outsider.address),
  ])
  if (policy[0] !== 0 || !eligibleUser) {
    throw new E2ePrerequisiteError('L1 does not expose the protected EarnShare policy')
  }
  if (outsider.eligible) {
    throw new E2ePrerequisiteError(
      `Protected Zone negative tests require outsider ${context.outsider.address} to remain ineligible`,
    )
  }
  context.progress.step(
    'CHECK',
    'protected policy is live and test identities are correctly scoped',
  )
}

/** Zone cases that need EarnShare's protected TIP-403 policy mirrored into the Zone. */
export const protectedZoneCases: readonly E2eCase[] = [
  {
    id: 'zone-ineligible-private-transfer-blocked',
    description:
      'Zone policy mirroring rejects a private EarnShare transfer to an ineligible account without changing balances.',
    flow: 'EarnShare (private) → ineligible recipient ✕ · balances unchanged',
    default: true,
    launch: true,
    requiredCapabilities: ['privateRouting'],
    requiresProtectedAccess: true,
    coverage: { 'private-router': ['negative'] },
    weight: 6,
    preflight: requireProtectedZoneAccess,
    async run(context) {
      requireE2eZone(context)
      const entry = await zoneDeposit(context, { amount: AMOUNT })
      const balances = () =>
        Promise.all([
          zoneBalance(context, context.contracts.earnShare, 'user'),
          zoneBalance(context, context.contracts.earnShare, 'outsider'),
        ])
      const [userBefore, outsiderBefore] = await balances()
      const zoneClient = context.actors.user.zone.client
      await expectContractRevert(async () => {
        const hash = await zoneClient.writeContract({
          address: context.contracts.earnShare,
          abi: erc20Abi,
          functionName: 'transfer',
          args: [context.outsider.address, 1n],
        })
        const receipt = await zoneClient.waitForTransactionReceipt({ hash, timeout: TIMEOUT_MS })
        assert(receipt.status === 'success', `private transaction ${hash} reverted`)
      }, 'private transfer to ineligible recipient unexpectedly succeeded')
      const [userAfter, outsiderAfter] = await balances()
      assert(userAfter === userBefore, 'rejected private transfer changed sender balance')
      assert(
        outsiderAfter === outsiderBefore,
        'rejected private transfer changed recipient balance',
      )
      context.progress.step('CHECK', 'ineligible private transfer rejected; balances unchanged')
      await zoneRedeem(context, { earnShares: entry.earnShares })
    },
  },
  ineligibleRecipientBounceCase(),
]

function ineligibleRecipientBounceCase(): E2eCase {
  let publicRefund = 0n
  return {
    id: 'zone-ineligible-private-deposit-bounces',
    description:
      'A private deposit for an ineligible recipient returns the net EarnShare after Zone bounce fees to the eligible initiator without crediting the recipient.',
    flow: 'private asset → EarnShare → ineligible recipient ✕ → public EarnShare refund',
    default: true,
    launch: true,
    requiredCapabilities: ['privateRouting'],
    requiresProtectedAccess: true,
    coverage: { 'private-router': ['negative', 'rollback'] },
    weight: 6,
    async preflight(context) {
      await requireProtectedZoneAccess(context)
      // The bounce refund must return to the initiator so cleanup can reclaim it publicly.
      if (!(await refundsToSelf(context, context.user.address))) {
        throw new E2ePrerequisiteError(
          'Bounce refunds need an admitted E2E user; delegated refund custody cannot be reclaimed',
        )
      }
    },
    async run(context) {
      publicRefund = 0n
      const result = await zoneDepositExpectRecipientBounce(context, {
        amount: AMOUNT,
        recipient: 'outsider',
      })
      publicRefund = result.refundedEarnShares
    },
    async cleanup(context) {
      if (publicRefund === 0n) return
      const earnShares = publicRefund
      publicRefund = 0n
      await redeem(context, { earnShares, receiver: context.user.address })
    },
  }
}
