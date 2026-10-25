import { Abis } from 'viem/tempo'

import { requiredOutput, type CapabilityModule } from '../../../../deployments/modules/module.js'
import { validateWhitelistPolicy } from './policy.js'
import { transferPolicyId } from './profile.js'

/**
 * The EarnShare access capability: an open EarnShare, or one bound to a reusable TIP-403 whitelist
 * whose administrator stays mutable and is read live rather than recorded.
 */
export const accessPolicyModule: CapabilityModule = {
  async preflight(client, profile) {
    const policyId = transferPolicyId(profile)
    if (policyId === undefined) return
    await validateWhitelistPolicy(client, { policyId, requiredMembers: [] })
  },
  async inspect(client, profile, outputs) {
    const policyId = await client.readContract({
      address: requiredOutput(outputs, 'earnShare'),
      abi: Abis.tip20,
      functionName: 'transferPolicyId',
    })
    // EarnFactory binds an open EarnShare to the always-allow builtin policy 1.
    const expected = transferPolicyId(profile) ?? 1n
    if (policyId !== expected)
      throw new Error(`EarnShare policy is ${policyId}, expected ${expected}`)
    return undefined
  },
  async stack({ client, profile }) {
    if (profile.access.kind === 'open') return { access: { kind: 'open' } }
    const accessAdministrator = await validateWhitelistPolicy(client, {
      policyId: BigInt(profile.access.policyId),
      requiredMembers: [],
    })
    return {
      access: { kind: 'tip403-whitelist', transferPolicyId: profile.access.policyId },
      operations: { accessAdministrator },
    }
  },
}
