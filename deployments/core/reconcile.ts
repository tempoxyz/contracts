import {
  engineDefinitions,
  inspectEngineBindings,
  readEngineBinding,
} from '../modules/earn/engines/index.js'
import { existsSync, readFileSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { getAbiItem, getAddress, zeroAddress, type Address, type PublicClient } from 'viem'
import { address, object } from './parse.js'
import { deploymentActions, planEarnDeployment, type EarnDeploymentAction } from './plan.js'
import {
  configuredEngineAddress,
  deploysEngine,
  earnFactoryDeployParams,
  engineOwnerAccepted,
  profileEngineFactory,
  type EarnDeploymentProfile,
} from './profile.js'
import {
  runtimeCodeHash,
  validateSharedFactoryRelease,
  type SharedFactoryRuntimeCodeHashes,
} from './releases.js'
import { inspectEarnDeployment } from './inspection.js'
import { foundryProcessEnvironment } from '../chain/foundry.js'
import {
  completeAction,
  foundryOutputPath,
  loadPendingDeployment,
  savePendingDeployment,
  stageFoundryOutputs,
  syncFoundryOutputs,
  type PendingDeployment,
} from './pending.js'
import { pendingDeploymentPath } from './bundle.js'
import { rpcClient } from '../chain/runtime.js'
import {
  authorityStep,
  capabilityModules,
  deploymentStep,
} from '../../deployments/modules/index.js'
import { foundryScript, required } from '../../deployments/modules/module.js'
import { earnEngineBindingAbi, earnFactoryAbi, earnFeesAbi, earnVaultAbi } from '../abis/index.js'

export type ReconciliationStep =
  | { kind: 'complete'; pending: PendingDeployment }
  | {
      kind: 'handoff'
      action: EarnDeploymentAction
      instructions: string
      pending: PendingDeployment
    }
  | {
      kind: 'foundry'
      action: EarnDeploymentAction
      arguments: string[]
      environment: Record<string, string>
      /** Whether the step needs Forge's raw gas estimate; see `FoundryStep.rawGasEstimate`. */
      rawGasEstimate: boolean
      /** The script's `run(Input)` calldata, also part of `arguments`. */
      calldata: `0x${string}`
      pending: PendingDeployment
      outputPath: string
    }

/**
 * Reconciles one action at a time. Pending state is only a cache: external handoffs and recovered
 * Foundry outputs are accepted only after their desired state is observed onchain.
 */
export async function prepareLifecycleStep(options: {
  root: string
  profilePath: string
  profile: EarnDeploymentProfile
  rpcUrl: string
  environment: NodeJS.ProcessEnv
  actions?: EarnDeploymentAction[] | undefined
  discoveredOutputs?: Record<string, `0x${string}`> | undefined
}): Promise<ReconciliationStep> {
  const { profile, profilePath } = options
  const client = rpcClient(options.rpcUrl)
  syncFoundryOutputs(options.root, profilePath)
  let pending = loadPendingDeployment(profilePath, profile)
  if (options.discoveredOutputs) {
    pending = { ...pending, outputs: { ...pending.outputs, ...options.discoveredOutputs } }
    savePendingDeployment(profilePath, profile, pending)
  }
  const recoveredCore = await recoverBoundCoreOutputs(client, pending.outputs)
  if (recoveredCore !== pending.outputs) {
    pending = { ...pending, outputs: recoveredCore }
    savePendingDeployment(profilePath, profile, pending)
  }
  const complete = (action: EarnDeploymentAction, transactions: `0x${string}`[] = []) => {
    pending = completeAction(pending, action.id, 'chain', transactions)
    savePendingDeployment(profilePath, profile, pending)
  }

  for (const action of options.actions ?? planEarnDeployment(profile)) {
    const step = deploymentStep(action.id)
    // Each activation acts on a published deployment, so it is inspected again first.
    if (step.execution === 'authority' && step.phase === 'activation') {
      await inspectEarnDeployment(client, profile, pending.outputs)
    }
    if (await step.satisfied(client, profile, pending.outputs)) {
      if (!pending.actions[action.id]) complete(action)
      continue
    }
    if (step.execution === 'authority') {
      return {
        kind: 'handoff',
        action,
        instructions: authorityStep(action.id).handoff(profile, pending.outputs),
        pending,
      }
    }
    if (pending.actions[action.id]) {
      throw new Error(
        `Pending deployment marks ${action.id} complete, but its expected state is no longer present onchain`,
      )
    }
    // An interrupted run may have deployed before recording; adopt its outputs once satisfied.
    const outputPath = foundryOutputPath(options.root, profilePath)
    const recoveredOutputs = readActionOutputs(pendingDeploymentPath(profilePath))
    if (Object.keys(recoveredOutputs).length > 0) {
      const outputs = { ...pending.outputs, ...recoveredOutputs }
      if (await step.satisfied(client, profile, outputs)) {
        pending = { ...pending, outputs }
        complete(
          action,
          // Every profile on a chain shares the script's latest broadcast file, and it can lack the
          // receipt; the factory's own event names the transaction that created this stack.
          action.id === 'deploy-core'
            ? [
                await creationTransaction(
                  client,
                  profile.factories.earn,
                  required(outputs.earnShare, 'Recovered earnShare output'),
                ),
              ]
            : successfulBroadcastTransactions(
                options.root,
                foundryScript(step, profile),
                step.input(profile, outputs, outputPath),
                profile.chainId,
              ),
        )
        continue
      }
    }

    // The prediction is occupied, so the factory call could only revert: adopt that stack.
    if (action.id === 'deploy-core') {
      const adopted = await adoptPredictedCore(client, profile, pending.outputs)
      if (adopted) {
        pending = { ...pending, outputs: adopted.outputs }
        complete(action, [adopted.transaction])
        continue
      }
    }

    savePendingDeployment(profilePath, profile, pending)
    stageFoundryOutputs(options.root, profilePath)
    const calldata = step.input(profile, pending.outputs, outputPath)
    return {
      kind: 'foundry',
      action,
      arguments: [
        'script',
        foundryScript(step, profile),
        '--sig',
        calldata,
        '--network',
        'tempo',
        '--broadcast',
        '--rpc-url',
        options.rpcUrl,
      ],
      // Only the deployer key reaches Forge; every other input is typed calldata.
      environment: foundryProcessEnvironment(options.environment),
      calldata,
      rawGasEstimate: step.rawGasEstimate === true,
      pending,
      outputPath,
    }
  }

  return { kind: 'complete', pending }
}

export async function recordFoundryAction(options: {
  root: string
  profilePath: string
  profile: EarnDeploymentProfile
  rpcUrl: string
  step: Extract<ReconciliationStep, { kind: 'foundry' }>
}) {
  syncFoundryOutputs(options.root, options.profilePath)
  const outputs = {
    ...options.step.pending.outputs,
    ...readActionOutputs(pendingDeploymentPath(options.profilePath)),
  }
  await requireSatisfied(options, outputs, 'exited successfully')
  const pending = completeAction(
    { ...options.step.pending, outputs },
    options.step.action.id,
    'broadcast',
    successfulBroadcastTransactions(
      options.root,
      required(options.step.arguments[1], 'Foundry target'),
      options.step.calldata,
      options.profile.chainId,
    ),
  )
  savePendingDeployment(options.profilePath, options.profile, pending)
  return pending
}

/** Records an authority transaction only after its exact desired state is observed onchain. */
export async function recordAuthorityAction(options: {
  root: string
  profilePath: string
  profile: EarnDeploymentProfile
  rpcUrl: string
  step: Extract<ReconciliationStep, { kind: 'handoff' }>
  transactions: `0x${string}`[]
}) {
  await requireSatisfied(options, options.step.pending.outputs, 'transaction succeeded')
  const pending = completeAction(
    options.step.pending,
    options.step.action.id,
    options.transactions.length > 0 ? 'broadcast' : 'chain',
    options.transactions,
  )
  savePendingDeployment(options.profilePath, options.profile, pending)
  return pending
}

async function requireSatisfied(
  options: {
    profile: EarnDeploymentProfile
    rpcUrl: string
    step: { action: EarnDeploymentAction }
  },
  outputs: Record<string, Address>,
  outcome: string,
) {
  const { id } = options.step.action
  if (!(await deploymentStep(id).satisfied(rpcClient(options.rpcUrl), options.profile, outputs))) {
    throw new Error(`${id} ${outcome} but its expected state was not found onchain`)
  }
}

/** Read-only validation before any key is consumed. Existing engines are fully ownership-checked. */
export async function preflightEarnDeployment(
  profile: EarnDeploymentProfile,
  rpcUrl: string,
  expectedEarnVault?: Address,
  expectedFactoryRuntimeCodeHashes?: SharedFactoryRuntimeCodeHashes,
  poolInspectionMode: 'ready' | 'bindings' = 'ready',
) {
  const client = rpcClient(rpcUrl)
  const chainId = await client.getChainId()
  if (chainId !== profile.chainId)
    throw new Error(`RPC chain ID ${chainId} does not match target ${profile.chainId}`)
  await Promise.all(
    preflightAddresses(profile).map(([label, address]) => runtimeCodeHash(client, address, label)),
  )
  if (expectedFactoryRuntimeCodeHashes) {
    await validateSharedFactoryRelease(client, profile, expectedFactoryRuntimeCodeHashes)
  }
  for (const module of capabilityModules) await module.preflight?.(client, profile)
  const existingEngine = configuredEngineAddress(profile)
  if (existingEngine) {
    const { asset, owner, earnVault, vaultOperator } = await readEngineBinding(
      client,
      existingEngine,
    )
    if (asset === zeroAddress) throw new Error('Existing engine has a zero asset')
    await inspectEngineBindings(client, profile.engine.kind, existingEngine, poolInspectionMode)
    if (earnVault !== zeroAddress) {
      if (earnVault !== expectedEarnVault)
        throw new Error(`Existing engine is already bound to ${earnVault}`)
      if (!engineOwnerAccepted(profile, owner, vaultOperator)) {
        throw new Error(
          `Existing engine owner is ${owner}, expected ${profile.owner} or EarnVault operator ${vaultOperator}`,
        )
      }
    }
  }
}

/** Verifies every derived action without broadcasting or mutating pending deployment state. */
export async function verifyEarnDeploymentState(
  profile: EarnDeploymentProfile,
  rpcUrl: string,
  outputs: Record<string, Address>,
  factoryDeploymentId?: `0x${string}` | null,
  actions = deploymentActions(profile),
) {
  await preflightEarnDeployment(profile, rpcUrl, outputs.earnVault, undefined, 'bindings')
  const client = rpcClient(rpcUrl)
  for (const action of actions) {
    const satisfied = await deploymentStep(action.id).satisfied(client, profile, outputs)
    if (!satisfied) throw new Error(`Deployment action ${action.id} is not satisfied onchain`)
  }
  return await inspectEarnDeployment(client, profile, outputs, factoryDeploymentId)
}

const earnStackDeployed = getAbiItem({ abi: earnFactoryAbi, name: 'EarnStackDeployed' })
const maxLogBlockRange = 100_000n

/**
 * Adopts a stack already created with this profile's exact factory parameters, by another account
 * or by a run that left no Foundry outputs, with the transaction that created it:
 * `EarnFactory.deploy` is permissionless and refuses an occupied EarnShare prediction, so
 * `deploy-core` could otherwise never complete. Both CREATE2 predictions cover every creation-time
 * parameter, and inspection checks the stack again before a record is written.
 */
async function adoptPredictedCore(
  client: Pick<PublicClient, 'getBlockNumber' | 'getCode' | 'getLogs' | 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  const engine = configuredEngineAddress(profile) ?? outputs.engine
  if (!engine) return undefined
  const params = earnFactoryDeployParams(profile, engine)
  const factory = { address: profile.factories.earn, abi: earnFactoryAbi, args: [params] } as const
  const [earnShare, earnFees] = await Promise.all([
    client.readContract({ ...factory, functionName: 'predictEarnShare' }),
    client.readContract({ ...factory, functionName: 'predictEarnFees' }),
  ])
  const code = await client.getCode({ address: earnShare })
  if (!code || code === '0x') return undefined
  const earnVault = getAddress(
    await client.readContract({ address: earnFees, abi: earnFeesAbi, functionName: 'earnVault' }),
  )
  const vault = { address: earnVault, abi: earnVaultAbi } as const
  const [vaultShare, vaultFees, vaultEngine] = await Promise.all([
    client.readContract({ ...vault, functionName: 'earnShare' }),
    client.readContract({ ...vault, functionName: 'earnFees' }),
    client.readContract({ ...vault, functionName: 'engine' }),
  ])
  if (
    getAddress(vaultShare) !== getAddress(earnShare) ||
    getAddress(vaultFees) !== getAddress(earnFees) ||
    getAddress(vaultEngine) !== getAddress(engine)
  ) {
    throw new Error(`Predicted EarnShare ${earnShare} exists, but its stack is not this profile's`)
  }
  // Record what DeployEarnCore records: a configured engine never runs deploy-engine.
  const asset = await client.readContract({
    address: engine,
    abi: earnEngineBindingAbi,
    functionName: 'asset',
  })
  return {
    outputs: {
      ...outputs,
      engine: getAddress(engine),
      asset: getAddress(asset),
      earnVault,
      earnShare: getAddress(earnShare),
      earnFees: getAddress(earnFees),
    },
    transaction: await creationTransaction(client, profile.factories.earn, earnShare),
  }
}

/** The factory transaction that deployed `earnShare`'s stack, searched back from the head. */
async function creationTransaction(
  client: Pick<PublicClient, 'getBlockNumber' | 'getLogs'>,
  factory: Address,
  earnShare: Address,
) {
  for (let toBlock = await client.getBlockNumber(); toBlock >= 0n; toBlock -= maxLogBlockRange) {
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
  throw new Error(`No EarnStackDeployed event names the predicted EarnShare ${earnShare}`)
}

async function recoverBoundCoreOutputs(
  client: Pick<PublicClient, 'readContract'>,
  outputs: Record<string, Address>,
) {
  if (!outputs.engine || outputs.earnVault) return outputs
  const { earnVault } = await readEngineBinding(client, outputs.engine)
  if (earnVault === zeroAddress) return outputs
  const [earnShare, earnFees] = await Promise.all([
    client.readContract({ address: earnVault, abi: earnVaultAbi, functionName: 'earnShare' }),
    client.readContract({ address: earnVault, abi: earnVaultAbi, functionName: 'earnFees' }),
  ])
  return {
    ...outputs,
    earnVault,
    earnShare: getAddress(earnShare),
    earnFees: getAddress(earnFees),
  }
}

/** Resume caches may contain discovery metadata; only contract identity is commit-ready output. */
function preflightAddresses(profile: EarnDeploymentProfile): Array<[string, Address]> {
  const addresses: Array<[string, Address]> = [['EarnFactory', profile.factories.earn]]
  if (deploysEngine(profile)) {
    const factory = profileEngineFactory(profile)
    addresses.push(
      [factory.contract, factory.address],
      [engineDefinitions[profile.engine.kind].venueLabel, profile.engine.venue],
    )
  } else
    addresses.push([
      'existing engine',
      required(configuredEngineAddress(profile), 'engine.address'),
    ])
  return addresses
}

function readActionOutputs(path: string): Record<string, `0x${string}`> {
  if (!existsSync(path)) return {}
  const raw = object(JSON.parse(readFileSync(path, 'utf8')), path)
  if (raw.latestOutputs === undefined) return {}
  return Object.fromEntries(
    Object.entries(object(raw.latestOutputs, `${path}.latestOutputs`)).map(([key, value]) => [
      key,
      address(value, `${path}.latestOutputs.${key}`),
    ]),
  )
}

/** Forge names a calldata invocation's latest broadcast after the function selector. */
function successfulBroadcastTransactions(
  root: string,
  target: string,
  calldata: `0x${string}`,
  chainId: number,
): `0x${string}`[] {
  const script = basename(required(target.split(':')[0], 'Foundry script'))
  const latest = `${calldata.slice(2, 10)}-latest.json`
  const path = resolve(root, 'broadcast', script, String(chainId), latest)
  if (!existsSync(path)) return []
  const raw = JSON.parse(readFileSync(path, 'utf8')) as {
    transactions?: Array<{ hash?: unknown }>
    receipts?: Array<{ transactionHash?: unknown; status?: unknown }>
  }
  const successful = new Set(
    (raw.receipts ?? []).flatMap((receipt) =>
      receipt.status === '0x1' && typeof receipt.transactionHash === 'string'
        ? [receipt.transactionHash.toLowerCase()]
        : [],
    ),
  )
  return (raw.transactions ?? []).flatMap((transaction) =>
    typeof transaction.hash === 'string' &&
    /^0x[0-9a-fA-F]{64}$/.test(transaction.hash) &&
    successful.has(transaction.hash.toLowerCase())
      ? [transaction.hash as `0x${string}`]
      : [],
  )
}
