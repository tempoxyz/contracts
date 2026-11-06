import { E2ePrerequisiteError } from '../../harness/support/utils.js'

type SupplyQuote = { supply: bigint; pendingFeeShares: bigint }
type FundingAttempt = { funded: bigint; receipt: { blockNumber: bigint } }

/** Quotes the same fee-inclusive supply that the controller checks after accrual, without headroom. */
export function fundingSupply(quote: SupplyQuote) {
  return quote.supply + quote.pendingFeeShares
}

/** Retries only confirmed zero funding with fee-quote drift, never an unknown submission or increased raw supply. */
export async function fundWithSupplyQuote<Result extends FundingAttempt>(input: {
  quote: (blockNumber?: bigint) => Promise<SupplyQuote>
  submit: (maxEarnShareSupply: bigint) => Promise<Result>
}): Promise<Result> {
  const initial = await input.quote()
  let quote = initial
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt > 0) quote = await input.quote()
    requireOriginalSupply(initial, quote)
    const maxEarnShareSupply = fundingSupply(quote)
    const result = await input.submit(maxEarnShareSupply)
    if (result.funded !== 0n) return result

    // A zero Funded event confirms the atomic contribution did not happen; only then is retry safe.
    const settled = await input.quote(result.receipt.blockNumber)
    requireOriginalSupply(initial, settled)
    if (fundingSupply(settled) <= maxEarnShareSupply) return result
  }
  throw new E2ePrerequisiteError(
    'Reward fee-inclusive supply changed across 3 confirmed zero-funding attempts; retry acceptance with a stable fee quote',
  )
}

function requireOriginalSupply(initial: SupplyQuote, quote: SupplyQuote) {
  // Do not reauthorize new depositors by lifting the anti-JIT bound after a rejected attempt.
  if (quote.supply > initial.supply)
    throw new E2ePrerequisiteError(
      `Reward EarnShare supply increased from ${initial.supply} to ${quote.supply}; refusing to raise the anti-JIT cap for new supply`,
    )
}
