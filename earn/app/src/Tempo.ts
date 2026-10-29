import {
  configuredTempoNetworkChain,
  hasFaucet,
  type PublicNetwork,
} from '@tempoxyz/contracts/deployments'
import type { Account, Address } from 'viem'
import { createClient as createTempoClient, http, withRelay } from 'viem/tempo'

import { nestedMessageIncludes } from './Errors.js'

/** Batches concurrent Tempo L1 contract reads through deployless multicall. */
export const l1Batch = { multicall: { deployless: true } } as const

/** How long one transaction send, or one wait for its settlement, may take. */
export const transactionTimeout = 180_000

type Network = Pick<PublicNetwork, 'chainId' | 'name' | 'rpcUrl'>

/** Returns the Tempo L1 chain one catalog network serves. */
export function chain(network: Network) {
  return configuredTempoNetworkChain({ ...network, id: network.name })
}

/** Creates an account-free Tempo client for contract reads only. */
export function createClient(network: Network) {
  return createTempoClient({
    batch: l1Batch,
    chain: chain(network),
    transport: transport(network.rpcUrl),
  })
}

/**
 * The Tempo L1 RPC transport; with a sponsor, transactions are relayed to it for fee signing and
 * every other request goes to the RPC.
 */
export function transport(rpcUrl: string, sponsorUrl?: string | undefined) {
  const rpc = http(rpcUrl, { timeout: 10_000 })
  if (!sponsorUrl) return rpc
  return withRelay(rpc, http(sponsorUrl, { timeout: 10_000 }), { policy: 'sign-only' })
}

/** Creates a Tempo client that signs with a browser-owned Privy viem account. */
export function createAccountClient(network: Network, account: Account) {
  return createTempoClient({
    account,
    batch: l1Batch,
    chain: chain(network),
    transport: transport(network.rpcUrl),
  })
}

/** Funds every canonical testnet faucet token for a connected wallet. */
export function fundAccount(network: Network, account: Address) {
  if (!hasFaucet(network.chainId))
    throw new Error(`Chain ${network.chainId} does not have a faucet.`)
  return createClient(network).faucet.fundSync({ account, timeout: transactionTimeout })
}

/**
 * Sends once, and on an insufficient-funds failure funds the sender through `fund` and sends once
 * more. Pass `fund` only on a self-funded testnet: a sponsored send must never retry.
 */
export async function sendWithFaucetRetry<result>(
  send: () => Promise<result>,
  fund: (() => Promise<unknown>) | undefined,
) {
  try {
    return await send()
  } catch (error) {
    if (!fund || !nestedMessageIncludes(error, 'insufficient funds')) throw error
    await fund()
    return await send()
  }
}
