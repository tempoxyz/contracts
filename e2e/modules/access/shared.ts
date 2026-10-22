import { getAddress } from 'viem'
import { Abis, Addresses } from 'viem/tempo'

import type { E2eActor, E2eContext } from '../../harness/context.js'
import { authorizeZoneActor } from '../zone/readiness.js'
import { requireProtectedAccess, setAccessEligibility } from '@tempoxyz/earn/deployments/operations'
import { E2ePrerequisiteError, waitFor } from '../../harness/support/utils.js'
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
