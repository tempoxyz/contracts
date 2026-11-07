import {
  encodeFunctionData,
  getAbiItem,
  getAddress,
  zeroAddress,
  type Address,
  type PublicClient,
} from 'viem'

import {
  deployEarnCoreScriptAbi,
  earnEngineBindingAbi,
  earnVaultAbi,
  earnFactoryAbi,
  earnFeesAbi,
} from '../../../abis/index.js'
import {
  deploysEngine,
  engineAddress,
  earnFactoryDeployParams,
  engineOwnerAccepted,
  configuredEngineAddress,
  profileEngineFactory,
  profileFactoryDeploymentId,
  type EarnDeploymentProfile,
} from '../../../core/profile.js'
import { readEngineBinding } from '../engines/index.js'
import { readCurrentEngine } from '../../../core/stack.js'
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
  creates: ['core'],
  creationEvent: (profile) => ({
    address: profile.factories.earn,
    event: earnStackDeployed,
    argument: 'earnVault',
    output: 'earnVault',
  }),
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
    await assertEngineIdentity(client, profile, outputs)
    const vault = requiredOutput(outputs, 'earnVault')
    const predicted = await predictedCore(client, profile, outputs)
    if (
      predicted.earnShare !== requiredOutput(outputs, 'earnShare') ||
      predicted.earnFees !== requiredOutput(outputs, 'earnFees')
    )
      throw new Error('Recovered core does not match this profile’s factory predictions')
    const [engine, share, fees] = await Promise.all([
      client.readContract({ address: vault, abi: earnVaultAbi, functionName: 'engine' }),
      client.readContract({ address: vault, abi: earnVaultAbi, functionName: 'earnShare' }),
      client.readContract({ address: vault, abi: earnVaultAbi, functionName: 'earnFees' }),
    ])
    if (getAddress(engine) !== engineAddress(profile, outputs)) {
      if (profile.core.migrationMode !== 'OperatorEnabled')
        throw new Error('Immutable EarnVault reports a different engine')
      await readCurrentEngine(client, {
        creationEngine: engineAddress(profile, outputs),
        engineKind: profile.engine.kind,
        asset: getAddress(
          await client.readContract({
            address: engineAddress(profile, outputs),
            abi: earnEngineBindingAbi,
            functionName: 'asset',
          }),
        ),
        earnVault: vault,
      })
    }
    const [asset, vaultAsset, feesVault] = await Promise.all([
      client.readContract({
        address: engineAddress(profile, outputs),
        abi: earnEngineBindingAbi,
        functionName: 'asset',
      }),
      client.readContract({ address: vault, abi: earnVaultAbi, functionName: 'asset' }),
      client.readContract({
        address: predicted.earnFees,
        abi: earnFeesAbi,
        functionName: 'earnVault',
      }),
    ])
    return (
      getAddress(asset) === getAddress(vaultAsset) &&
      getAddress(feesVault) === vault &&
      getAddress(share) === requiredOutput(outputs, 'earnShare') &&
      getAddress(fees) === requiredOutput(outputs, 'earnFees')
    )
  },
  adopt: adoptPredictedCore,
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
    if (!(await deployCore.satisfied(client, profile, outputs)))
      throw new Error(
        'Cannot bind engine: the target core has not passed factory and reciprocal binding checks',
      )
    const binding = await readEngineBinding(client, engineAddress(profile, outputs))
    if (
      binding.earnVault !== zeroAddress &&
      binding.earnVault !== requiredOutput(outputs, 'earnVault')
    )
      throw new Error(
        `Engine is already bound to ${binding.earnVault}; it cannot be rebound to ${requiredOutput(outputs, 'earnVault')}`,
      )
    if (binding.earnVault !== requiredOutput(outputs, 'earnVault')) return false
    const active = getAddress(
      await client.readContract({
        address: binding.earnVault,
        abi: earnVaultAbi,
        functionName: 'engine',
      }),
    )
    // After migration the retired engine's owner has no authority over the active stack.
    const owner =
      active === engineAddress(profile, outputs)
        ? binding.owner
        : (await readEngineBinding(client, active)).owner
    return engineOwnerAccepted(profile, owner, binding.vaultOperator)
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
    if (!(await deployCore.satisfied(client as never, options.profile, options.outputs)))
      throw new Error(
        'Cannot bind engine: the target core has not passed factory and reciprocal binding checks',
      )
    const { earnVault: current, owner } = await readEngineBinding(client, engine)
    if (current === vault) {
      if (await bindCore.satisfied(client as never, options.profile, options.outputs))
        return { transactions: [] }
      throw new Error(
        `Engine ${engine} is already bound but owned by ${owner}; complete the outstanding two-step transfer to ${options.profile.owner}`,
      )
    }
    if (current !== zeroAddress)
      throw new Error(
        `Engine ${engine} is already bound to ${current}; it cannot be rebound to ${vault}`,
      )
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

