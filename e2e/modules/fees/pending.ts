import { earnFeesAbi, earnVaultAbi } from '@tempoxyz/contracts/abis'
import { erc20Abi } from 'viem'
import { e2eEngines } from '../../engines/index.js'
import type { E2eContext } from '../../harness/context.js'
import { mintVaultAsset } from '../../harness/support/funding.js'
import { accrueFees, deposit, redeem } from '../../harness/support/public.js'
import { assert, E2ePrerequisiteError } from '../../harness/support/utils.js'

const DEPOSIT = 1_000_000n
const GROWTH = 100_000n
const WITHDRAW = DEPOSIT / 2n

/** Requires a validated disposable venue before the case funds or deposits anything. */
export function requirePendingFeeGrowth(context: E2eContext) {
  const grow = e2eEngines[context.engineKind].pendingFeeGrowth?.(context)
  if (!grow)
    throw new E2ePrerequisiteError(
      'Pending-fee preview coverage requires a disposable yield fixture',
    )
  return grow
}

/** Exercises real venue growth across an explicit Earn fee checkpoint and subsequent redemption. */
export async function pendingFeeTransition(context: E2eContext) {
  const grow = requirePendingFeeGrowth(context)
  await mintVaultAsset(context, DEPOSIT + GROWTH)
  const position = await deposit(context, { assets: DEPOSIT, receiver: context.user.address })
  const before = await state(context, position.earnShares)
  assert(
    before.pending.totalFeeEarnShares === 0n,
    'deposit left fees pending before yield injection',
  )

  await grow(GROWTH)
  const pending = await state(context, position.earnShares)
  assertPendingGrowth(before, pending)
  context.progress.step(
    'CHECK',
    `pending fee EarnShare ${pending.pending.totalFeeEarnShares}; redeem preview ${pending.redeem}; withdraw preview ${pending.withdraw}`,
  )

  await accrueFees(context)
  const after = await state(context, position.earnShares)
  const minted = after.supply - pending.supply
  assert(minted > 0n, 'fee checkpoint minted no EarnShare')
  assertWithinOne(
    minted,
    pending.pending.totalFeeEarnShares,
    'checkpoint differs from pending fee mint',
  )
  assert(
    after.feeBalance - pending.feeBalance === minted,
    'fee mint did not reach EarnFees custody',
  )
  assert(after.claimable - pending.claimable === minted, 'fee mint did not credit the claim ledger')
  assert(after.assets === pending.assets, 'fee checkpoint moved active assets')
  assert(after.engineShares === pending.engineShares, 'fee checkpoint moved engine shares')
  assert(after.pending.totalFeeEarnShares === 0n, 'fee checkpoint left representable fees pending')
  // The local excess target may advance between blocks; at this fixture scale it rounds by at most one unit.
  assertWithinOne(
    after.redeem,
    pending.redeem,
    'redeem preview did not include pending fee dilution',
  )
  assertWithinOne(
    after.withdraw,
    pending.withdraw,
    'withdraw preview did not include pending fee dilution',
  )
  context.progress.step(
    'CHECK',
    `crystallized fee EarnShare ${minted}; redeem preview ${after.redeem}`,
  )

  const redeemed = await redeem(context, {
    earnShares: position.earnShares,
    receiver: context.user.address,
  })
  assert(redeemed.assets === after.redeem, 'redemption did not pay the crystallized net preview')
}

/** Rejects a no-growth or already-checkpointed fixture instead of accepting vacuous preview parity. */
export function assertPendingGrowth(before: GrowthState, pending: GrowthState) {
  assert(pending.assets > before.assets, 'venue donation did not increase active backing')
  assert(pending.engineShares === before.engineShares, 'venue donation minted engine shares')
  assert(pending.supply === before.supply, 'venue donation crystallized fee EarnShare')
  assert(
    pending.feeBalance === before.feeBalance,
    'venue donation changed fee custody before checkpoint',
  )
  assert(
    pending.claimable === before.claimable,
    'venue donation changed fee claims before checkpoint',
  )
  assert(pending.pending.positiveAccrualAssets > 0n, 'venue donation created no positive accrual')
  assert(pending.pending.totalFeeAssets > 0n, 'venue donation created no pending fee assets')
  assert(pending.pending.totalFeeEarnShares > 0n, 'venue donation created no pending fee EarnShare')
}

async function state(context: E2eContext, earnShares: bigint) {
  const blockNumber = await context.l1Public.getBlockNumber({ cacheTime: 0 })
  const vault = { address: context.contracts.earnVault, abi: earnVaultAbi, blockNumber } as const
  const fees = { address: context.contracts.earnFees, abi: earnFeesAbi, blockNumber } as const
  const read = context.l1Public.readContract
  const [assets, engineShares, supply, feeBalance, claimable, pending, redeem, withdraw] =
    await Promise.all([
      read({ ...vault, functionName: 'totalAssets' }),
      read({ ...vault, functionName: 'engineShares' }),
      read({ ...vault, functionName: 'totalEarnShares' }),
      read({
        address: context.contracts.earnShare,
        abi: erc20Abi,
        blockNumber,
        functionName: 'balanceOf',
        args: [context.contracts.earnFees],
      }),
      read({ ...fees, functionName: 'totalClaimableEarnShares' }),
      read({ ...fees, functionName: 'previewAccruedFees' }),
      read({ ...vault, functionName: 'previewRedeem', args: [earnShares] }),
      read({ ...vault, functionName: 'previewWithdraw', args: [WITHDRAW] }),
    ])
  return { assets, engineShares, supply, feeBalance, claimable, pending, redeem, withdraw }
}

type FeeState = Awaited<ReturnType<typeof state>>
type GrowthState = Pick<
  FeeState,
  'assets' | 'engineShares' | 'supply' | 'feeBalance' | 'claimable'
> & {
  pending: Pick<
    FeeState['pending'],
    'positiveAccrualAssets' | 'totalFeeAssets' | 'totalFeeEarnShares'
  >
}

function assertWithinOne(actual: bigint, expected: bigint, message: string) {
  const difference = actual > expected ? actual - expected : expected - actual
  assert(difference <= 1n, `${message}: ${actual} versus ${expected}`)
}
