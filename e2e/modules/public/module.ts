import { BaseError, ContractFunctionRevertedError, maxUint256, type Hash } from 'viem'
import { simulateCalls } from 'viem/actions'
import {
  deposit,
  depositIntoVenue,
  depositVenueShares,
  expectUnchanged,
  redeem,
  redeemVenueShares,
  withdrawExact,
} from '../../harness/support/public.js'
import { earnVaultAbi } from '@tempoxyz/contracts/abis'
import { mintVaultAsset, tokenBalance } from '../../harness/support/funding.js'
import { previewEarnDeposit, previewEarnRedeem } from '../../harness/support/slippage.js'
import { expectRevertedWrite } from '../../harness/support/transactions.js'
import { assert } from '../../harness/support/utils.js'
import { e2eEngines } from '../../engines/index.js'
import type { E2eBenchmark, E2eCase, LaunchFeature } from '../../harness/case.js'
import type { E2eContext } from '../../harness/context.js'
import { accessKeyCase } from './access-keys.js'

const DEPOSIT = 1_000_000n
const WITHDRAW = 400_000n

/** Requires `reject` to revert without changing the user's position or the vault's backing. */
function expectRollback(context: E2eContext, label: string, reject: () => Promise<Hash>) {
  return expectUnchanged(
    context,
    label,
    () => expectRevertedWrite(context, reject, `${label} unexpectedly ignored its bound`),
    { owners: [context.user.address] },
  )
}

function previewWithdraw(context: E2eContext, assets: bigint) {
  return context.l1Public.readContract({
    address: context.contracts.earnVault,
    abi: earnVaultAbi,
    functionName: 'previewWithdraw',
    args: [assets],
  })
}

const protectedRecovery = ['recovery'] as const

/** Restoring a removed holder's exit is recovery, so it applies only under protected access. */
export const launchFeatures: Record<string, LaunchFeature> = {
  'public-deposit': {
    dimensions: ['positive', 'negative', 'rollback', 'third-party'],
    applies: () => true,
  },
  'in-kind-deposit': {
    dimensions: ['positive', 'negative', 'rollback'],
    applies: ({ capabilities }) => capabilities.inKindDeposit,
  },
  'immediate-redeem': {
    dimensions: ['positive', 'negative', 'rollback', 'third-party'],
    protectedDimensions: protectedRecovery,
    applies: ({ capabilities }) => capabilities.redeem && capabilities.boundedRedeem,
  },
  'exact-withdraw': {
    dimensions: ['positive', 'negative', 'rollback', 'third-party'],
    protectedDimensions: protectedRecovery,
    applies: ({ capabilities }) => capabilities.exactWithdraw,
  },
}

