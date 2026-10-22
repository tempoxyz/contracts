import type { E2eBenchmark, E2eCase, E2eModule, LaunchFeature } from '../../harness/case.js'
import { assert, ZONE_CASE_AMOUNT } from '../../harness/support/utils.js'
import { protectedZoneCases } from './access.js'
import {
  fundPrivateFeeBuffer,
  fundPrivateInput,
  requireSelfRefunds,
  zoneDeposit,
  zoneDepositExpectBounce,
  zoneRedeem,
} from './actions.js'
import {
  migrateExistingVenueSharesToZone,
  migrateMorphoFeeWrapperToPrivateEarn,
  requireMorphoFeeWrapperMigration,
} from './migration.js'
import { routerIntegrity, validateRouter } from './router.js'

const AMOUNT = ZONE_CASE_AMOUNT

export const validate: E2eModule['validate'] = validateRouter
export const integrity: E2eModule['integrity'] = routerIntegrity

export const launchFeatures: Record<string, LaunchFeature> = {
  'public-to-private-migration': {
    dimensions: ['positive', 'recovery'],
    applies: ({ capabilities }) => capabilities.inKindDeposit && capabilities.privateRouting,
  },
  'private-router': {
    dimensions: ['positive', 'negative', 'rollback', 'recovery', 'third-party'],
    applies: ({ capabilities }) => capabilities.privateRouting,
  },
}

function thirdPartyRecipientCase(): E2eCase {
  let unredeemed: bigint | undefined
  return {
    id: 'zone-third-party-recipient',
    description:
      'Swap the private asset into EarnShare for another private recipient, which redeems it back to the depositor.',
    flow: 'private asset → EarnShare (private recipient) → private asset (depositor)',
    default: false,
    launch: true,
    requiredCapabilities: ['privateRouting'],
    coverage: { 'private-router': ['third-party'] },
    weight: 6,
    // The recipient redeems as itself, so its router returns must refund to it.
    preflight: (context) => requireSelfRefunds(context, ['operator']),
    async run(context) {
      unredeemed = undefined
      const entry = await zoneDeposit(context, {
        amount: AMOUNT,
        recipient: 'operator',
      })
      assert(entry.earnShares > 0n, 'third-party Zone deposit minted no EarnShare')
      unredeemed = entry.earnShares
      const exit = await zoneRedeem(context, {
        owner: 'operator',
        earnShares: entry.earnShares,
        recipient: 'user',
      })
      unredeemed = undefined
      assert(exit.outputAmount > 0n, 'third-party Zone redemption returned no assets')
    },
    async cleanup(context) {
      if (unredeemed === undefined) return
      const earnShares = unredeemed
      unredeemed = undefined
      await zoneRedeem(context, {
        owner: 'operator',
        earnShares,
        recipient: 'user',
      })
    },
  }
}

export const cases: readonly E2eCase[] = [
  {
    id: 'migration-existing-vault-shares-to-zone',
    description:
      'Atomically move existing venue shares into private EarnShare, then redeem them privately.',
    default: false,
    launch: true,
    requiredCapabilities: ['inKindDeposit', 'privateRouting'],
    coverage: {
      'public-to-private-migration': ['positive', 'recovery'],
    },
    async run(context) {
      const result = await migrateExistingVenueSharesToZone(context)
      assert(result.venueShares > 0n, 'Migration moved no venue shares')
      assert(result.earnShares > 0n, 'Migration returned no private EarnShare')
      const exit = await zoneRedeem(context, { earnShares: result.earnShares })
      assert(exit.outputAmount > 0n, 'Migrated EarnShare could not redeem privately')
    },
  },
  {
    id: 'migration-morpho-fee-wrapper-to-private-earn',
    requiredEngineHooks: ['morphoFeeWrapper'],
    environments: ['local'],
    description:
      'Atomically replace the Morpho fee wrapper with private EarnShare while keeping the same Morpho vault.',
    default: false,
    launch: false,
    requiredCapabilities: ['inKindDeposit', 'privateRouting'],
    preflight(context) {
      requireMorphoFeeWrapperMigration(context)
    },
    async run(context) {
      const result = await migrateMorphoFeeWrapperToPrivateEarn(context)
      assert(result.morphoFeeShares > 0n, 'Migration burned no Morpho fee-wrapper shares')
      assert(result.earnShares > 0n, 'Migration returned no private EarnShare')
      const exit = await zoneRedeem(context, { earnShares: result.earnShares })
      assert(exit.outputAmount > 0n, 'Replacement private EarnShare could not be redeemed')
    },
  },
  {
    id: 'zone-lifecycle-swapped',
    description:
      "Swap the router's private asset into EarnShare returned to the same Zone, then swap the private redemption back.",
    flow: 'private asset → router swap → EarnVault → EarnShare (private) → private asset',
    default: true,
    launch: true,
    requiredCapabilities: ['privateRouting'],
    coverage: { 'private-router': ['positive'] },
    weight: 8,
    async run(context) {
      const entry = await zoneDeposit(context, { amount: AMOUNT })
      assert(entry.earnShares > 0n, 'swapped Zone entry minted no EarnShare')
      const exit = await zoneRedeem(context, { earnShares: entry.earnShares })
      assert(exit.outputAmount > 0n, 'swapped Zone lifecycle returned no assets')
    },
  },
  thirdPartyRecipientCase(),
  {
    id: 'zone-swap-slippage-bounces',
    description:
      'A private swapped deposit that cannot meet its output bound bounces its private input back without changing public Earn supply or backing.',
    flow: 'private asset → swap below minimum ✕ → input bounced · backing unchanged',
    default: false,
    launch: true,
    requiredCapabilities: ['privateRouting'],
    coverage: { 'private-router': ['negative', 'rollback', 'recovery'] },
    weight: 6,
    async run(context) {
      await zoneDepositExpectBounce(context, {
        amount: AMOUNT,
        minimumVaultAssetsOverride: (1n << 128n) - 1n,
      })
    },
  },
  ...protectedZoneCases,
]

export const benchmark: E2eBenchmark = {
  roundTrip: {
    group: 'private',
    async sample(context, measure) {
      assert(context.deployment.network.zone !== undefined, 'Private benchmark fixture has no Zone')
      await fundPrivateInput(context, AMOUNT)
      await fundPrivateFeeBuffer(context)
      const entry = await measure('zone-deposit', async () => {
        const result = await zoneDeposit(context, {
          amount: AMOUNT,
          funded: true,
        })
        assert(result.earnShares > 0n, 'Zone benchmark deposit minted no EarnShare')
        return result
      })
      await fundPrivateFeeBuffer(context)
      await measure('zone-redeem', async () => {
        const result = await zoneRedeem(context, {
          earnShares: entry.earnShares,
          funded: true,
        })
        assert(result.outputAmount > 0n, 'Zone benchmark redeem returned no assets')
      })
    },
  },
}
