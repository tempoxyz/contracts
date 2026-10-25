import { getAddress, zeroAddress, type Address } from 'viem'

import { readEngineBinding } from './index.js'
import {
  deploysEngine,
  engineOwnerAccepted,
  profileEngineFactory,
  profileFactoryDeploymentId,
  type EarnDeploymentProfile,
} from '../../core/profile.js'
import { defineFoundryStep, deployedOutputs, deployerAuthority, requiredOutput } from '../module.js'

/** Provisions the profile's engine from its venue through the engine kind's shared factory. */
export const deployEngine = defineFoundryStep({
  id: 'deploy-engine',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: "Deploy or resolve the deterministic engine through its kind's shared factory.",
  phase: 'deployment',
  intent: ['engine'],
  script: (profile) => factoryOf(profile).deployScript,
  rawGasEstimate: true,
  enabled: deploysEngine,
  input(profile, _outputs, outputPath) {
    const factory = factoryOf(profile)
    return factory.deployInput({
      expectedChainId: BigInt(profile.chainId),
      deploymentId: profileFactoryDeploymentId(profile),
      factory: factory.address,
      venue: factory.venue,
      // The deployer holds the unbound engine until binding transfers it to the final owner.
      owner: profile.deployer,
      finalOwner: profile.owner,
      outputPath,
    })
  },
  async satisfied(client, profile, outputs) {
    if (!(await deployedOutputs(client, outputs, ['engine', 'asset']))) return false
    return resolvedEngineStateSatisfied(
      profile,
      outputs,
      await readEngineBinding(client, requiredOutput(outputs, 'engine')),
    )
  },
})

function factoryOf(profile: EarnDeploymentProfile) {
  if (!deploysEngine(profile)) throw new Error(`Profile ${profile.id} reuses an existing engine`)
  return { ...profileEngineFactory(profile), venue: profile.engine.venue }
}

export function resolvedEngineStateSatisfied(
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
  state: {
    asset: Address
    owner: Address
    earnVault: Address
    vaultOperator?: Address | undefined
  },
) {
  if (getAddress(state.asset) !== requiredOutput(outputs, 'asset')) return false
  const binding = getAddress(state.earnVault)
  if (binding === zeroAddress) {
    return deploysEngine(profile) && getAddress(state.owner) === profile.deployer
  }
  return (
    engineOwnerAccepted(profile, state.owner, state.vaultOperator) &&
    (outputs.earnVault === undefined || binding === outputs.earnVault)
  )
}
