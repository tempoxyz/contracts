import { encodeFunctionData, getAddress } from 'viem'

import { deployEarnCoreScriptAbi, earnEngineBindingAbi, earnVaultAbi } from '../../../abis/index.js'
import {
  deploysEngine,
  engineAddress,
  earnFactoryDeployParams,
  engineOwnerAccepted,
} from '../../../core/profile.js'
import { readEngineBinding } from '../engines/index.js'
import { privateKeyToAccount } from 'viem/accounts'

import { envPrivateKey } from '../../../chain/runtime.js'
import { privateKeyMatches, sendAuthorityCalls } from '../../../../deployments/modules/signer.js'
import {
  defineAuthorityStep,
  defineFoundryStep,
  deployedOutputs,
  deployerAuthority,
  requiredOutput,
  type StepAuthority,
} from '../../../../deployments/modules/module.js'

/** The engine's current owner; the deployer key acts only when it holds that role. */
const engineOwnerAuthority = {
  id: 'engine-owner',
  label: 'current engine owner',
  signer: 'DEPLOYER_PRIVATE_KEY',
} as const satisfies StepAuthority

export const deployCore = defineFoundryStep({
  id: 'deploy-core',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: 'Deploy EarnShare, EarnVault, and EarnFees.',
  phase: 'deployment',
  intent: ['core'],
  script: 'script/deploy/DeployEarnCore.s.sol:DeployEarnCoreScript',
  rawGasEstimate: true,
  enabled: () => true,
  input: (profile, outputs, outputPath) =>
    encodeFunctionData({
      abi: deployEarnCoreScriptAbi,
      functionName: 'run',
      args: [
        {
          expectedChainId: BigInt(profile.chainId),
          factory: profile.factories.earn,
          params: earnFactoryDeployParams(profile, engineAddress(profile, outputs)),
          outputPath,
        },
      ],
    }),
  async satisfied(client, profile, outputs) {
    if (!(await deployedOutputs(client, outputs, ['earnShare', 'earnVault', 'earnFees']))) {
      return false
    }
    const vault = requiredOutput(outputs, 'earnVault')
    const [engine, share, fees] = await Promise.all([
      client.readContract({ address: vault, abi: earnVaultAbi, functionName: 'engine' }),
      client.readContract({ address: vault, abi: earnVaultAbi, functionName: 'earnShare' }),
      client.readContract({ address: vault, abi: earnVaultAbi, functionName: 'earnFees' }),
    ])
    return (
      getAddress(engine) === engineAddress(profile, outputs) &&
      getAddress(share) === requiredOutput(outputs, 'earnShare') &&
      getAddress(fees) === requiredOutput(outputs, 'earnFees')
    )
  },
})

export const bindCore = defineAuthorityStep({
  id: 'bind-core',
  authority: engineOwnerAuthority,
  execution: 'authority',
  summary: 'Bind the engine to its EarnVault and transfer to the configured final owner.',
  handoffSummary: 'Verify the binding and final owner, or emit a current engine-owner handoff.',
  phase: 'deployment',
  intent: ['core'],
  enabled: () => true,
  async satisfied(client, profile, outputs) {
    const binding = await readEngineBinding(client, engineAddress(profile, outputs))
    return (
      binding.earnVault === requiredOutput(outputs, 'earnVault') &&
      engineOwnerAccepted(profile, binding.owner, binding.vaultOperator)
    )
  },
  handoff: (profile, outputs) =>
    `The current engine owner must call initializeEarnVault(${requiredOutput(outputs, 'earnVault')}, ${profile.owner}) on ${engineAddress(profile, outputs)} to bind the vault and transfer to the configured final owner. Re-run the same pnpm earn deploy command; it will verify the binding and continue.`,
  signerAvailable(profile, environment) {
    return deploysEngine(profile)
      ? privateKeyMatches(environment, 'DEPLOYER_PRIVATE_KEY', profile.deployer)
      : Boolean(environment.DEPLOYER_PRIVATE_KEY?.trim())
  },
  async execute(options, dependencies) {
    const key = envPrivateKey(options.environment, 'DEPLOYER_PRIVATE_KEY')
    if (!key) return undefined
    const account = privateKeyToAccount(key)
    const engine = engineAddress(options.profile, options.outputs)
    const vault = requiredOutput(options.outputs, 'earnVault')
    const client = dependencies.authorityClient(options, account)
    const { earnVault: current, owner } = await readEngineBinding(client, engine)
    if (current === vault) {
      if (owner === options.profile.owner) return { transactions: [] }
      throw new Error(
        `Engine ${engine} is already bound but owned by ${owner}; complete the outstanding two-step transfer to ${options.profile.owner}`,
      )
    }
    if (owner !== account.address) return undefined
    return await sendAuthorityCalls(client, dependencies, options.profile, [
      {
        to: engine,
        data: encodeFunctionData({
          abi: earnEngineBindingAbi,
          functionName: 'initializeEarnVault',
          args: [vault, options.profile.owner],
        }),
      },
    ])
  },
})
