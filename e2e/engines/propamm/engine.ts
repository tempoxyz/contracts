import { earnFeesAbi, earnVaultAbi } from '@tempoxyz/earn/abis'
import { quotePropAMMRoute } from '@tempoxyz/earn/deployments'
import type { E2eEngine } from '../index.js'

export const engine: E2eEngine = {
  /**
   * `previewRedeem` values engine shares at the oracle price, rounded down, but the pool's sell also
   * pays the engine route's accrued rounding credit. Quote that route as deposits do, after the same
   * fee-projected EarnShare conversion `previewRedeem` applies.
   */
  async quoteRedeem(context, earnShares) {
    const [held, supply, fees] = await Promise.all([
      context.l1Public.readContract({
        address: context.contracts.earnVault,
        abi: earnVaultAbi,
        functionName: 'engineShares',
      }),
      context.l1Public.readContract({
        address: context.contracts.earnVault,
        abi: earnVaultAbi,
        functionName: 'totalEarnShares',
      }),
      context.l1Public.readContract({
        address: context.contracts.earnFees,
        abi: earnFeesAbi,
        functionName: 'previewAccruedFees',
      }),
    ])
    const projectedSupply = supply + fees.totalFeeEarnShares
    if (held === 0n || projectedSupply === 0n)
      throw new Error('PropAMM redeem quote has no backing')
    const engineShares = (earnShares * held) / projectedSupply
    if (engineShares === 0n) throw new Error('PropAMM redeem quote converts to zero engine shares')
    return quotePropAMMRoute(context.l1Public, context.contracts.engine, true, engineShares)
  },
}
