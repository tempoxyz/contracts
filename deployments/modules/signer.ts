import {
  isAddressEqual,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type Transport,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { Addresses, createClient } from 'viem/tempo'
import {
  configuredTempoNetworkChain,
  deploymentEnvironmentId,
  hostedEnvironment,
} from '../chain/tempo.js'
import type { EarnDeploymentProfile } from '../core/profile.js'
import { configuredRpcTransport, envPrivateKey } from '../chain/runtime.js'

export type AuthorityOptions = {
  environment: NodeJS.ProcessEnv
  outputs: Record<string, Address>
  profile: EarnDeploymentProfile
  rpcUrl: string
}

export type AuthorityDependencies = {
  authorityClient: typeof authorityClient
  fundFromFaucet: typeof fundFromFaucet
}

export type AuthorityClient = ReturnType<typeof authorityClient>

export function authorityClient(
  options: Pick<AuthorityOptions, 'profile' | 'rpcUrl'>,
  account: ReturnType<typeof privateKeyToAccount>,
) {
  const { chainId } = options.profile
  return createClient({
    account,
    chain: configuredTempoNetworkChain({
      id: deploymentEnvironmentId(chainId),
      chainId,
      rpcUrl: options.rpcUrl,
    }),
    transport: pinnedAuthorityTransport(configuredRpcTransport({ url: options.rpcUrl }), chainId),
  })
}

/**
 * Pins an authority's signing domain to the profile: viem adopts the chain ID and nonce key that
 * `eth_fillTransaction` returns for a local account, so the RPC could otherwise choose what the
 * authority signs. Refuses a reported chain other than `chainId` and any nonce key but the
 * protocol nonce.
 */
export function pinnedAuthorityTransport(transport: Transport, chainId: number): Transport {
  return (config) => {
    const resolved = transport(config)
    const request = (async (args: { method: string }, options?: unknown) => {
      const result: unknown = await resolved.request(args as never, options as never)
      if (args.method === 'eth_chainId') requireChain(result, chainId)
      if (args.method === 'eth_fillTransaction') {
        const filled = (result as { tx?: { chainId?: unknown; nonceKey?: unknown } } | null)?.tx
        if (filled?.chainId !== undefined) requireChain(filled.chainId, chainId)
        if (filled?.nonceKey !== undefined && BigInt(filled.nonceKey as string) !== 0n) {
          throw new Error('The RPC filled an authority transaction outside the protocol nonce')
        }
      }
      return result
    }) as typeof resolved.request
    return { ...resolved, request }
  }
}

function requireChain(reported: unknown, chainId: number) {
  if (Number(reported) !== chainId) {
    throw new Error(`The RPC reported chain ${String(reported)}, not the profile's ${chainId}`)
  }
}

/** Tops up an authority from a hosted network's faucet; other chains fund it themselves. */
export async function fundFromFaucet(
  client: AuthorityClient,
  profile: EarnDeploymentProfile,
  account: Address,
) {
  if (hostedEnvironment(profile.chainId)?.faucet) {
    await client.faucet.fundSync({ account, timeout: 180_000 })
  }
}

/**
 * Tops up the authority from a hosted faucet, then sends `calls` as one atomic transaction and
 * returns its hash.
 */
export async function sendAuthorityCalls(
  client: AuthorityClient,
  dependencies: Pick<AuthorityDependencies, 'fundFromFaucet'>,
  profile: EarnDeploymentProfile,
  calls: readonly { to: Address; data: Hex }[],
) {
  await dependencies.fundFromFaucet(client, profile, client.account.address)
  const receipt = await client.sendTransactionSync({
    ...(await guardedTransactionRequest(client, calls)),
    throwOnReceiptRevert: true,
    timeout: 180_000,
  })
  if (receipt.status !== 'success') throw new Error('Authority transaction did not succeed')
  return { transactions: [receipt.transactionHash] }
}

/** Whether environment variable `name` holds a valid private key of `expected`. */
export function privateKeyMatches(
  environment: Readonly<Record<string, string | undefined>>,
  name: string,
  expected: Address,
) {
  const key = envPrivateKey(environment, name)
  if (!key) return false
  try {
    return isAddressEqual(privateKeyToAccount(key).address, expected)
  } catch {
    throw new Error(`${name} must be a valid secp256k1 private key`)
  }
}

/** Captures caller intent and checks the final prepared envelope immediately before local signing. */
export async function guardedTransactionRequest<const chain extends Chain>(
  client: {
    account: ReturnType<typeof privateKeyToAccount>
    chain: chain
    getTransactionCount: PublicClient['getTransactionCount']
  },
  calls: readonly { to: Address; data: Hex; value?: bigint | undefined }[],
  feeToken: Address = Addresses.pathUsd,
) {
  const nonce = await client.getTransactionCount({
    address: client.account.address,
    blockTag: 'pending',
  })
  const validBefore = Math.floor(Date.now() / 1000) + 300
  const intent = { calls, chainId: client.chain.id, feeToken, nonce, validBefore }
  const account: typeof client.account = {
    ...client.account,
    signTransaction: (transaction, options) => {
      assertSigningIntent(transaction as unknown as Record<string, unknown>, intent)
      return client.account.signTransaction(transaction, options)
    },
  }
  return {
    account,
    calls,
    chain: client.chain,
    chainId: intent.chainId,
    feeToken,
    forceAtomic: true as const,
    nonce,
    nonceKey: 0n,
    validBefore,
    type: 'tempo' as const,
  }
}

/** Rejects unsolicited signing fields, altered caller intent, and unbounded gas liability. */
export function assertSigningIntent(
  transaction: Record<string, unknown>,
  intent: {
    calls: readonly { to: Address; data: Hex; value?: bigint | undefined }[]
    chainId: number
    feeToken: Address
    nonce: number
    validBefore?: number | undefined
  },
) {
  if (transaction.type !== 'tempo')
    throw new Error('Prepared transaction changed the Tempo envelope type')
  if (
    transaction.chainId !== intent.chainId ||
    transaction.nonce !== intent.nonce ||
    transaction.nonceKey !== 0n
  )
    throw new Error('Prepared transaction changed the signing chain or protocol nonce')
  if (
    typeof transaction.feeToken !== 'string' ||
    !isAddressEqual(transaction.feeToken as Address, intent.feeToken)
  )
    throw new Error('Prepared transaction changed the fee token')
  for (const field of [
    'keyAuthorization',
    'authorizationList',
    'aaAuthorizationList',
    'validAfter',
    'feePayer',
    'feePayerSignature',
  ])
    if (
      transaction[field] !== undefined &&
      transaction[field] !== null &&
      transaction[field] !== false
    )
      throw new Error(`Prepared transaction contains unsolicited ${field}`)
  if (
    transaction.validBefore !== intent.validBefore ||
    (intent.validBefore !== undefined && intent.validBefore <= Math.floor(Date.now() / 1000))
  )
    throw new Error('Prepared transaction changed or exceeded its local signing validity')
  const calls = transaction.calls as typeof intent.calls | undefined
  if (
    !calls ||
    calls.length !== intent.calls.length ||
    calls.some((call, index) => {
      const expected = intent.calls[index]!
      return (
        !isAddressEqual(call.to, expected.to) ||
        call.data.toLowerCase() !== expected.data.toLowerCase() ||
        (call.value ?? 0n) !== (expected.value ?? 0n)
      )
    })
  )
    throw new Error('Prepared transaction changed the authorized calls')
  // Tempo quotes gas in attodollars. A single operational action may reserve at most one USD.
  const { gas, maxFeePerGas, maxPriorityFeePerGas } = transaction
  if (
    typeof gas !== 'bigint' ||
    gas <= 0n ||
    typeof maxFeePerGas !== 'bigint' ||
    maxFeePerGas < 0n ||
    typeof maxPriorityFeePerGas !== 'bigint' ||
    maxPriorityFeePerGas < 0n ||
    maxPriorityFeePerGas > maxFeePerGas ||
    gas * maxFeePerGas > 10n ** 18n
  )
    throw new Error('Prepared transaction exceeds the one-USD fee limit or has invalid gas fees')
}
