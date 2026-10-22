import { engineFixtures } from '../../harness/context.js'
import { previewEarnRedeem } from '../../harness/support/slippage.js'
import type { E2eEngine } from '../index.js'

export const engine: E2eEngine = {
  quoteRedeem: (context, earnShares) => previewEarnRedeem(context, earnShares),
  morphoFeeWrapper: (context) => engineFixtures(context, ['morphoFeeWrapper'])?.morphoFeeWrapper,
}
