import { earnRouterAbi } from '@tempoxyz/earn/abis'
import { inspectRouterReadiness } from '@tempoxyz/earn/deployments'
import { erc20Abi, getAddress, zeroAddress, type Address } from 'viem'
import type { DeploymentPublicClient, E2eContext, E2eStack } from '../../harness/context.js'
import { tokenBalance } from '../../harness/support/funding.js'
import { assert, ZONE_CASE_AMOUNT } from '../../harness/support/utils.js'

/**
 * The router supports exactly the deposit and redeem flows, holds nothing and grants its pool no
 * allowance at rest, and a converting router is ready with inventory for one Zone case each way.
 */
export async function validateRouter(client: DeploymentPublicClient, deployment: E2eStack) {
  const { contracts } = deployment
  const router = contracts.earnRouter
  if (!router) return
  const route = { address: router, abi: earnRouterAbi } as const
  const [pool, ...flows] = await Promise.all([
    client.readContract({ ...route, functionName: 'pool' }),
    ...[0, 1, 2, 3].map((flow) =>
      client.readContract({ ...route, functionName: 'supportsFlow', args: [flow] }),
    ),
  ])
  assert(flows[0]! && flows[1]!, 'EarnRouter does not support both closed-loop flows')
  assert(!flows[2] && !flows[3], 'EarnRouter advertises an unknown flow')
  const converting = getAddress(pool) !== zeroAddress
  const privateAsset = deployment.modes.private?.privateAsset
  const balance = (token: Address, owner: Address) =>
    client.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [owner] })
  const [routerAssets, routerEarnShares, ...allowances] = await Promise.all([
    balance(contracts.asset, router),
    balance(contracts.earnShare, router),
    ...(converting
      ? [contracts.asset, ...(privateAsset ? [privateAsset] : [])].map((token) =>
          client.readContract({
            address: token,
            abi: erc20Abi,
            functionName: 'allowance',
            args: [router, pool],
          }),
        )
      : []),
  ])
  assert(routerAssets === 0n, 'EarnRouter retains vault assets at rest')
  assert(routerEarnShares === 0n, 'EarnRouter retains EarnShare at rest')
  assert(
    allowances.every((allowance) => allowance === 0n),
    'EarnRouter grants its conversion pool an allowance at rest',
  )
  if (!converting || !deployment.capabilities.privateRouting) return
  const readiness = await inspectRouterReadiness(client, router, pool)
  assert(
    readiness.status === 'ready',
    `router conversion is blocked: ${readiness.blockers.join('; ')}`,
  )
  assert(
    readiness.depositLiquidity! >= ZONE_CASE_AMOUNT,
    `router conversion pool has ${readiness.depositLiquidity} vault-asset units; private deposits need at least ${ZONE_CASE_AMOUNT}`,
  )
  assert(
    readiness.redeemLiquidity! >= ZONE_CASE_AMOUNT,
    `router conversion pool has ${readiness.redeemLiquidity} private-asset units; private redemptions need at least ${ZONE_CASE_AMOUNT}`,
  )
}

/**
 * Router custody, pool allowances, and the pool's mutable admission state, which every case must
 * restore. Pool inventory legitimately moves with every conversion, so amounts are not compared.
 */
export async function routerIntegrity(context: E2eContext) {
  const router = context.contracts.earnRouter
  if (!router) return undefined
  const route = { address: router, abi: earnRouterAbi } as const
  const [pool, [paused, admitted, atPar]] = await Promise.all([
    context.l1Public.readContract({ ...route, functionName: 'pool' }),
    context.l1Public.readContract({ ...route, functionName: 'liquidityStatus' }),
  ])
  const allowance = (token: Address) =>
    context.l1Public.readContract({
      address: token,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [router, pool],
    })
  const [baseBalance, alternateBalance, earnShareBalance, baseAllowance, alternateAllowance] =
    await Promise.all([
      tokenBalance(context, context.assets.base, router),
      tokenBalance(context, context.assets.alternate, router),
      tokenBalance(context, context.contracts.earnShare, router),
      allowance(context.assets.base),
      allowance(context.assets.alternate),
    ])
  return {
    baseBalance,
    alternateBalance,
    earnShareBalance,
    baseAllowance,
    alternateAllowance,
    pool: getAddress(pool),
    paused,
    admitted,
    atPar,
  }
}
