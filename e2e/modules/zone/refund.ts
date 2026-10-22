import { getAddress, type Address, type PublicClient } from 'viem'
import { zonePortalRole } from '@tempoxyz/earn/tempo/zone'
import { earnVaultAbi, zonePortalAbi } from '@tempoxyz/earn/abis'
import type { E2eContext } from '../../harness/context.js'

type Client = Pick<PublicClient, 'readContract'>

/** Tempo refund recipient per acting E2E account on an account-admission Zone. */
type ZoneRefundRecipients = ReadonlyMap<Address, Address>

const resolved = new WeakMap<object, Promise<ZoneRefundRecipients | undefined>>()

/**
 * Each acting account's verified Tempo refund recipient on a hosted Zone stack, resolved on first
 * use so runs without router returns skip the role reads. Local Zones refund every actor to itself.
 */
export function zoneRefundRecipients(context: E2eContext) {
  const zone = context.deployment.network.zone
  if (context.provider !== 'hosted' || !zone || !context.contracts.earnRouter) {
    return Promise.resolve(undefined)
  }
  let recipients = resolved.get(context.l1Public)
  if (!recipients) {
    recipients = resolveZoneRefundRecipients(context.l1Public, {
      zoneId: zone.id,
      portal: zone.portal,
      earnVault: context.contracts.earnVault,
      user: context.user.address,
      actors: [context.operator, context.outsider, context.accessAdministrator].map(
        ({ address }) => address,
      ),
    })
    resolved.set(context.l1Public, recipients)
  }
  return recipients
}

/**
 * Resolves each acting account's Tempo refund recipient for router returns.
 *
 * The Portal accepts `depositEncrypted` only when its Tempo refund recipient holds the `Account`
 * role. Every admitted actor refunds to itself. Only the primary E2E user may instead refund to
 * the stack's admitted EarnVault operator or pending operator, which the customer controls; other
 * unadmitted actors get no entry and cannot submit router returns. Returns `undefined` when the
 * Portal does not currently enforce account admission, so every actor refunds to itself.
 */
export async function resolveZoneRefundRecipients(
  client: Client,
  options: {
    zoneId: number
    portal: Address
    earnVault: Address
    user: Address
    actors: readonly Address[]
  },
): Promise<ZoneRefundRecipients | undefined> {
  const enforced = await client.readContract({
    address: options.portal,
    abi: zonePortalAbi,
    functionName: 'isAccessEnforced',
  })
  if (!enforced) return undefined
  const [operator, pendingOperator] = await Promise.all([
    client.readContract({
      address: options.earnVault,
      abi: earnVaultAbi,
      functionName: 'operator',
    }),
    client.readContract({
      address: options.earnVault,
      abi: earnVaultAbi,
      functionName: 'pendingOperator',
    }),
  ])
  const user = getAddress(options.user)
  const actors = [...new Set([user, ...options.actors.map((actor) => getAddress(actor))])]
  const candidates = [operator, pendingOperator]
    .filter((candidate) => BigInt(candidate) !== 0n)
    .map((candidate) => getAddress(candidate))
  // Refunds and manual deposits require the `Account` role under account admission.
  const accounts = [...new Set([...actors, ...candidates])]
  const admittedFlags = await Promise.all(
    accounts.map((account) =>
      client.readContract({
        address: options.portal,
        abi: zonePortalAbi,
        functionName: 'hasRole',
        args: [account, zonePortalRole.account],
      }),
    ),
  )
  const admitted = new Set(accounts.filter((_, index) => admittedFlags[index]))
  const recipients = new Map<Address, Address>()
  for (const actor of actors) {
    if (admitted.has(actor)) recipients.set(actor, actor)
  }
  if (!recipients.has(user)) {
    const fallback = candidates.find((candidate) => admitted.has(candidate))
    if (!fallback) {
      throw new Error(
        `Zone ${options.zoneId} requires an allowed Tempo refund recipient, but neither the E2E user ${user} nor the EarnVault operator or pending operator holds the Account role`,
      )
    }
    recipients.set(user, fallback)
  }
  return recipients
}
