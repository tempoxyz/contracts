import { getAddress, zeroAddress, type Address } from 'viem'

import { assertEngineIdentity, resolvePredictedCore } from '../core/steps.js'
import { readEngineBinding } from './index.js'
import { earnVaultAbi } from '../../../abis/index.js'
import {
  deploysEngine,
  engineOwnerAccepted,
  profileEngineFactory,
  profileFactoryDeploymentId,
  type EarnDeploymentProfile,
} from '../../../core/profile.js'
import {
  defineFoundryStep,
  deployedOutputs,
  deployerAuthority,
  requiredOutput,
} from '../../../../deployments/modules/module.js'

/** Provisions the profile's engine from its venue through the engine kind's shared factory. */
export const deployEngine = defineFoundryStep({
  id: 'deploy-engine',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: "Deploy or resolve the deterministic engine through its kind's shared factory.",
  phase: 'deployment',
  intent: ['engine'],
  creationEvent(profile) {
    const factory = factoryOf(profile)
    return { address: factory.address, event: factory.creationEvent, argument: 'engine' }
  },
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
    await assertEngineIdentity(client, profile, outputs)
    const state = await readEngineBinding(client, requiredOutput(outputs, 'engine'))
    if (state.earnVault !== zeroAddress) {
      const core = await resolvePredictedCore(client, profile, outputs)
      if (!core || state.earnVault !== core.earnVault)
        throw new Error(
          `Engine is already bound to ${state.earnVault}, not this profile's predicted stack; use a new deployment identity`,
        )
      const active = getAddress(
        await client.readContract({
          address: core.earnVault,
          abi: earnVaultAbi,
          functionName: 'engine',
        }),
      )
      // A migrated stack is governed by its active engine, not its retired creation engine's owner.
      const owner =
        active === outputs.engine ? state.owner : (await readEngineBinding(client, active)).owner
      return resolvedEngineStateSatisfied(
        profile,
        { ...outputs, earnVault: core.earnVault },
        { ...state, owner },
      )
    }
    return resolvedEngineStateSatisfied(profile, outputs, state)
  },
  async adopt(client, profile, outputs) {
    const factory = factoryOf(profile)
    const engine = getAddress(
      await factory.predictEngine(client, factory.address, {
        deploymentId: profileFactoryDeploymentId(profile),
        venue: factory.venue,
        owner: profile.deployer,
      }),
    )
    const code = await client.getCode({ address: engine })
    if (!code || code === '0x') return undefined
    const asset = getAddress(await factory.venueAsset(client, factory.venue))
    const resolved = { ...outputs, engine, asset }
    if (!(await deployEngine.satisfied(client, profile, resolved)))
      throw new Error(`Predicted engine ${engine} does not satisfy this profile`)
    // A successful idempotent call is not the engine's creation; use its factory event instead.
    for (let attempt = 0; attempt < 2; attempt++) {
      for (
        let toBlock = await client.getBlockNumber({ cacheTime: 0 });
        toBlock >= 0n;
        toBlock -= 100_000n
      ) {
        const fromBlock = toBlock >= 100_000n ? toBlock - 100_000n + 1n : 0n
        const [log] = await client.getLogs({
          address: factory.address,
          event: factory.creationEvent,
          args: { engine },
          fromBlock,
          toBlock,
        })
        if (log) return { outputs: resolved, transaction: log.transactionHash }
        if (fromBlock === 0n) break
      }
    }
    throw new Error(
      `RPC did not return the factory creation event for engine ${engine}; retry with a synchronized RPC`,
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
    outputs.earnVault !== undefined &&
    binding === outputs.earnVault
  )
}
