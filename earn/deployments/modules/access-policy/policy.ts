import {
  getAddress,
  zeroAddress,
  type Address,
  type Chain,
  type Client,
  type Transport,
} from 'viem'
import { readContract } from 'viem/actions'
import { Abis, Addresses } from 'viem/tempo'
import type { DeploymentAccess } from '../../core/stack.js'

type ProtectedAccess = Extract<DeploymentAccess, { kind: 'tip403-whitelist' }>

/** Serializes an existing simple whitelist policy for the deployment registry. */
export function serializeWhitelistPolicy(policyId: bigint): ProtectedAccess {
  return {
    kind: 'tip403-whitelist',
    transferPolicyId: policyId.toString(),
  }
}

/** Parses a protected deployment's simple whitelist policy ID. */
export function parseWhitelistPolicy(access: ProtectedAccess): bigint {
  return BigInt(access.transferPolicyId)
}

/** Validates an existing simple whitelist and its required members. */
export async function validateWhitelistPolicy<chain extends Chain | undefined>(
  client: Client<Transport, chain>,
  parameters: {
    policyId: bigint
    requiredMembers: readonly Address[]
  },
): Promise<Address> {
  const { policyId, requiredMembers } = parameters
  const members = [...new Set(requiredMembers.map((member) => getAddress(member)))]
  const [policy, memberResults] = await Promise.all([
    readContract(client, {
      abi: Abis.tip403Registry,
      address: Addresses.tip403Registry,
      args: [policyId],
      functionName: 'policyData',
    }),
    Promise.all(
      members.map(async (member) => {
        const authorized = await readContract(client, {
          abi: Abis.tip403Registry,
          address: Addresses.tip403Registry,
          args: [policyId, member],
          functionName: 'isAuthorized',
        })
        return { member, authorized }
      }),
    ),
  ])

  if (policy[0] !== 0) throw new Error('TIP-403 transfer policy is not a whitelist.')
  const administrator = getAddress(policy[1])
  if (administrator === zeroAddress) throw new Error('TIP-403 whitelist has no administrator.')
  const unauthorized = memberResults.find((result) => !result.authorized)
  if (unauthorized) {
    throw new Error(`Required TIP-403 member is unauthorized: ${unauthorized.member}`)
  }
  return administrator
}

/** Validates that EarnShare directly uses the expected reusable simple whitelist. */
export async function validateEarnShareWhitelist<chain extends Chain | undefined>(
  client: Client<Transport, chain>,
  parameters: {
    earnShare: Address
    policyId: bigint
    requiredMembers: readonly Address[]
  },
): Promise<void> {
  const tokenPolicyId = await readContract(client, {
    abi: Abis.tip20,
    address: parameters.earnShare,
    functionName: 'transferPolicyId',
  })
  if (tokenPolicyId !== parameters.policyId) {
    throw new Error('EarnShare transfer policy mismatch.')
  }
  await validateWhitelistPolicy(client, parameters)
}
