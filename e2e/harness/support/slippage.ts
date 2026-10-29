import { earnVaultAbi } from '@tempoxyz/contracts/abis'
import { quoteEarnDeposit } from '@tempoxyz/contracts/deployments'
import { EarnShares } from 'viem/tempo'
import type { E2eContext } from '../context.js'

const LIVE_SLIPPAGE_BPS = 50

/** EarnShare a deposit of `assets` mints at the current state, through the engine's shared quote. */
export function previewEarnDeposit(context: E2eContext, assets: bigint) {
  const { engine, venue, earnVault } = context.contracts
  return quoteEarnDeposit(
    context.l1Public,
    {
      engineKind: context.engineKind,
      contracts: { asset: context.assets.base, engine, venue, earnVault },
    },
    assets,
  )
}

/** The EarnVault's conservative valuation of `earnShares` in vault assets. */
export function previewEarnRedeem(context: E2eContext, earnShares: bigint) {
  return context.l1Public.readContract({
    address: context.contracts.earnVault,
    abi: earnVaultAbi,
    functionName: 'previewRedeem',
    args: [earnShares],
  })
}

export function minimumOutput(expected: bigint) {
  if (expected <= 0n) throw new Error('Preview returned zero output')
  return EarnShares.minimumOutput(expected, LIVE_SLIPPAGE_BPS)
}