/** Checks the creation engine before any recovered output can select a core or bind target. */
export async function assertEngineIdentity(
  client: Pick<PublicClient, 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  const actual = engineAddress(profile, outputs)
  if (outputs.engine && getAddress(outputs.engine) !== actual)
    throw new Error('Recovered engine differs from the configured engine')
  if (!deploysEngine(profile)) return
  const factory = profileEngineFactory(profile)
  const expected = await factory.predictEngine(client, factory.address, {
    deploymentId: profileFactoryDeploymentId(profile),
    venue: profile.engine.venue,
    owner: profile.deployer,
  })
  if (getAddress(expected) !== actual)
    throw new Error(`Recovered engine ${actual} does not match factory prediction ${expected}`)
}

async function predictedCore(
  client: Pick<PublicClient, 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  const factory = {
    address: profile.factories.earn,
    abi: earnFactoryAbi,
    args: [earnFactoryDeployParams(profile, engineAddress(profile, outputs))],
  } as const
  const [earnShare, earnFees] = await Promise.all([
    client.readContract({ ...factory, functionName: 'predictEarnShare' }),
    client.readContract({ ...factory, functionName: 'predictEarnFees' }),
  ])
  return { earnShare: getAddress(earnShare), earnFees: getAddress(earnFees) }
}

/** Resolves only a stack at this profile's predictions, never the engine's arbitrary bind target. */
export async function resolvePredictedCore(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  const engine = configuredEngineAddress(profile) ?? outputs.engine
  if (!engine) return undefined
  await assertEngineIdentity(client, profile, outputs)
  const { earnShare, earnFees } = await predictedCore(client, profile, outputs)
  const code = await client.getCode({ address: earnShare })
  if (!code || code === '0x') return undefined
  const earnVault = getAddress(
    await client.readContract({ address: earnFees, abi: earnFeesAbi, functionName: 'earnVault' }),
  )
  const asset = getAddress(
    await client.readContract({
      address: engine,
      abi: earnEngineBindingAbi,
      functionName: 'asset',
    }),
  )
  const resolved = { ...outputs, engine, asset, earnVault, earnShare, earnFees }
  if (!(await deployCore.satisfied(client as never, profile, resolved)))
    throw new Error(`Predicted EarnShare ${earnShare} exists, but its stack is not this profile's`)
  return resolved
}

async function adoptPredictedCore(
  client: Pick<PublicClient, 'getBlockNumber' | 'getCode' | 'getLogs' | 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  const resolved = await resolvePredictedCore(client, profile, outputs)
  if (!resolved) return undefined
  return {
    outputs: resolved,
    transaction: await creationTransaction(client, profile.factories.earn, resolved.earnShare),
  }
}

const earnStackDeployed = getAbiItem({ abi: earnFactoryAbi, name: 'EarnStackDeployed' })
const maxLogBlockRange = 100_000n

/** Refreshes the head and retries a missing event before reporting inconsistent RPC evidence. */
async function creationTransaction(
  client: Pick<PublicClient, 'getBlockNumber' | 'getLogs'>,
  factory: Address,
  earnShare: Address,
) {
  for (let attempt = 0; attempt < 2; attempt++) {
    for (
      let toBlock = await client.getBlockNumber({ cacheTime: 0 });
      toBlock >= 0n;
      toBlock -= maxLogBlockRange
    ) {
      const fromBlock = toBlock >= maxLogBlockRange ? toBlock - maxLogBlockRange + 1n : 0n
      const [log] = await client.getLogs({
        address: factory,
        event: earnStackDeployed,
        args: { earnShare },
        fromBlock,
        toBlock,
      })
      if (log) return log.transactionHash
      if (fromBlock === 0n) break
    }
  }
  throw new Error(
    `RPC did not return EarnStackDeployed for ${earnShare} after refreshing its head. Retry with a synchronized RPC; no creation receipt was recorded.`,
  )
}
