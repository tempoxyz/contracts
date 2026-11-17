import { earnRouterAbi } from '@tempoxyz/contracts/abis'
import { inspectRouterReadiness } from '@tempoxyz/contracts/deployments'
import { erc20Abi, getAddress, maxUint128, maxUint256, zeroAddress, type Address } from 'viem'
import type { DeploymentPublicClient, E2eContext, E2eStack } from '../../harness/context.js'
import { tokenBalance } from '../../harness/support/funding.js'
import { assert, ZONE_CASE_AMOUNT } from '../../harness/support/utils.js'

/**
 * The router supports exactly deposit and redeem, grants no temporary allowances at rest, and has
 * conversion inventory for one Zone case each way. Per-case snapshots check custody against its baseline.
 */
export async function validateRouter(client: DeploymentPublicClient, deployment: E2eStack) {
  const { contracts } = deployment
  const router = contracts.earnRouter
  if (!router) return
  const route = { address: router, abi: earnRouterAbi } as const
  const [pool, privateAsset, ...flows] = await Promise.all([
    client.readContract({ ...route, functionName: 'pool' }),
    client.readContract({ ...route, functionName: 'privateAsset' }),
    ...[0, 1, 2, 3].map((flow) =>
      client.readContract({
        ...route,
        functionName: 'supportsFlow',
        args: [flow],
      }),
    ),
  ])
  assert(flows[0]! && flows[1]!, 'EarnRouter does not support both closed-loop flows')
  assert(!flows[2] && !flows[3], 'EarnRouter advertises an unknown flow')
  const converting = getAddress(pool) !== zeroAddress
  // Unsolicited tokens are a preserved baseline, not evidence of operation residue.
  await routerAllowances(client, deployment, { router, pool, privateAsset })
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
 * Exact custody baselines and zero temporary allowances, plus mutable pool admission state.
 * Pool inventory legitimately moves with conversion, so its amounts are not compared.
 */
export async function routerIntegrity(context: E2eContext) {
  const router = context.contracts.earnRouter
  if (!router) return undefined
  const route = { address: router, abi: earnRouterAbi } as const
  const [pool, privateAsset, [paused, admitted, atPar]] = await Promise.all([
    context.l1Public.readContract({ ...route, functionName: 'pool' }),
    context.l1Public.readContract({ ...route, functionName: 'privateAsset' }),
    context.l1Public.readContract({
      ...route,
      functionName: 'liquidityStatus',
    }),
  ])
  // Hosted contexts need not have fixture assets, so read the router's actual private input.
  const [vaultAssetBalance, privateAssetBalance, earnShareBalance, allowances] = await Promise.all([
    tokenBalance(context, context.contracts.asset, router),
    tokenBalance(context, privateAsset, router),
    tokenBalance(context, context.contracts.earnShare, router),
    routerAllowances(context.l1Public, context.deployment, {
      router,
      pool,
      privateAsset,
    }),
  ])
  // Exact equality detects residue and deficits. Snapshots cannot attribute concurrent donations:
  // they may fail equality or offset a deficit; accepting increases would weaken the check further.
  return {
    vaultAssetBalance,
    privateAssetBalance,
    earnShareBalance,
    allowances,
    privateAsset: getAddress(privateAsset),
    pool: getAddress(pool),
    paused,
    admitted,
    atPar,
  }
}

/**
 * Checks every approval used by deposit, redemption, conversion, and return to the source Portal. The
 * immutable EarnVault and pool may hold a standing maximum (Tempo charges each zero-to-nonzero allowance
 * as a new slot); any other amount, and any Portal allowance, is a leftover.
 */
async function routerAllowances(
  client: DeploymentPublicClient,
  deployment: E2eStack,
  route: { router: Address; pool: Address; privateAsset: Address },
) {
  const { asset, earnShare, earnVault } = deployment.contracts
  const { router, pool, privateAsset } = route
  const portal = deployment.network.zone?.portal
  assert(
    portal !== undefined && getAddress(portal) !== zeroAddress,
    'EarnRouter has no source Portal',
  )
  const targets: {
    token: Address
    spender: Address
    label: string
    standing: boolean
  }[] = [
    {
      token: asset,
      spender: earnVault,
      label: 'vault asset to EarnVault',
      standing: true,
    },
    {
      token: earnShare,
      spender: earnVault,
      label: 'EarnShare to EarnVault',
      standing: true,
    },
    {
      token: privateAsset,
      spender: portal,
      label: 'private asset to source Portal',
      standing: true,
    },
    {
      token: earnShare,
      spender: portal,
      label: 'EarnShare to source Portal',
      standing: true,
    },
  ]
  if (getAddress(pool) !== zeroAddress) {
    targets.push(
      {
        token: asset,
        spender: pool,
        label: 'vault asset to conversion pool',
        standing: true,
      },
      {
        token: privateAsset,
        spender: pool,
        label: 'private asset to conversion pool',
        standing: true,
      },
    )
  }
  return Promise.all(
    targets.map(async ({ token, spender, label, standing }) => {
      const allowance = await client.readContract({
        address: token,
        abi: erc20Abi,
        functionName: 'allowance',
        args: [router, spender],
      })
      // The Portal's standing maximum shrinks by what each deposit pulls, so it is only far above any amount.
      const isStanding =
        getAddress(spender) === getAddress(portal)
          ? allowance > maxUint128
          : allowance === maxUint256
      assert(
        allowance === 0n || (standing && isStanding),
        `EarnRouter retains an allowance at rest: ${label}`,
      )
      // A standing allowance is set by the first operation, so its value is no baseline to compare.
      return standing
        ? { token: getAddress(token), spender: getAddress(spender), standing }
        : { token: getAddress(token), spender: getAddress(spender), allowance }
    }),
  )
}
