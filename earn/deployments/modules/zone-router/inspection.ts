import { getAddress, zeroAddress, type Address, type Hex, type PublicClient } from 'viem'

import { earnRouterAbi, priceOracleAbi, propAMMPoolAbi } from '../../abis/index.js'
import {
  InspectionMismatchError,
  equalAddress,
  type LatestBlockClient,
} from '../../chain/inspect.js'

/** Live PropAMM conversion snapshot for the router; it is not a liquidity guarantee. */
export type RouterReadiness = {
  scope: 'conversion'
  status: 'ready' | 'blocked'
  blockers: string[]
  depositLiquidity: bigint | null
  redeemLiquidity: bigint | null
}

/** Immutable bindings of one `SingleZoneEarnRouter`. */
export type ExpectedRouter = {
  router: Address
  zoneId: number
  earnVault: Address
  earnShare: Address
  vaultAsset: Address
  privateAsset: Address
  /** The configured conversion route (zero pool and customer ID for none); omit to skip it. */
  route?: { pool: Address; customerId: Hex } | undefined
}

/**
 * Checks a router's immutable bindings and, when a route is expected, its PropAMM pool, customer
 * ID, and pool orientation. Returns the bound pool when a route is expected.
 */
export async function inspectRouterBinding(
  client: Pick<PublicClient, 'readContract'>,
  expected: ExpectedRouter,
): Promise<Address | undefined> {
  const { router, route } = expected
  const [zoneId, vault, privateAsset, vaultAsset, share] = await Promise.all([
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'allowedZoneId' }),
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'earnVault' }),
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'privateAsset' }),
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'vaultAsset' }),
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'earnShare' }),
  ])
  if (zoneId !== expected.zoneId) {
    throw new InspectionMismatchError(`Router Zone is ${zoneId}, expected ${expected.zoneId}`)
  }
  equalAddress(vault, expected.earnVault, 'router EarnVault')
  equalAddress(privateAsset, expected.privateAsset, 'router private asset')
  equalAddress(vaultAsset, expected.vaultAsset, 'router vault asset')
  equalAddress(share, expected.earnShare, 'router EarnShare')
  if (!route) return undefined

  const [pool, customerId, privateAssetIsBase] = await Promise.all([
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'pool' }),
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'customerId' }),
    client.readContract({
      address: router,
      abi: earnRouterAbi,
      functionName: 'privateAssetIsBase',
    }),
  ])
  equalAddress(pool, route.pool, 'router PropAMM pool')
  if (customerId.toLowerCase() !== route.customerId.toLowerCase()) {
    throw new InspectionMismatchError(
      `Router customer ID is ${customerId}, expected ${route.customerId}`,
    )
  }
  if (getAddress(route.pool) === zeroAddress) {
    if (privateAssetIsBase) {
      throw new InspectionMismatchError('Router without a pool reports a pool orientation')
    }
    return zeroAddress
  }
  const [base, quote] = await Promise.all([
    client.readContract({ address: route.pool, abi: propAMMPoolAbi, functionName: 'baseToken' }),
    client.readContract({ address: route.pool, abi: propAMMPoolAbi, functionName: 'quoteToken' }),
  ])
  const [expectedBase, expectedQuote] = privateAssetIsBase
    ? [expected.privateAsset, expected.vaultAsset]
    : [expected.vaultAsset, expected.privateAsset]
  equalAddress(base, expectedBase, 'router PropAMM pool base token')
  equalAddress(quote, expectedQuote, 'router PropAMM pool quote token')
  return getAddress(route.pool)
}

/** Reports whether a router's PropAMM conversion can serve deposits and redemptions now. */
export async function inspectRouterReadiness(
  client: Pick<PublicClient, 'readContract'> & LatestBlockClient,
  router: Address,
  pool: Address,
): Promise<RouterReadiness> {
  let status: readonly [boolean, boolean, boolean, bigint, bigint]
  try {
    status = await client.readContract({
      address: router,
      abi: earnRouterAbi,
      functionName: 'liquidityStatus',
    })
  } catch {
    return {
      scope: 'conversion',
      status: 'blocked',
      blockers: ['router liquidity status is unavailable'],
      depositLiquidity: null,
      redeemLiquidity: null,
    }
  }
  const [paused, admitted, atPar, depositLiquidity, redeemLiquidity] = status
  const blockers: string[] = []
  if (paused) blockers.push('pool is paused')
  if (!admitted) blockers.push('router is not admitted as taker and unredirected recipient')
  if (!atPar) blockers.push('oracle price is not at par')
  // `atPar` compares only the price; the pool also rejects reports older than its maximum age.
  const freshness = await oracleFreshness(client, pool)
  if (freshness) blockers.push(freshness)
  if (depositLiquidity === 0n) blockers.push('pool has no vault-asset liquidity for deposits')
  if (redeemLiquidity === 0n) blockers.push('pool has no private-asset liquidity for redemptions')
  return {
    scope: 'conversion',
    status: blockers.length === 0 ? 'ready' : 'blocked',
    blockers,
    depositLiquidity,
    redeemLiquidity,
  }
}

/** Returns why the pool would reject its oracle's latest report as stale, if it would. */
export async function oracleFreshness(
  client: Pick<PublicClient, 'readContract'> & LatestBlockClient,
  pool: Address,
): Promise<string | undefined> {
  try {
    const [oracle, maxAge, block] = await Promise.all([
      client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'oracle' }),
      client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'maxOracleAge' }),
      client.getBlock(),
    ])
    const [, updatedAt] = await client.readContract({
      address: oracle,
      abi: priceOracleAbi,
      functionName: 'latestPrice',
    })
    const age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0n
    return age > maxAge ? `oracle report is stale (${age}s old, maximum ${maxAge}s)` : undefined
  } catch {
    return 'oracle freshness is unavailable'
  }
}
