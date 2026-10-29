import { stringify } from 'viem'
import { Abis } from 'viem/tempo'
import { earnVaultAbi } from '@tempoxyz/contracts/abis'
import type { E2eContext } from './context.js'
import { moduleIntegrity } from './modules.js'
import { assert } from './support/utils.js'

/** Pause and access state, plus each capability module's own snapshot; see `E2eModule.integrity`. */
export async function captureCaseIntegrity(context: E2eContext) {
  const vault = { address: context.contracts.earnVault, abi: earnVaultAbi } as const
  const [depositsPaused, operator, emergencyGuardian, transferPolicyId, ...modules] =
    await Promise.all([
      context.l1Public.readContract({ ...vault, functionName: 'depositsPaused' }),
      context.l1Public.readContract({ ...vault, functionName: 'operator' }),
      context.l1Public.readContract({ ...vault, functionName: 'emergencyGuardian' }),
      context.l1Public.readContract({
        address: context.contracts.earnShare,
        abi: Abis.tip20,
        functionName: 'transferPolicyId',
      }),
      ...moduleIntegrity.map(async ([id, capture]) => [id, await capture(context)] as const),
    ])
  return {
    depositsPaused,
    operator,
    emergencyGuardian,
    transferPolicyId,
    modules: Object.fromEntries(modules),
  }
}

export async function assertCaseIntegrity(
  context: E2eContext,
  baseline: Awaited<ReturnType<typeof captureCaseIntegrity>>,
) {
  const current = await captureCaseIntegrity(context)
  assert(
    stringify(current) === stringify(baseline),
    'case did not restore pause/access state or a module invariant (such as router custody, allowances, or conversion-pool admission)',
  )
}
