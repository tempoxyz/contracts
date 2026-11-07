import { simple4626VaultAbi } from '@tempoxyz/contracts/abis'
import { isAddressEqual } from 'viem'
import { approve } from '../../harness/support/funding.js'
import { write } from '../../harness/support/transactions.js'
import { engineFixtures } from '../../harness/context.js'
import { previewEarnRedeem } from '../../harness/support/slippage.js'
import type { E2eEngine } from '../index.js'

export const engine: E2eEngine = {
  pendingFeeGrowth(context) {
    const fixture = context.funding
    // Only the disposable loader's validated Simple4626 venue supports synthetic yield injection.
    if (
      context.provider !== 'local' ||
      context.environmentId !== 'local' ||
      !fixture?.funder ||
      !isAddressEqual(fixture.venue, context.contracts.venue) ||
      !isAddressEqual(fixture.baseAsset, context.assets.base) ||
      !isAddressEqual(fixture.baseAsset, context.contracts.asset)
    )
      return undefined
    return async (assets) => {
      const { wallet } = context.actors.user
      await approve(context, wallet, fixture.baseAsset, fixture.venue, assets)
      // Donate to the venue, not EarnVault.contribute(), which crystallizes fees immediately.
      await write(wallet, {
        address: fixture.venue,
        abi: simple4626VaultAbi,
        functionName: 'donate',
        args: [assets],
      })
    }
  },
  quoteRedeem: (context, earnShares) => previewEarnRedeem(context, earnShares),
  morphoFeeWrapper: (context) => engineFixtures(context, ['morphoFeeWrapper'])?.morphoFeeWrapper,
}
