import {
  getAbiItem,
  getAddress,
  zeroAddress,
  type Account,
  type Address,
  type Chain,
  type Client,
  type PublicClient,
  type Transport,
} from 'viem'
import { simulateContract } from 'viem/actions'
import { Abis, Actions, Addresses } from 'viem/tempo'

import { earnFeesAbi, earnVaultAbi } from '../../abis/index.js'
import type { EarnDeploymentProfile } from '../../core/profile.js'
import { stackAddress, type EarnStack } from '../../core/stack.js'
import { accessMemberContracts, capabilityModules } from '../index.js'
import { transferPolicyId } from './profile.js'

type ReadClient = Pick<PublicClient, 'readContract'>
type LogClient = ReadClient & Pick<PublicClient, 'getBlockNumber' | 'getLogs'>

const redeemRequested = getAbiItem({ abi: earnVaultAbi, name: 'RedeemRequested' })

/**
 * Required policy membership, derived from deployment principals: every fee recipient, the EarnVault
 * and EarnFees, every capability's principals, and every step-created access member with the
 * principals it pays. Authorities that never hold EarnShare (owner, deployer, fee distributor) are
 * not members. `requiredAccessMembers` derives the same set from a live stack.
 */
export function accessMembers(profile: EarnDeploymentProfile, outputs: Record<string, Address>) {
  if (transferPolicyId(profile) === undefined) return []
  const protectedFee = profile.core.fees.protectedFixed
  const members = new Set<Address>([
    ...profile.core.fees.fixed.map((fee) => fee.recipient),
    ...(protectedFee && protectedFee.rateBps !== 0 ? [protectedFee.recipient] : []),
    ...(profile.core.fees.excess ? [profile.core.fees.excess.recipient] : []),
  ])
  for (const key of ['earnVault', 'earnFees'] as const) {
    if (outputs[key]) members.add(outputs[key])
  }
  for (const module of capabilityModules) {
    for (const principal of module.accessPrincipals?.(profile, outputs) ?? [])
      members.add(principal)
  }
  for (const { step, output, member } of accessMemberContracts) {
    if (outputs[output]) members.add(outputs[output])
    if (member !== true && step.enabled(profile)) {
      for (const principal of Object.values(member.principals)) members.add(principal(profile))
    }
  }
  return [...members]
}

/** The protected stack's TIP-403 whitelist and its live administrator; open access fails. */
export function requireProtectedAccess(deployment: EarnStack) {
  if (deployment.access.kind !== 'tip403-whitelist') {
    throw new Error('This operation requires a protected TIP-403 deployment')
  }
  const accessAdministrator = deployment.operations.accessAdministrator
  if (!accessAdministrator) {
    throw new Error('Protected deployment is missing its access administrator')
  }
  return { access: deployment.access, accessAdministrator }
}

/** Resolves a virtual address to its registered master, which is what TIP-403 authorizes. */
export async function resolveAccessAddress(client: Client, target: Address) {
  if (getAddress(target) === zeroAddress) throw new Error('Zero address cannot be allowlisted')
  const resolved = await Actions.virtualAddress.resolve(client, { address: target })
  if (!resolved) throw new Error(`Virtual address ${target} has no registered master`)
  return getAddress(resolved)
}

export async function readAccessStatus(client: ReadClient, deployment: EarnStack, target: Address) {
  const { access } = requireProtectedAccess(deployment)
  const eligible = await client.readContract({
    address: Addresses.tip403Registry,
    abi: Abis.tip403Registry,
    functionName: 'isAuthorized',
    args: [BigInt(access.transferPolicyId), target],
  })
  return { eligible }
}

/**
 * Every protocol address that moves EarnShare or the asset and so must stay on a protected
 * EarnShare's whitelist: the core contracts, each deployed step-created access member with the
 * principals it reads onchain, every capability's live principals, the owner, and the fee recipient.
 */
