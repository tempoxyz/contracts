import type { PublicEarnStack, TokenMetadata } from '@tempoxyz/earn/deployments'
import { erc20Abi, isAddressEqual, type Address, type PublicClient } from 'viem'

import type { CatalogStack } from './catalog.js'

/** Returns every configured customer token whose balance belongs in the app panels. */
export function balanceTokens(deployment: PublicEarnStack): readonly Address[] {
  const privateAsset = deployment.modes.private?.privateAsset
  return unique([...(privateAsset ? [privateAsset] : []), deployment.contracts.asset])
}

/** Returns every registered token needed for one private position snapshot. */
export function privateBalanceTokens(deployment: PublicEarnStack): readonly Address[] {
  return unique([deployment.contracts.earnShare, ...balanceTokens(deployment)])
}

/**
 * Returns the one private asset of the registry's immutable private route, or `undefined` unless
 * the route converts a distinct private asset to and from the vault asset.
 */
export function privateRouteAsset(deployment: PublicEarnStack): Address | undefined {
  const privateAsset = deployment.modes.private?.privateAsset
  if (!privateAsset || isAddressEqual(privateAsset, deployment.contracts.asset)) return undefined
  return privateAsset
}

/**
 * Returns every token the app may move into the Zone: the private route's asset, plus the Zone fee
 * token PATHUSD when it is one of the deployment's balance tokens, since private fees are paid in it.
 */
export function zoneFundingTokens(
  deployment: PublicEarnStack,
  feeToken: Address,
): readonly Address[] {
  const privateAsset = privateRouteAsset(deployment) ?? deployment.contracts.asset
  const fee = balanceTokens(deployment).find((token) => isAddressEqual(token, feeToken))
  return unique([privateAsset, ...(fee ? [fee] : [])])
}

/** Returns display metadata for a configured deployment token. */
export function tokenMetadata(deployment: CatalogStack, token: Address): TokenMetadata {
  if (isAddressEqual(token, deployment.contracts.asset)) return deployment.expectedMetadata.asset
  const privateAsset = privateRouteAsset(deployment)
  if (privateAsset && deployment.privateAssetMetadata && isAddressEqual(token, privateAsset)) {
    return deployment.privateAssetMetadata
  }
  return {
    decimals: deployment.expectedMetadata.asset.decimals,
    name: 'Unsupported token',
    symbol: 'Unsupported token',
  }
}

/** Reads one token's metadata, as the catalog records it. */
export async function readMetadata(
  client: Pick<PublicClient, 'readContract'>,
  address: Address,
): Promise<TokenMetadata> {
  const [name, symbol, decimals] = await Promise.all([
    client.readContract({ address, abi: erc20Abi, functionName: 'name' }),
    client.readContract({ address, abi: erc20Abi, functionName: 'symbol' }),
    client.readContract({ address, abi: erc20Abi, functionName: 'decimals' }),
  ])
  return { name, symbol, decimals }
}

function unique(tokens: readonly Address[]) {
  return tokens.filter(
    (token, index) => tokens.findIndex((candidate) => isAddressEqual(candidate, token)) === index,
  )
}
