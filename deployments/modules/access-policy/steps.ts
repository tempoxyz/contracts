import { encodeFunctionData } from 'viem'

import { attachEarnSharePolicyScriptAbi } from '../../abis/index.js'
import { validateEarnShareWhitelist } from './policy.js'
import { defineFoundryStep, deployerAuthority, requiredOutput } from '../module.js'

export const validateAccess = defineFoundryStep({
  id: 'validate-access',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: 'Validate the policy definition and EarnShare binding.',
  phase: 'deployment',
  intent: ['core'],
  script: 'script/deploy/AttachEarnSharePolicy.s.sol:AttachEarnSharePolicyScript',
  enabled: (profile) => profile.access.kind === 'tip403-whitelist',
  input(profile, outputs) {
    if (profile.access.kind !== 'tip403-whitelist') throw new Error(`Profile ${profile.id} is open`)
    return encodeFunctionData({
      abi: attachEarnSharePolicyScriptAbi,
      functionName: 'run',
      args: [
        {
          expectedChainId: BigInt(profile.chainId),
          policyId: BigInt(profile.access.policyId),
          earnShare: requiredOutput(outputs, 'earnShare'),
        },
      ],
    })
  },
  async satisfied(client, profile, outputs) {
    if (profile.access.kind === 'open') return true
    try {
      await validateEarnShareWhitelist(client, {
        earnShare: requiredOutput(outputs, 'earnShare'),
        policyId: BigInt(profile.access.policyId),
        requiredMembers: [],
      })
      return true
    } catch {
      return false
    }
  },
})
