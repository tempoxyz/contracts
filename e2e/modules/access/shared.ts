import { encodeFunctionData, erc20Abi, getAddress, type Address } from 'viem'
import { Abis, Addresses } from 'viem/tempo'

import type { E2eActor, E2eContext } from '../../harness/context.js'
import { authorizeZoneActor } from '../zone/readiness.js'
import {
  readAccessStatus,
  requireProtectedAccess,
  setAccessEligibility,
} from '@tempoxyz/contracts/deployments/operations'
import { assert, E2ePrerequisiteError, waitFor } from '../../harness/support/utils.js'
import { waitForSuccessfulWrite } from '../../harness/support/transactions.js'

export const DEPOSIT = 1_000_000n
export const REWARD = 100_000n

export function protectedAccessConfiguration(context: E2eContext) {
  if (context.deployment.access.kind !== 'tip403-whitelist') {
    throw new E2ePrerequisiteError('Hosted deployment does not use protected TIP-403 access')
  }
  const result = requireProtectedAccess(context.deployment)
  if (getAddress(result.accessAdministrator) !== getAddress(context.accessAdministrator.address)) {
    throw new Error('Configured access-administrator key does not match the deployment registry')
  }
  return result
}

export function protectedAccess(context: E2eContext) {
  protectedAccessConfiguration(context)
}

/** Refuses restricted policy read lanes before a case funds actors or changes L1 membership. */
export async function requirePolicyZoneRead(context: E2eContext) {
  if (!context.policyZoneClient) return
  const { access } = protectedAccessConfiguration(context)
  try {
    await authorizeZoneActor(context, 'user')
    await context.policyZoneClient.readContract({
      address: Addresses.tip403Registry,
      abi: Abis.tip403Registry,
      functionName: 'isAuthorized',
      args: [BigInt(access.transferPolicyId), context.outsider.address],
    })
  } catch (cause) {
    throw new E2ePrerequisiteError(
      'Configured Zone RPC cannot read mirrored TIP-403 policies; an explicitly authorized public-policy read endpoint is required',
      { cause },
    )
  }
}

/**
 * Changes the outsider's eligibility on L1 and, on a Zone stack, waits until the Zone's mirrored
 * policy agrees.
 */
export async function setOutsiderEligibility(context: E2eContext, allowed: boolean) {
  const { access } = protectedAccessConfiguration(context)
  const result = await setAccessEligibility({
    client: context.l1Public,
    deployment: context.deployment,
    target: context.outsider.address,
    allowed,
    wallet: context.actors.accessAdministrator.wallet,
  })
  if (!context.policyZoneClient) return result
  const policyZoneClient = context.policyZoneClient
  const policyId = BigInt(access.transferPolicyId)
  await authorizeZoneActor(context, 'user')
  await waitFor(
    `Zone outsider eligibility ${allowed ? 'enablement' : 'removal'}`,
    async () => {
      const eligible = await policyZoneClient.readContract({
        address: Addresses.tip403Registry,
        abi: Abis.tip403Registry,
        functionName: 'isAuthorized',
        args: [policyId, context.outsider.address],
      })
      return eligible === allowed ? true : undefined
    },
    { intervalMs: context.pollingInterval },
  )
  return result
}

/** Restores the original L1 membership even if the initial write's Zone readback fails. */
export async function withOutsiderEligibility<result>(
  context: E2eContext,
  allowed: boolean,
  run: () => Promise<result>,
): Promise<result> {
  const before = await readAccessStatus(
    context.l1Public,
    context.deployment,
    context.outsider.address,
  )
  try {
    await setOutsiderEligibility(context, allowed)
    return await run()
  } finally {
    try {
      await setOutsiderEligibility(context, before.eligible)
    } finally {
      // Zone authorization and readback cannot prevent independent L1 restoration verification.
      const after = await readAccessStatus(
        context.l1Public,
        context.deployment,
        context.outsider.address,
      )
      assert(after.eligible === before.eligible, 'Outsider L1 membership was not restored')
    }
  }
}

/** Temporarily approves one spender, restoring and verifying even an existing nonzero allowance. */
export async function withEarnShareAllowance<result>(
  context: E2eContext,
  spender: Address,
  amount: bigint,
  run: () => Promise<result>,
): Promise<result> {
  const allowance = () =>
    context.l1Public.readContract({
      address: context.contracts.earnShare,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [context.user.address, spender],
    })
  const approve = (value: bigint) =>
    sendEarnShareCall(
      context,
      'user',
      encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [spender, value] }),
    )
  const before = await allowance()
  try {
    await approve(amount)
    return await run()
  } finally {
    try {
      await approve(before)
    } finally {
      assert((await allowance()) === before, 'EarnShare allowance was not restored')
    }
  }
}

export async function sendEarnShareCall(context: E2eContext, actor: E2eActor, data: `0x${string}`) {
  return waitForSuccessfulWrite(context, await submitEarnShareCall(context, actor, data))
}

export async function submitEarnShareCall(
  context: E2eContext,
  actor: E2eActor,
  data: `0x${string}`,
) {
  const { account, wallet } = context.actors[actor]
  return wallet.sendTransaction({
    account,
    calls: [{ to: context.contracts.earnShare, data }],
    chain: wallet.chain,
    feeToken: context.deployment.network.pathUsd,
    forceAtomic: true,
  })
}
