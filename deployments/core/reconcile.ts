import {
  engineDefinitions,
  inspectEngineBindings,
  readEngineBinding,
} from '../modules/earn/engines/index.js'
import { existsSync, readFileSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { zeroAddress, type Address } from 'viem'
import { object } from './parse.js'
import { deploymentActions, planEarnDeployment, type EarnDeploymentAction } from './plan.js'
import {
  configuredEngineAddress,
  deploysEngine,
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
import { readCurrentEngine } from './stack.js'
import {
  assertFoundryProjectEnvironment,
  foundryProcessEnvironment,
  foundryProjectRoot,
  foundryRpcEnvironment,
} from '../chain/foundry.js'
import {
  completeAction,
  foundryOutputPath,
  foundryBroadcastPath,
  parsePendingOutputs,
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
  resolvePredictedCore,
} from '../../deployments/modules/index.js'
import { foundryScript, required } from '../../deployments/modules/module.js'

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
      /** The Foundry project directory Forge runs in: Earn's, or the sibling `FoundryStep.project`. */
      root: string
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
    // Discovery metadata is a fresh set, not an append-only list of former principals.
    const retained = Object.fromEntries(
      Object.entries(pending.outputs).filter(
        ([key]) => !capabilityModules.some((module) => module.metadataOutput?.(key)),
      ),
    )
    pending = { ...pending, outputs: { ...retained, ...options.discoveredOutputs } }
    savePendingDeployment(profilePath, profile, pending)
  }
  const complete = (action: EarnDeploymentAction, transactions: `0x${string}`[] = []) => {
    pending = completeAction(pending, action.id, 'chain', transactions)
    savePendingDeployment(profilePath, profile, pending)
  }

  for (const action of options.actions ?? planEarnDeployment(profile)) {
    const step = deploymentStep(action.id)
    // Each activation acts on a published deployment, so it is inspected again first.
    const inspection =
      step.execution === 'authority' && step.phase === 'activation'
        ? await inspectEarnDeployment(client, profile, pending.outputs)
        : undefined
    if (await step.satisfied(client, profile, pending.outputs)) {
      if (!pending.actions[action.id]) {
        const adopted =
          step.execution === 'foundry' && step.adopt
            ? await step.adopt(client, profile, pending.outputs)
            : undefined
        if (adopted) pending = { ...pending, outputs: adopted.outputs }
        complete(action, adopted ? [adopted.transaction] : [])
      }
      continue
    }
    if (step.execution === 'authority') {
      return {
        kind: 'handoff',
        action,
        instructions: [
          authorityStep(action.id).handoff(profile, pending.outputs),
          ...Object.values(inspection ?? {}).flatMap((capability) =>
            capability.blockers.length > 0
              ? [
                  `${capability.label}: ${capability.blockers.join('; ')}. Review and resolve these blockers before approving this action.`,
                ]
              : [],
          ),
        ].join('\n'),
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
        const adopted = step.adopt ? await step.adopt(client, profile, outputs) : undefined
        if (adopted) pending = { ...pending, outputs: adopted.outputs }
        complete(
          action,
          adopted
            ? [adopted.transaction]
            : successfulBroadcastTransactions(
                foundryBroadcastPath(options.root, profilePath),
                foundryScript(step, profile),
                step.input(profile, outputs, outputPath),
                profile.chainId,
              ),
        )
        continue
      }
    }

    // Another deployer created this step's contract through the same factory: adopt it.
    const adopted = step.adopt ? await step.adopt(client, profile, pending.outputs) : undefined
    if (adopted && (await step.satisfied(client, profile, adopted.outputs))) {
      pending = { ...pending, outputs: adopted.outputs }
      complete(action, [adopted.transaction])
      continue
    }

    savePendingDeployment(profilePath, profile, pending)
    stageFoundryOutputs(options.root, profilePath)
    const calldata = step.input(profile, pending.outputs, outputPath)
    const root = foundryProjectRoot(options.root, step.project)
    assertFoundryProjectEnvironment(root)
    return {
      kind: 'foundry',
      action,
      root,
      arguments: [
        'script',
        foundryScript(step, profile),
        '--sig',
        calldata,
        '--network',
        'tempo',
        '--broadcast',
      ],
      // Only the deployer key reaches Forge; every other input is typed calldata. A sibling project's
      // receipts go to `<root>/broadcast` too, where they are read back.
      environment: {
        ...foundryRpcEnvironment(foundryProcessEnvironment(options.environment), options.rpcUrl),
        FOUNDRY_BROADCAST: foundryBroadcastPath(options.root, profilePath),
      },
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
  // A factory call can return a contract someone created after planning; record the transaction
  // that created it, which the factory's event names, rather than this run's call.
  const step = deploymentStep(options.step.action.id)
  const created =
    step.execution === 'foundry' && step.adopt
      ? await step.adopt(rpcClient(options.rpcUrl), options.profile, outputs)
      : undefined
  const transactions = created
    ? [created.transaction]
    : successfulBroadcastTransactions(
        options.step.environment.FOUNDRY_BROADCAST ??
          foundryBroadcastPath(options.root, options.profilePath),
        required(options.step.arguments[1], 'Foundry target'),
        options.step.calldata,
        options.profile.chainId,
      )
  const pending = completeAction(
    { ...options.step.pending, outputs },
    options.step.action.id,
    transactions.length > 0 ? 'broadcast' : 'chain',
    transactions,
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
  outputs: Record<string, Address> = {},
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
  for (const module of capabilityModules) await module.preflight?.(client, profile, outputs)
  const existingEngine = configuredEngineAddress(profile)
  if (existingEngine) {
    const { asset, owner, earnVault, vaultOperator } = await readEngineBinding(
      client,
      existingEngine,
    )
    if (asset === zeroAddress) throw new Error('Existing engine has a zero asset')
    if (earnVault === zeroAddress && owner === zeroAddress)
      throw new Error(`Existing engine ${existingEngine} has no owner to initialize its vault`)
    if (earnVault !== zeroAddress) {
      const expected =
        expectedEarnVault ??
        (await resolvePredictedCore(client, profile, { ...outputs, engine: existingEngine }))
          ?.earnVault
      if (earnVault !== expected)
        throw new Error(
          `Existing engine is already bound to ${earnVault}, not this profile's predicted vault`,
        )
      const current = await readCurrentEngine(client, {
        creationEngine: existingEngine,
        engineKind: profile.engine.kind,
        asset,
        earnVault,
      })
      if (current.engine !== existingEngine && profile.core.migrationMode !== 'OperatorEnabled')
        throw new Error('Configured immutable vault cannot migrate its engine')
      await inspectEngineBindings(client, current.engineKind, current.engine, poolInspectionMode)
      const currentOwner =
        current.engine === existingEngine
          ? owner
          : (await readEngineBinding(client, current.engine)).owner
      if (!engineOwnerAccepted(profile, currentOwner, vaultOperator)) {
        throw new Error(
          `Current engine owner is ${currentOwner}, expected ${profile.owner} or EarnVault operator ${vaultOperator}`,
        )
      }
    } else
      await inspectEngineBindings(client, profile.engine.kind, existingEngine, poolInspectionMode)
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
  await preflightEarnDeployment(profile, rpcUrl, outputs.earnVault, undefined, 'bindings', outputs)
  const client = rpcClient(rpcUrl)
  for (const action of actions) {
    const satisfied = await deploymentStep(action.id).satisfied(client, profile, outputs)
    if (!satisfied) throw new Error(`Deployment action ${action.id} is not satisfied onchain`)
  }
  return await inspectEarnDeployment(client, profile, outputs, factoryDeploymentId)
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
  return parsePendingOutputs(raw.latestOutputs, `${path}.latestOutputs`)
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
  const path = resolve(root, script, String(chainId), latest)
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
