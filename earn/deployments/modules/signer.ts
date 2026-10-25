import type { Address, Hex, Transport } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { createClient } from 'viem/tempo'
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
    account: client.account,
    calls,
    chain: client.chain,
    forceAtomic: true,
    throwOnFailure: true,
    timeout: 180_000,
  })
  return { transactions: [receipt.transactionHash] }
}

/** Whether environment variable `name` holds a valid private key of `expected`. */
export function privateKeyMatches(
  environment: Readonly<Record<string, string | undefined>>,
  name: string,
  expected: Address,
) {
  try {
    const key = envPrivateKey(environment, name)
    return key !== undefined && privateKeyToAccount(key).address === expected
  } catch {
    return false
  }
}
