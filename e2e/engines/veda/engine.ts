import { engineFixtures } from '../../harness/context.js'
import { previewEarnRedeem } from '../../harness/support/slippage.js'
import type { E2eEngine } from '../index.js'

export const engine: E2eEngine = {
  // Only loader-provided LocalVeda fixtures use this string instead of the engine's custom error.
  redeemBoundErrors: (context) =>
    engineFixtures(context, ['teller'])
      ? { errors: [{ reason: 'VEDA_MINIMUM_ASSETS' }] }
      : undefined,
  quoteRedeem: (context, earnShares) => previewEarnRedeem(context, earnShares),
}
