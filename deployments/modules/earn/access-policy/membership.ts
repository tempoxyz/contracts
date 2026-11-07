import {
  getAbiItem,
  getAddress,
  zeroAddress,
  type Account,
  type Address,
  type Chain,
  type Client,
  type Hex,
  type PublicClient,
  type Transport,
} from 'viem'
import { simulateContract } from 'viem/actions'
import { Abis, Actions, Addresses } from 'viem/tempo'

import { earnFeesAbi, earnVaultAbi } from '../../../abis/index.js'
import type { EarnDeploymentProfile } from '../../../core/profile.js'
import { stackAddress, type EarnStack } from '../../../core/stack.js'
import { accessMemberContracts, capabilityModules } from '../../../../deployments/modules/index.js'
import { transferPolicyId } from './profile.js'

type ReadClient = Pick<PublicClient, 'readContract'>
type LogClient = Client & ReadClient & Pick<PublicClient, 'getBlockNumber' | 'getLogs'>

const redeemEvents = [
  getAbiItem({ abi: earnVaultAbi, name: 'RedeemRequested' }),
  getAbiItem({ abi: earnVaultAbi, name: 'RedeemFinalized' }),
  getAbiItem({ abi: earnVaultAbi, name: 'RedeemCancelled' }),
] as const

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
 * Refuses to remove an identity used by a required protocol member or open async claim receiver,
 * preserving share transfers and claim cancellation even when the receiver is a virtual alias.
 */
export async function assertAccessRemovalSafe(
  client: LogClient,
  deployment: EarnStack,
  target: Address,
) {
  requireProtectedAccess(deployment)
  const resolvedTarget = await resolveAccessAddress(client, target)
  const required = await requiredAccessMembers(client, deployment)
  const identities = await Promise.all(
    required.map((member) => resolveAccessAddress(client, member)),
  )
  if (identities.includes(resolvedTarget)) {
    throw new Error(`Refusing to remove required protocol address ${target}`)
  }
  const anchor = deployment.metadata?.deployedAtBlock
  if (typeof anchor !== 'string' || !/^(?:0x[0-9a-fA-F]+|[0-9]+)$/.test(anchor)) {
    throw new Error('Access removal requires a valid deployedAtBlock claim scan anchor')
  }
  const head = await client.getBlockNumber({ cacheTime: 0 })
  const firstBlock = BigInt(anchor)
  if (firstBlock > head) {
    throw new Error('Access removal claim scan anchor is beyond the current chain head')
  }
  const outstanding = new Set<Hex>()
  const maxBlockRange = 100_000n
  for (let fromBlock = firstBlock; fromBlock <= head; fromBlock += maxBlockRange) {
    const toBlock = fromBlock + maxBlockRange - 1n < head ? fromBlock + maxBlockRange - 1n : head
    // A receiver-topic filter would miss aliases whose effective policy identity is the target.
    const logs = await client.getLogs({
      address: deployment.contracts.earnVault,
      events: redeemEvents,
      fromBlock,
      toBlock,
      strict: true,
    })
    // Apply terminal events in order: a later request may reuse a closed engine request ID.
    logs.sort((a, b) =>
      a.blockNumber === b.blockNumber
        ? a.logIndex - b.logIndex
        : a.blockNumber < b.blockNumber
          ? -1
          : 1,
    )
    for (const log of logs) {
      if (log.eventName === 'RedeemRequested') outstanding.add(log.args.requestId)
      else outstanding.delete(log.args.requestId)
    }
  }
  // Closed history needs no eth_call; cap concurrency for the claims that remain outstanding.
  const requestIds = [...outstanding]
  const readBatchSize = 16
  for (let offset = 0; offset < requestIds.length; offset += readBatchSize) {
    await Promise.all(
      requestIds.slice(offset, offset + readBatchSize).map(async (requestId) => {
        const pending = await client.readContract({
          address: deployment.contracts.earnVault,
          abi: earnVaultAbi,
          functionName: 'pendingRedeem',
          args: [requestId],
        })
        if (!pending.open) return
        // An unregistered alias has no policy identity to remove. RPC errors still fail closed.
        const receiver = await Actions.virtualAddress.resolve(client, { address: pending.receiver })
        if (receiver && getAddress(receiver) === resolvedTarget) {
          throw new Error(`Address ${target} has open async claim ${requestId}; removal is unsafe`)
        }
      }),
    )
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
  const target = await resolveAccessAddress(parameters.client, parameters.target)
  if (!parameters.allowed) {
    await assertAccessRemovalSafe(parameters.client, parameters.deployment, target)
  }
  const whitelist = {
    policyId: BigInt(access.transferPolicyId),
    address: target,
    allowed: parameters.allowed,
  }
  await simulateContract(parameters.wallet, Actions.policy.modifyWhitelist.call(whitelist))
  const result = await Actions.policy.modifyWhitelistSync(parameters.wallet, whitelist)
  const status = await readAccessStatus(parameters.client, parameters.deployment, target)
  if (status.eligible !== parameters.allowed) {
    throw new Error('Policy readback did not match the requested membership update')
  }
  return { ...status, transactionHash: result.receipt.transactionHash }
}
