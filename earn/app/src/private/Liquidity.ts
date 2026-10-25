import { earnRouterAbi } from '@tempoxyz/earn/abis'
import { oracleFreshness } from '@tempoxyz/earn/deployments'
import { formatUnits, getAddress, type Address, type Hex, type PublicClient } from 'viem'

import type { CatalogStack } from '../../deployments/catalog.js'
import { tokenMetadata } from '../../deployments/tokens.js'
import { actions, privateFlow, type Action } from '../earn/Actions.js'
import { UserFacingError } from '../Errors.js'

/** Live DirectPropAMM pool state reported by the router; a snapshot, not an execution guarantee. */
export type Status = {
  /** Whether the pool owner has paused conversion. */
  paused: boolean
  /** Whether the pool admits the router as taker and unredirected recipient. */
  admitted: boolean
  /** Whether the pool oracle currently reports the exact par price. */
  atPar: boolean
  /** Whether the oracle's latest report is within the pool's maximum age; the pool rejects older ones. */
  oracleFresh: boolean
  /** Vault-asset inventory held by the pool: the maximum private deposit. */
  depositLiquidity: bigint
  /** Private-asset inventory held by the pool: the maximum private redemption output. */
  redeemLiquidity: bigint
}

/** Contract reads plus the latest block time, which bounds the oracle report's age. */
type ReadClient = Pick<PublicClient, 'readContract'> & {
  getBlock: () => Promise<{ timestamp: bigint }>
}

/** Reads the router's live pool admission, price, freshness, and inventory snapshot. */
export async function read(client: ReadClient, earnRouter: Address): Promise<Status> {
  const [[paused, admitted, atPar, depositLiquidity, redeemLiquidity], oracleFresh] =
    await Promise.all([
      client.readContract({
        abi: earnRouterAbi,
        address: earnRouter,
        functionName: 'liquidityStatus',
      }),
      readOracleFresh(client, earnRouter),
    ])
  return { paused, admitted, atPar, oracleFresh, depositLiquidity, redeemLiquidity }
}

/** `liquidityStatus` compares only the price, so read the report age against the pool's limit. */
async function readOracleFresh(client: ReadClient, earnRouter: Address) {
  try {
    const pool = await client.readContract({
      abi: earnRouterAbi,
      address: earnRouter,
      functionName: 'pool',
    })
    return (await oracleFreshness(client, pool)) === undefined
  } catch {
    return false
  }
}

/** One pool inventory side and the private flow it fills. */
type Inventory = {
  balance: bigint
  decimals: number
  flow: Action
  symbol: string
  token: Address
}

/** The router's immutable pool binding with its live readiness and inventory. */
export type Snapshot = {
  customerId: Hex
  inventory: readonly [Inventory, Inventory]
  pool: Address
  status: Status
}

/** Reads the router's pool binding and its live readiness and inventory for display. */
export async function readSnapshot(
  client: ReadClient,
  deployment: CatalogStack,
): Promise<Snapshot> {
  const earnRouter = deployment.contracts.earnRouter
  if (!earnRouter) throw new Error('The deployment does not have an EarnRouter.')
  const [pool, customerId, privateAsset, vaultAsset, status] = await Promise.all([
    client.readContract({ address: earnRouter, abi: earnRouterAbi, functionName: 'pool' }),
    client.readContract({ address: earnRouter, abi: earnRouterAbi, functionName: 'customerId' }),
    client.readContract({ address: earnRouter, abi: earnRouterAbi, functionName: 'privateAsset' }),
    client.readContract({ address: earnRouter, abi: earnRouterAbi, functionName: 'vaultAsset' }),
    read(client, earnRouter),
  ])
  const side = (flow: Action, token: Address, balance: bigint): Inventory => {
    const metadata = tokenMetadata(deployment, token)
    return {
      balance,
      decimals: metadata.decimals,
      flow,
      symbol: metadata.symbol,
      token: getAddress(token),
    }
  }
  return {
    customerId,
    inventory: [
      side('deposit', vaultAsset, status.depositLiquidity),
      side('redeem', privateAsset, status.redeemLiquidity),
    ],
    pool: getAddress(pool),
    status,
  }
}

/** Returns why the pool cannot convert at all, or `undefined` when its state permits conversion. */
export function unavailableReason(status: Status) {
  if (status.paused) return 'the conversion pool is paused'
  if (!status.admitted) return 'the conversion pool has not admitted this EarnRouter'
  if (!status.atPar) return 'the conversion pool oracle is unavailable or off par'
  if (!status.oracleFresh) return 'the conversion pool oracle report is stale'
  return undefined
}

/**
 * Rejects a private action the pool cannot fill. Conversion is exactly 1:1 with no partial fills,
 * so a deposit needs vault-asset inventory for its input and a redemption needs private-asset
 * inventory for its expected output.
 */
export function assertConvertible(options: assertConvertible.Options) {
  const { action, amount, status, token } = options
  const { noun } = actions[action]
  const reason = unavailableReason(status)
  if (reason) throw new UserFacingError(`Private ${noun}s are unavailable: ${reason}.`)
  const liquidity = status[privateFlow(action).inventory]
  if (amount > liquidity) {
    throw new UserFacingError(
      `This private ${noun} needs ${formatUnits(amount, token.decimals)} ${token.symbol} of conversion liquidity, but the pool holds ${formatUnits(liquidity, token.decimals)} ${token.symbol}.`,
    )
  }
}

export declare namespace assertConvertible {
  type Options = {
    action: Action
    /** Private deposit input, or expected private redemption output. */
    amount: bigint
    status: Status
    /** Metadata of the pool inventory token the action consumes. */
    token: { decimals: number; symbol: string }
  }
}
