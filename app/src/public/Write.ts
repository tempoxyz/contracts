import type { PublicEarnStack } from '@tempoxyz/earn/deployments'
import type { Account, Address, Call, Hex, PublicClient } from 'viem'
import { simulateCalls, waitForTransactionReceipt } from 'viem/actions'

import { actions, limits, type Action } from '../earn/Actions.js'
import { readDepositEligibility } from '../earn/AccessVerification.js'
import { readPublicWriteState } from '../earn/Verification.js'
import * as Tempo from '../Tempo.js'

/**
 * Revalidates one public action immediately before a wallet signs it, then simulates and returns
 * its exact approval-and-action call batch. The bound comes from the quote the user reviewed; a
 * live quote that no longer meets it is refused rather than silently widening the bound.
 */
export async function prepare(options: prepare.Options): Promise<readonly Call[]> {
  const { account, action, amount, deployment, publicClient, reviewedQuote } = options
  const definition = actions[action]
  if (!definition.available(deployment.capabilities)) {
    throw new Error('This action is unavailable.')
  }

  const [state, quote, eligible] = await Promise.all([
    readPublicWriteState(publicClient, deployment),
    definition.quote(publicClient, deployment, amount),
    definition.requiresEligibility
      ? readDepositEligibility(publicClient, deployment, account)
      : Promise.resolve(true),
  ])
  if (!eligible) throw new Error('This wallet cannot deposit.')
  if (!state.engineMatches || !state.isAccountingAligned) {
    throw new UnsafeDeploymentError(state.engineMatches)
  }

  const { bound } = limits(definition, amount, reviewedQuote)
  if (definition.bound === 'minimumOutput' ? quote < bound : quote > bound) {
    throw new QuoteChangedError()
  }

  const calls = definition.calls({ account, amount, deployment, bound })
  const simulation = await simulateCalls(publicClient, {
    account,
    calls,
    // Moderato rejects validation-mode eth_simulateV1 calls above its block gas limit.
    // Contract execution and state transitions are still simulated sequentially.
    validation: false,
  })
  const failure = simulation.results.find((result) => result.status === 'failure')
  if (failure) throw failure.error ?? new Error('The transaction simulation failed.')
  return calls
}

export declare namespace prepare {
  type Options = {
    account: Address
    action: Action
    amount: bigint
    deployment: PublicEarnStack
    publicClient: PublicClient
    /** The quote shown to the user, from which the signed bound is derived. */
    reviewedQuote: bigint
  }
}

/**
 * Submits exactly the prepared call batch, reports its hash on broadcast, and waits for a
 * successful receipt.
 */
export async function send(options: send.Options): Promise<Hex> {
  // Wagmi erases Tempo's call-batch request extension from its wallet client type.
  const hash = await options.walletClient.sendTransaction({
    account: options.account,
    calls: options.calls,
    ...(options.sponsored ? { feePayer: true as const } : {}),
    timeout: Tempo.transactionTimeout,
  } as never)
  options.onBroadcast(hash)
  // Expiring-nonce sends share nonce 0, so viem's replacement check could return an earlier
  // transaction's receipt.
  const receipt = await waitForTransactionReceipt(options.publicClient, {
    checkReplacement: false,
    hash,
  })
  if (receipt.status !== 'success') throw new Error(`Transaction ${hash} reverted.`)
  return hash
}

export declare namespace send {
  type Options = {
    account: Account | Address
    calls: readonly Call[]
    onBroadcast: (hash: Hex) => void
    publicClient: PublicClient
    sponsored: boolean
    walletClient: { sendTransaction: (parameters: never) => Promise<Hex> }
  }
}

/** Indicates that the live quote moved past the bound the user reviewed. */
export class QuoteChangedError extends Error {
  constructor() {
    super('The quote changed beyond the reviewed bound. Review the new terms.')
    this.name = 'QuoteChangedError'
  }
}

/** Indicates that the selected deployment changed after its initial verification. */
export class UnsafeDeploymentError extends Error {
  constructor(engineMatches: boolean) {
    super(
      engineMatches
        ? 'EarnVault accounting is not aligned.'
        : 'EarnVault engine no longer matches the deployment registry.',
    )
    this.name = 'UnsafeDeploymentError'
  }
}