export async function requiredAccessMembers(client: ReadClient, deployment: EarnStack) {
  const contracts = accessMemberContracts.flatMap(({ output, member }) => {
    const address = stackAddress(deployment, output)
    return address ? [{ address, member }] : []
  })
  const [feeRecipients, principals, capabilityPrincipals] = await Promise.all([
    currentFeeRecipients(client, deployment.contracts.earnFees),
    Promise.all(
      contracts.flatMap(({ address, member }) =>
        member === true
          ? []
          : Object.keys(member.principals).map(
              (functionName) =>
                client.readContract({ address, abi: member.abi, functionName }) as Promise<Address>,
            ),
      ),
    ),
    Promise.all(
      capabilityModules.map((module) => module.stackAccessPrincipals?.(client, deployment) ?? []),
    ),
  ])
  return [
    deployment.contracts.earnVault,
    deployment.contracts.earnFees,
    ...contracts.map(({ address }) => address),
    ...principals,
    ...capabilityPrincipals.flat(),
    ...feeRecipients,
  ]
}

/** Every account the current EarnFees configuration pays, read live: the operator can change them. */
async function currentFeeRecipients(client: ReadClient, earnFees: Address) {
  const configId = await client.readContract({
    address: earnFees,
    abi: earnFeesAbi,
    functionName: 'currentFeeConfigId',
  })
  const config = await client.readContract({
    address: earnFees,
    abi: earnFeesAbi,
    functionName: 'feeConfig',
    args: [configId],
  })
  return [
    ...config.fixedFees.slice(0, config.fixedFeeCount).map((fee) => fee.account),
    ...(config.excess.enabled ? [config.excess.account] : []),
  ]
}

/**
 * Refuses to remove a required protocol member or an account with an open async claim, which
 * could then never be paid.
 */
export async function assertAccessRemovalSafe(
  client: LogClient,
  deployment: EarnStack,
  target: Address,
) {
  requireProtectedAccess(deployment)
  const required = await requiredAccessMembers(client, deployment)
  if (required.some((address) => getAddress(address) === getAddress(target))) {
    throw new Error(`Refusing to remove required protocol address ${target}`)
  }
  if (!deployment.metadata.deployedAtBlock) return
  const head = await client.getBlockNumber({ cacheTime: 0 })
  const firstBlock = BigInt(deployment.metadata.deployedAtBlock)
  const maxBlockRange = 100_000n
  for (let fromBlock = firstBlock; fromBlock <= head; fromBlock += maxBlockRange) {
    const toBlock = fromBlock + maxBlockRange - 1n < head ? fromBlock + maxBlockRange - 1n : head
    const logs = await client.getLogs({
      address: deployment.contracts.earnVault,
      event: redeemRequested,
      fromBlock,
      toBlock,
      args: { receiver: target },
    })
    for (const log of logs) {
      const requestId = log.args.requestId
      if (!requestId) continue
      const pending = await client.readContract({
        address: deployment.contracts.earnVault,
        abi: earnVaultAbi,
        functionName: 'pendingRedeem',
        args: [requestId],
      })
      if (pending.open) {
        throw new Error(`Address ${target} has open async claim ${requestId}; removal is unsafe`)
      }
    }
  }
}

/**
 * Adds or removes one whitelist member as the access administrator `wallet`, checking removal
 * safety first, and confirms the readback.
 */
export async function setAccessEligibility(parameters: {
  client: LogClient
  deployment: EarnStack
  target: Address
  allowed: boolean
  wallet: Client<Transport, Chain, Account>
}) {
  const { access } = requireProtectedAccess(parameters.deployment)
  if (!parameters.allowed) {
    await assertAccessRemovalSafe(parameters.client, parameters.deployment, parameters.target)
  }
  const whitelist = {
    policyId: BigInt(access.transferPolicyId),
    address: parameters.target,
    allowed: parameters.allowed,
  }
  await simulateContract(parameters.wallet, Actions.policy.modifyWhitelist.call(whitelist))
  const result = await Actions.policy.modifyWhitelistSync(parameters.wallet, whitelist)
  const status = await readAccessStatus(parameters.client, parameters.deployment, parameters.target)
  if (status.eligible !== parameters.allowed) {
    throw new Error('Policy readback did not match the requested membership update')
  }
  return { ...status, transactionHash: result.receipt.transactionHash }
}
