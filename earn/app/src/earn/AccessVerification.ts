import type { PublicEarnStack } from '@tempoxyz/contracts/deployments'
import type { Address, PublicClient } from 'viem'
import { Abis, Actions, Addresses } from 'viem/tempo'

type Client = Pick<PublicClient, 'readContract'>
type Deployment = PublicEarnStack

/** Verifies the registered EarnShare transfer policy and required system authorizations. */
export async function verify(client: Client, deployment: Deployment, issues: string[]) {
  const { earnRouter } = deployment.contracts
  const transferPolicyId = await client.readContract({
    address: deployment.contracts.earnShare,
    abi: Abis.tip20,
    functionName: 'transferPolicyId',
  })
  if (deployment.access.kind === 'open') {
    if (transferPolicyId !== 1n) {
      issues.push('Open deployment does not use the always-allow transfer policy.')
    }
    return
  }

  const expectedPolicyId = BigInt(deployment.access.transferPolicyId)
  if (transferPolicyId !== expectedPolicyId) {
    issues.push('EarnShare transfer policy does not match the registry.')
    return
  }
  const [policy, authorizations] = await Promise.all([
    client.readContract({
      address: Addresses.tip403Registry,
      abi: Abis.tip403Registry,
      functionName: 'policyData',
      args: [expectedPolicyId],
    }),
    Promise.all(
      [
        deployment.contracts.earnVault,
        deployment.contracts.earnFees,
        ...(earnRouter ? [earnRouter] : []),
      ].map((address) =>
        client.readContract({
          address: Addresses.tip403Registry,
          abi: Abis.tip403Registry,
          functionName: 'isAuthorized',
          args: [expectedPolicyId, address],
        }),
      ),
    ),
  ])
  if (policy[0] !== 0 || authorizations.some((authorized) => !authorized)) {
    issues.push('EarnShare whitelist policy configuration is invalid.')
  }
}

/** Reads whether an account is authorized by EarnShare's transfer policy. */
export async function readDepositEligibility(
  client: Client,
  deployment: Deployment,
  account: Address,
): Promise<boolean> {
  if (deployment.access.kind === 'open') return true
  const resolved = await Actions.virtualAddress.resolve(client as never, { address: account })
  if (!resolved) return false
  return client.readContract({
    address: Addresses.tip403Registry,
    abi: Abis.tip403Registry,
    functionName: 'isAuthorized',
    args: [BigInt(deployment.access.transferPolicyId), resolved],
  })
}