export const cases: readonly E2eCase[] = [
  {
    id: 'public-round-trip',
    description:
      'Deposit vault assets for the depositor and redeem them back, then deposit for another address, which redeems them back to the depositor.',
    default: true,
    launch: true,
    requiredCapabilities: ['redeem'],
    coverage: {
      'public-deposit': ['positive', 'third-party'],
      'immediate-redeem': ['positive', 'third-party'],
    },
    async run(context) {
      await mintVaultAsset(context, 2n * DEPOSIT)
      const entry = await deposit(context, { assets: DEPOSIT, receiver: context.user.address })
      assert(entry.earnShares > 0n, 'deposit minted no EarnShare')
      const [preview, expected] = await Promise.all([
        previewEarnRedeem(context, entry.earnShares),
        e2eEngines[context.engineKind].quoteRedeem(context, entry.earnShares),
      ])
      const exit = await redeem(context, {
        earnShares: entry.earnShares,
        receiver: context.user.address,
      })
      // Previews are conservative valuations; the route quote adds any execution rounding credit.
      assert(exit.assets >= preview, 'redeem returned less than the earnVault preview')
      assert(exit.assets === expected, 'redeem did not return the engine execution quote')

      const receiverBefore = await tokenBalance(
        context,
        context.contracts.earnShare,
        context.operator.address,
      )
      const sponsored = await deposit(context, {
        assets: DEPOSIT,
        receiver: context.operator.address,
      })
      const receiverAfter = await tokenBalance(
        context,
        context.contracts.earnShare,
        context.operator.address,
      )
      assert(
        sponsored.earnShares > 0n && receiverAfter - receiverBefore === sponsored.earnShares,
        'third-party deposit did not mint to its receiver',
      )
      const assetsBefore = await tokenBalance(context, context.assets.base, context.user.address)
      const returned = await redeem(context, {
        actor: 'operator',
        earnShares: sponsored.earnShares,
        receiver: context.user.address,
      })
      const assetsAfter = await tokenBalance(context, context.assets.base, context.user.address)
      assert(assetsAfter - assetsBefore === returned.assets, 'third-party asset delta mismatch')
    },
  },
  {
    id: 'public-bounds-roll-back',
    description:
      'Deposit, in-kind entry, redemption, and exact withdrawal each revert atomically when their output bound cannot be met.',
    default: false,
    launch: true,
    requiredCapabilities: ['redeem'],
    coverage: {
      'public-deposit': ['negative', 'rollback'],
      'in-kind-deposit': ['negative', 'rollback'],
      'immediate-redeem': ['negative', 'rollback'],
      'exact-withdraw': ['negative', 'rollback'],
    },
    async run(context) {
      const { earnVault, venue } = context.contracts
      const earn = context.actors.user.wallet.earn
      await mintVaultAsset(context, 3n * DEPOSIT)

      const expectedEarnShares = await previewEarnDeposit(context, DEPOSIT)
      const depositRequest = {
        assetAmount: DEPOSIT,
        recipient: context.user.address,
        shareAmountMin: expectedEarnShares + 1n,
        vault: earnVault,
      }
      const simulation = await simulateCalls(context.l1Public, {
        account: context.user.address,
        calls: earn.deposit.calls({ ...depositRequest, assetToken: context.assets.base }),
        validation: false,
      })
      const failure = simulation.results.find((result) => result.status === 'failure')
      assert(failure?.error instanceof BaseError, 'deposit simulation returned no viem error')
      const reverted = failure.error.walk((cause) => cause instanceof ContractFunctionRevertedError)
      assert(
        reverted instanceof ContractFunctionRevertedError &&
          reverted.data?.errorName === 'MinimumEarnSharesNotMet',
        'deposit simulation did not decode MinimumEarnSharesNotMet',
      )
      await expectRollback(context, 'deposit', () =>
        earn.deposit({ account: context.user, ...depositRequest }),
      )

      if (context.deployment.capabilities.inKindDeposit) {
        const { venueShares } = await depositIntoVenue(context, {
          assets: DEPOSIT,
          receiver: context.user.address,
        })
        const expectedInKind = await context.l1Public.readContract({
          address: earnVault,
          abi: earnVaultAbi,
          functionName: 'convertEngineSharesToEarnShares',
          args: [venueShares],
        })
        await expectRollback(context, 'in-kind deposit', () =>
          earn.depositShares({
            account: context.user,
            earnShareAmountMin: expectedInKind + 1n,
            recipient: context.user.address,
            vault: earnVault,
            venueShareAmount: venueShares,
            venueShareToken: venue,
          }),
        )
        await redeemVenueShares(context, venueShares)
      }

      const { boundedRedeem, exactWithdraw } = context.deployment.capabilities
      const position = await deposit(context, { assets: DEPOSIT, receiver: context.user.address })
      if (boundedRedeem) {
        // Engine previews may conservatively omit route rounding credit, so use an impossible
        // minimum rather than assuming the preview is an exact execution quote.
        await expectRollback(context, 'redeem', () =>
          earn.redeem({
            account: context.user,
            assetAmountMin: maxUint256,
            recipient: context.user.address,
            shareAmount: position.earnShares,
            vault: earnVault,
          }),
        )
      }
      if (exactWithdraw) {
        const requiredEarnShares = await previewWithdraw(context, WITHDRAW)
        assert(requiredEarnShares > 0n, 'exact withdrawal preview returned zero EarnShare')
        await expectRollback(context, 'exact withdrawal', () =>
          earn.withdrawExact({
            account: context.user,
            assetAmount: WITHDRAW,
            recipient: context.user.address,
            shareAmountMax: requiredEarnShares - 1n,
            vault: earnVault,
          }),
        )
      }
      await redeem(context, { earnShares: position.earnShares, receiver: context.user.address })
    },
  },
  {
    id: 'public-withdraw-exact-third-party',
    description:
      'Withdraw exact asset amounts to the holder and to another address while retaining unused EarnShare.',
    default: false,
    launch: true,
    requiredCapabilities: ['exactWithdraw', 'redeem'],
    coverage: { 'exact-withdraw': ['positive', 'third-party'] },
    async run(context) {
      await mintVaultAsset(context, DEPOSIT)
      const position = await deposit(context, { assets: DEPOSIT, receiver: context.user.address })
      const expectedEarnShares = await previewWithdraw(context, WITHDRAW)
      const own = await withdrawExact(context, {
        assets: WITHDRAW,
        receiver: context.user.address,
        maxEarnShares: expectedEarnShares,
      })
      assert(
        own.earnSharesBurned === expectedEarnShares,
        'exact withdrawal did not match the earnVault preview',
      )
      assert(
        own.earnSharesBurned > 0n && own.earnSharesBurned < position.earnShares,
        'exact withdrawal burned an invalid EarnShare amount',
      )
      const before = await tokenBalance(context, context.assets.base, context.operator.address)
      const other = await withdrawExact(context, {
        assets: WITHDRAW,
        receiver: context.operator.address,
        maxEarnShares: await previewWithdraw(context, WITHDRAW),
      })
      const after = await tokenBalance(context, context.assets.base, context.operator.address)
      assert(after - before === WITHDRAW, 'third-party exact withdrawal delta mismatch')
      await redeem(context, {
        earnShares: position.earnShares - own.earnSharesBurned - other.earnSharesBurned,
        receiver: context.user.address,
      })
    },
  },
  {
    id: 'public-deposit-existing-venue-shares',
    description: 'Convert directly held venue shares into public EarnShare and redeem normally.',
    default: false,
    launch: true,
    requiredCapabilities: ['inKindDeposit'],
    coverage: { 'in-kind-deposit': ['positive'] },
    async run(context) {
      await mintVaultAsset(context, DEPOSIT)
      const venue = await depositIntoVenue(context, {
        assets: DEPOSIT,
        receiver: context.user.address,
      })
      assert(venue.venueShares > 0n, 'venue deposit minted no venue shares')
      const entry = await depositVenueShares(context, {
        venueShares: venue.venueShares,
        receiver: context.user.address,
      })
      assert(entry.venueSharesSpent === venue.venueShares, 'venue shares were not fully deposited')
      assert(entry.earnShares > 0n, 'venue-share entry minted no EarnShare')
      const cleanup = await redeem(context, {
        earnShares: entry.earnShares,
        receiver: context.user.address,
      })
      assert(cleanup.assets > 0n, 'venue-share entry could not redeem')
    },
  },
  accessKeyCase,
]

export const benchmark: E2eBenchmark = {
  roundTrip: {
    group: 'public',
    async sample(context, measure) {
      await mintVaultAsset(context, DEPOSIT)
      const entry = await measure('public-deposit', async () => {
        const result = await deposit(context, { assets: DEPOSIT, receiver: context.user.address })
        assert(result.earnShares > 0n, 'public benchmark deposit minted no EarnShare')
        return result
      })
      await measure('public-redeem', async () => {
        const result = await redeem(context, {
          earnShares: entry.earnShares,
          receiver: context.user.address,
        })
        assert(result.assets > 0n, 'public benchmark redeem returned no assets')
      })
    },
  },
}
