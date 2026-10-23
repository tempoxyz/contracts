import { getAddress, zeroAddress, type Address, type Hex, type PublicClient } from 'viem'

import {
  earnRouterAbi,
  managedPropAMMPoolAbi,
  priceOracleAbi,
  propAMMPoolAbi,
} from '../../abis/index.js'
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
  route?: ExpectedRoute | undefined
}

/**
 * A router's conversion route. `poolKind` is `SingleZoneEarnRouter.PoolKind` (0 Direct, 1 Managed);
 * omitting it, `pairIndex`, and `sponsorId` expects a Direct pool or none.
 */
export type ExpectedRoute = {
  pool: Address
  customerId: Hex
  poolKind?: number
  pairIndex?: number
  sponsorId?: bigint
}

/**
 * Checks a router's immutable bindings and, when a route is expected, its PropAMM pool, customer
 * ID, pool kind and pair, and pool orientation. Returns the bound pool when a route is expected.
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

  const [pool, customerId, privateAssetIsBase, poolKind, pairIndex, sponsorId] = await Promise.all([
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'pool' }),
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'customerId' }),
    client.readContract({
      address: router,
      abi: earnRouterAbi,
      functionName: 'privateAssetIsBase',
    }),
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'poolKind' }),
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'pairIndex' }),
    client.readContract({ address: router, abi: earnRouterAbi, functionName: 'sponsorId' }),
  ])
  equalAddress(pool, route.pool, 'router PropAMM pool')
  if (customerId.toLowerCase() !== route.customerId.toLowerCase()) {
    throw new InspectionMismatchError(
      `Router customer ID is ${customerId}, expected ${route.customerId}`,
    )
  }
  const expectedKind = route.poolKind ?? 0
  const expectedPair = route.pairIndex ?? 0
  const expectedSponsor = route.sponsorId ?? 0n
  if (poolKind !== expectedKind || pairIndex !== expectedPair || sponsorId !== expectedSponsor) {
    throw new InspectionMismatchError(
      `Router pool kind ${poolKind}, pair ${pairIndex}, and sponsor ${sponsorId} do not match the expected ${expectedKind}, ${expectedPair}, and ${expectedSponsor}`,
    )
  }
  if (getAddress(route.pool) === zeroAddress) {
    if (privateAssetIsBase) {
      throw new InspectionMismatchError('Router without a pool reports a pool orientation')
    }
    return zeroAddress
  }
  const { base, quote } = await poolTokens(client, route.pool, managedPair(poolKind, pairIndex))
  const [expectedBase, expectedQuote] = privateAssetIsBase
    ? [expected.privateAsset, expected.vaultAsset]
    : [expected.vaultAsset, expected.privateAsset]
  equalAddress(base, expectedBase, 'router PropAMM pool base token')
  equalAddress(quote, expectedQuote, 'router PropAMM pool quote token')
  return getAddress(route.pool)
}

/**
 * Reports whether a router's PropAMM conversion can serve deposits and redemptions now. Pass
 * `pairIndex` for a ManagedDirectPropAMM pool.
 */
export async function inspectRouterReadiness(
  client: Pick<PublicClient, 'readContract'> & LatestBlockClient,
  router: Address,
  pool: Address,
  pairIndex?: number,
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
  if (paused) blockers.push(pairIndex === undefined ? 'pool is paused' : 'pool or pair is paused')
  if (!admitted)
    blockers.push(
      pairIndex === undefined
        ? 'router is not admitted as taker and unredirected recipient'
        : `router is not listed on pool pair ${pairIndex}`,
    )
  if (!atPar) blockers.push('oracle price is not at par')
  // `atPar` compares only the price; the pool also rejects reports older than its maximum age.
  const freshness = await oracleFreshness(client, pool, pairIndex)
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

/**
 * Returns why the pool would reject its oracle's latest report as stale, if it would. Pass
 * `pairIndex` for a ManagedDirectPropAMM pool, whose oracle and maximum age are per pair.
 */
export async function oracleFreshness(
  client: Pick<PublicClient, 'readContract'> & LatestBlockClient,
  pool: Address,
  pairIndex?: number,
): Promise<string | undefined> {
  try {
    const [{ oracle, maxAge }, block] = await Promise.all([
      poolOracle(client, pool, pairIndex),
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

/** The converting pool's base and quote tokens: a Direct pool's, or a Managed pool pair's. */
export async function poolTokens(
  client: Pick<PublicClient, 'readContract'>,
  pool: Address,
  pairIndex?: number,
): Promise<{ base: Address; quote: Address }> {
  if (pairIndex !== undefined) {
    const pair = await client.readContract({
      address: pool,
      abi: managedPropAMMPoolAbi,
      functionName: 'pair',
      args: [pairIndex],
    })
    return { base: pair.base, quote: pair.quote }
  }
  const [base, quote] = await Promise.all([
    client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'baseToken' }),
    client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'quoteToken' }),
  ])
  return { base, quote }
}

async function poolOracle(
  client: Pick<PublicClient, 'readContract'>,
  pool: Address,
  pairIndex?: number,
): Promise<{ oracle: Address; maxAge: bigint }> {
  if (pairIndex !== undefined) {
    const pair = await client.readContract({
      address: pool,
      abi: managedPropAMMPoolAbi,
      functionName: 'pair',
      args: [pairIndex],
    })
    return { oracle: pair.oracle, maxAge: pair.maxOracleAge }
  }
  const [oracle, maxAge] = await Promise.all([
    client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'oracle' }),
    client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'maxOracleAge' }),
  ])
  return { oracle, maxAge }
}

/** The pair a router reads on its pool: its pair index for a Managed pool, else none. */
function managedPair(poolKind: number, pairIndex: number) {
  return poolKind === 1 ? pairIndex : undefined
}
