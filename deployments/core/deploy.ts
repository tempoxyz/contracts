import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { parseEnv } from 'node:util'
import { fileURLToPath } from 'node:url'

import { erc20Abi, getAddress, isHex, type Address, type Hex, type PublicClient } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import { inspectEngineBindings } from '../modules/earn/engines/index.js'
import { capabilityModules, executeAvailableAuthority } from '../../deployments/modules/index.js'
import type { DiscoveryOptions, InspectionReport } from '../../deployments/modules/module.js'
import {
  assertFoundryVersion,
  assertSourceVerifiableCompiler,
  foundryVerificationEnvironment,
} from '../chain/foundry.js'
import { activationActions, deploymentActions, type EarnDeploymentAction } from './plan.js'
import {
  loadPendingDeployment,
  removePendingDeployment,
  restorePendingDeployment,
  savePendingDeployment,
  type PendingDeployment,
} from './pending.js'
import {
  preflightEarnDeployment,
  prepareLifecycleStep,
  recordAuthorityAction,
  recordFoundryAction,
  verifyEarnDeploymentState,
  type ReconciliationStep,
} from './reconcile.js'
import type { IntentComponent } from './components.js'
import {
  changedIntentComponents,
  deploymentAddressKeysForProfile,
  deploymentTarget,
  sameDeploymentTarget,
  type DeploymentAddresses,
  type DeploymentTarget,
  type EarnDeploymentRecord,
} from './record.js'
import { rpcClient } from '../chain/runtime.js'
import { isHostedDeploymentChain } from '../chain/tempo.js'
import {
  componentDeploymentIntentHashes,
  deploysEngine,
  deploymentIntentHash,
  privilegedPrincipals,
  profileEngineFactory,
  type EarnDeploymentProfile,
} from './profile.js'
import { inspectEarnDeployment } from './inspection.js'
import { sharedFactoryRuntimeCodeHashes, type CompiledRuntimeCode } from './releases.js'
import {
  captureDeploymentSource,
  earliestDeploymentBlock,
  runtimeCodeHashes,
  verifyDeploymentProvenance,
} from './provenance.js'
import { verifyDeploymentSources, verifyRecordedDeploymentSources } from './verify.js'
import {
  loadEarnProfileBundle,
  loadEarnProfileForEnvironment,
  loadProfileDeploymentRecord,
  loadProfileDeploymentRecordForReconciliation,
  profileDeploymentPath,
  publishProfileDeploymentRecord,
} from './bundle.js'

type Handoff = Extract<ReconciliationStep, { kind: 'handoff' }>

type DeploymentSummary = {
  profile: EarnDeploymentProfile
  deploymentIntentHash: string
  addresses: Record<string, Address>
}

export type EarnDeploymentResult =
  | (DeploymentSummary & {
      state: 'complete'
      record: EarnDeploymentRecord
      recordPath: string
      /** Live capability readiness; reported, never a reconciliation failure. */
      capabilityReadiness: InspectionReport
    })
  | (DeploymentSummary & {
      state: 'handoff'
      record?: EarnDeploymentRecord
      recordPath?: string
      handoff: { action: Handoff['action']; instructions: string }
      sourceVerification?: 'pending'
      verificationInstructions?: string
    })
  | (DeploymentSummary & {
      state: 'verification-pending'
      record: EarnDeploymentRecord
      recordPath: string
      instructions: string
    })

type LifecycleOptions = {
  environment: NodeJS.ProcessEnv
  profilePath: string
  root: string
  rpcUrl: string
}

/** Reconciles one authored profile until it is complete or reaches external authority. */
export async function deployEarnProfile(options: LifecycleOptions): Promise<EarnDeploymentResult> {
  const profile = loadEarnProfileForEnvironment(options.profilePath, options.environment)
  assertNoPublicFixtureAuthority(profile, publicFixtureAddresses())
  const client = rpcClient(options.rpcUrl)
  const summary = (addresses: Record<string, Address>): DeploymentSummary => ({
    profile,
    deploymentIntentHash: deploymentIntentHash(profile),
    addresses,
  })
  const committed = existsSync(profileDeploymentPath(options.profilePath))
    ? loadProfileDeploymentRecordForReconciliation(options.profilePath, profile)
    : undefined
  // Optional components the profile changed since its record; core and engine never change in place.
  const reconciling = committed
    ? changedIntentComponents(committed.componentDeploymentIntentHashes, profile)
    : new Set<IntentComponent>()
  let pending: PendingDeployment
  if (committed) {
    await verifyDeploymentProvenance(client, committed)
    if (reconciling.size === 0) {
      if (committed.source.contractVerification !== 'pending') {
        await verifyRecordedDeploymentSources({ ...options, client, profile, record: committed })
      }
      await inspectEarnDeployment(
        client,
        profile,
        committed.addresses as Record<string, Address>,
        committed.source.factoryDeploymentId,
      )
    }
    pending = restorePendingDeployment(options.profilePath, profile, committed)
  } else {
    pending = loadPendingDeployment(options.profilePath, profile)
  }

  // A fresh deployment validates the selected release against this checkout once, then pins those
  // hashes in private resume state. Committed deployments carry durable runtime/source provenance.
  const expectedFactoryRuntimeCodeHashes = committed
    ? undefined
    : (pending.factoryRuntimeCodeHashes ??
      sharedFactoryRuntimeCodeHashes(
        (contract) => compiledRuntimeCode(options.root, contract, options.environment),
        deploysEngine(profile) ? profileEngineFactory(profile) : undefined,
      ))
  await preflightEarnDeployment(
    profile,
    options.rpcUrl,
    pending.outputs.earnVault,
    expectedFactoryRuntimeCodeHashes,
  )
  if (expectedFactoryRuntimeCodeHashes && !pending.factoryRuntimeCodeHashes) {
    pending = { ...pending, factoryRuntimeCodeHashes: expectedFactoryRuntimeCodeHashes }
    savePendingDeployment(options.profilePath, profile, pending)
  }
  const discoveredOutputs = await discoverOutputs({
    environment: options.environment,
    profile,
    rpcUrl: options.rpcUrl,
    requireLive: false,
  })
  const target = await discoverDeploymentTarget(client, profile, discoveredOutputs)
  if (committed && !sameDeploymentTarget(committed.target, target, reconciling)) {
    throw new Error(
      'Committed deployment record belongs to a different chain or capability identity',
    )
  }

  const reconcile = (actions: EarnDeploymentAction[]) =>
    reconcileEarnProfileActions({ ...options, actions, discoveredOutputs, profile })
  const deployed = await reconcile(deploymentActions(profile))
  if (deployed.kind === 'handoff') {
    return {
      state: 'handoff',
      ...summary(deployed.pending.outputs),
      handoff: { action: deployed.action, instructions: deployed.instructions },
    }
  }

  let record = reconciling.size > 0 ? undefined : committed
  let recordPath = profileDeploymentPath(options.profilePath)
  if (!record) {
    const candidate = await buildDeploymentRecord(client, {
      pending: deployed.pending,
      profile,
      root: options.root,
      target,
    })
    await verifyEarnDeploymentState(
      profile,
      options.rpcUrl,
      { ...candidate.addresses, ...discoveredOutputs },
      candidate.source.factoryDeploymentId,
    )
    recordPath = publishProfileDeploymentRecord(options.profilePath, profile, candidate)
    formatCommitReadyOutput(options.root, recordPath)
    record = loadProfileDeploymentRecord(options.profilePath, profile)
  }

  // Every activation action is attempted; the first handoff is reported afterward.
  let activationHandoff: Handoff | undefined
  for (const action of activationActions(profile)) {
    const result = await reconcile([action])
    if (result.kind === 'handoff') activationHandoff ??= result
  }

  let verificationInstructions: string | undefined
  try {
    record = await completeDeploymentSourceVerification(client, { ...options, profile, record })
  } catch (error) {
    verificationInstructions = `Source verification is pending: ${error instanceof Error ? error.message : String(error)} Re-run the same deploy command later; deployed contracts and activation will not be repeated.`
  }

  if (activationHandoff) {
    return {
      state: 'handoff',
      ...summary(record.addresses),
      record,
      recordPath,
      handoff: {
        action: activationHandoff.action,
        instructions: activationHandoff.instructions,
      },
      ...(verificationInstructions
        ? { sourceVerification: 'pending' as const, verificationInstructions }
        : {}),
    }
  }

  if (verificationInstructions) {
    return {
      state: 'verification-pending',
      ...summary(record.addresses),
      record,
      recordPath,
      instructions: verificationInstructions,
    }
  }

  removePendingDeployment(options.profilePath)
  recordPath = publishProfileDeploymentRecord(options.profilePath, profile, record)
  formatCommitReadyOutput(options.root, recordPath)
  return {
    state: 'complete',
    ...summary(record.addresses),
    record,
    recordPath,
    capabilityReadiness: await inspectEarnDeployment(
      client,
      profile,
      { ...(record.addresses as Record<string, Address>), ...discoveredOutputs },
      record.source.factoryDeploymentId,
    ),
  }
}

/**
 * Executes planned actions until they are complete or reach an authority without a local signer.
 * `executeFoundry` lets a disposable chain run the same steps under its own Foundry profile and
 * broadcast directory; `root` is where the `broadcast/` receipts are read.
 */
export async function reconcileEarnProfileActions(
  options: LifecycleOptions & {
    actions: EarnDeploymentAction[]
    discoveredOutputs: Record<string, Address>
    executeFoundry?: (step: Extract<ReconciliationStep, { kind: 'foundry' }>) => void
    profile: EarnDeploymentProfile
  },
): Promise<Extract<ReconciliationStep, { kind: 'complete' | 'handoff' }>> {
  let compilerChecked = false
  for (;;) {
    const step = await prepareLifecycleStep(options)
    if (step.kind === 'complete') return step
    if (step.kind === 'handoff') {
      const execution = await executeAvailableAuthority({
        action: step.action,
        environment: options.environment,
        outputs: step.pending.outputs,
        profile: options.profile,
        rpcUrl: options.rpcUrl,
      })
      if (!execution) return step
      await recordAuthorityAction({ ...options, step, transactions: execution.transactions })
      continue
    }

    if (options.executeFoundry) {
      options.executeFoundry(step)
    } else {
      if (isHostedDeploymentChain(options.profile.chainId)) {
        assertFoundryVersion(options.root)
        // Only a Forge step compiles and broadcasts contracts, which hosted chains must be able to
        // source verify; authority handoffs above deploy nothing.
        if (!compilerChecked) {
          assertSourceVerifiableCompiler(options.root, options.environment)
          compilerChecked = true
        }
      }
      executeFoundry(options.root, step)
    }
    await recordFoundryAction({ ...options, step })
  }
}

async function buildDeploymentRecord(
  client: PublicClient,
  options: {
    pending: PendingDeployment
    profile: EarnDeploymentProfile
    root: string
    target: DeploymentTarget
  },
): Promise<EarnDeploymentRecord> {
  const { profile } = options
  const { outputs } = options.pending
  const addresses = Object.fromEntries(
    deploymentAddressKeysForProfile(profile).flatMap((key) =>
      outputs[key] ? [[key, outputs[key]]] : [],
    ),
  ) as DeploymentAddresses
  const actions = Object.fromEntries(
    deploymentActions(profile).flatMap((action) =>
      options.pending.actions[action.id] ? [[action.id, options.pending.actions[action.id]]] : [],
    ),
  ) as EarnDeploymentRecord['actions']
  const asset = addresses.asset
  if (!asset) throw new Error('Completed deployment record is missing its asset')
  const [assetDecimals, deploymentBlock] = await Promise.all([
    client.readContract({ address: asset, abi: erc20Abi, functionName: 'decimals' }),
    earliestDeploymentBlock(client, actions),
  ])
  if (deploymentBlock === undefined) {
    throw new Error('Cannot derive deploymentBlock without a successful deployment transaction')
  }
  return {
    version: 4,
    deploymentId: profile.id,
    deployer: profile.deployer,
    owner: profile.owner,
    factories: profile.factories,
    deploymentIntentHash: deploymentIntentHash(profile),
    componentDeploymentIntentHashes: componentDeploymentIntentHashes(profile),
    target: options.target,
    assetDecimals,
    deploymentBlock: deploymentBlock.toString(),
    generatedAt: new Date().toISOString(),
    source: captureDeploymentSource({
      profile,
      root: options.root,
      contractVerification: isHostedDeploymentChain(profile.chainId) ? 'pending' : 'not-applicable',
    }),
    runtimeCodeHashes: await runtimeCodeHashes(client, addresses),
    addresses,
    actions,
  }
}

async function completeDeploymentSourceVerification(
  client: PublicClient,
  options: LifecycleOptions & { profile: EarnDeploymentProfile; record: EarnDeploymentRecord },
) {
  if (options.record.source.contractVerification !== 'pending') {
    await verifyRecordedDeploymentSources({ client, ...options })
    return options.record
  }
  const verification = await verifyDeploymentSources({ client, ...options })
  const verified: EarnDeploymentRecord = {
    ...options.record,
    source: captureDeploymentSource({
      profile: options.profile,
      root: options.root,
      ...verification,
    }),
  }
  const recordPath = publishProfileDeploymentRecord(options.profilePath, options.profile, verified)
  formatCommitReadyOutput(options.root, recordPath)
  return loadProfileDeploymentRecord(options.profilePath, options.profile)
}

/**
 * Verifies a completed adjacent record and current capability identities without changing state.
 * Each `skipLive` flag names a module's `liveCheck`, whose external chain is then reported in
 * `unverified` instead of checked.
 */
export async function verifyEarnProfile(
  options: LifecycleOptions & { skipLive?: readonly string[] },
) {
  const { profile, record } = loadEarnProfileBundle(options.profilePath)
  const skipLive = options.skipLive ?? []
  const unverified = skipLive.map((flag) => {
    const check = capabilityModules.find((module) => module.liveCheck?.flag === flag)?.liveCheck
    if (!check) throw new Error(`--skip-${flag} names no live check`)
    if (!check.applies(profile)) {
      throw new Error(`--skip-${flag} does not apply: profile ${profile.id} has no ${check.label}`)
    }
    return check.label
  })
  const client = rpcClient(options.rpcUrl)
  const discovered = await discoverOutputs({
    environment: options.environment,
    profile,
    rpcUrl: options.rpcUrl,
    skipLive,
  })
  const target = await discoverDeploymentTarget(client, profile, discovered)
  if (!sameDeploymentTarget(record.target, target)) {
    throw new Error('Deployment record belongs to a different chain or capability identity')
  }
  for (const [key, address] of Object.entries(discovered)) {
    const recorded = (record.addresses as Record<string, Address | undefined>)[key]
    if (recorded && getAddress(recorded) !== getAddress(address)) {
      throw new Error(`Deployment record ${key} does not match its current discovered identity`)
    }
  }
  const inspection = await verifyEarnDeploymentState(
    profile,
    options.rpcUrl,
    { ...record.addresses, ...discovered },
    record.source.factoryDeploymentId,
  )
  await verifyDeploymentProvenance(client, record)
  await verifyRecordedDeploymentSources({ ...options, client, profile, record })
  return {
    profile,
    deploymentIntentHash: deploymentIntentHash(profile),
    record,
    readiness:
      'address' in profile.engine
        ? await inspectEngineBindings(client, profile.engine.kind, profile.engine.address)
        : undefined,
    capabilityReadiness: inspection,
    unverified,
  }
}

function executeFoundry(root: string, step: Extract<ReconciliationStep, { kind: 'foundry' }>) {
  const result = spawnSync('forge', step.arguments, {
    cwd: root,
    // Wrangler augments NodeJS.ProcessEnv with app-only required bindings. This child intentionally
    // receives the smaller deployment allowlist instead.
    env: step.environment as NodeJS.ProcessEnv,
    stdio: 'inherit',
  })
  if (result.error) throw result.error
  if (result.status !== 0) {
    throw new Error(
      `Forge failed while executing ${step.action.id} (status ${result.status ?? 'unknown'})`,
    )
  }
}

function formatCommitReadyOutput(root: string, outputPath: string) {
  const result = spawnSync('pnpm', ['exec', 'vp', 'fmt', outputPath], {
    cwd: root,
    encoding: 'utf8',
  })
  if (result.error) throw result.error
  if (result.status !== 0) {
    throw new Error(
      `Could not format commit-ready deployment result ${outputPath}: ${result.stderr.trim()}`,
    )
  }
}

/**
 * The live external addresses every configured capability uses but does not deploy, such as a
 * Zone's Portal. With `requireLive: false`, only the L1 is required; `skipLive` lists the
 * `liveCheck` flags of modules that skip their live check.
 */
export async function discoverOutputs(
  options: Omit<DiscoveryOptions, 'requireLive'> & {
    requireLive?: boolean
    skipLive?: readonly string[]
  },
) {
  const { requireLive = true, skipLive = [], ...discovery } = options
  const outputs: Record<string, Address> = {}
  for (const module of capabilityModules) {
    const skipped = module.liveCheck !== undefined && skipLive.includes(module.liveCheck.flag)
    Object.assign(
      outputs,
      await module.discover?.({ ...discovery, requireLive: requireLive && !skipped }),
    )
  }
  return outputs
}

/** Reads the chain's genesis and binds each capability's discovered identity into the target. */
async function discoverDeploymentTarget(
  client: PublicClient,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  const genesis = await client.getBlock({ blockNumber: 0n })
  if (!genesis.hash) throw new Error(`Chain ${profile.chainId} has no genesis hash`)
  return deploymentTarget(profile, genesis.hash, outputs)
}

/**
 * Refuses a hosted deployment whose privileged roles are held by an identity anyone can recover
 * from the checked-in `.env.example` template, including an owner defaulted from its deployer.
 */
export function assertNoPublicFixtureAuthority(
  profile: EarnDeploymentProfile,
  fixtureAddresses: ReadonlySet<Address>,
) {
  const exposed = privilegedPrincipals(profile).find(([, address]) =>
    fixtureAddresses.has(getAddress(address)),
  )
  if (exposed) {
    throw new Error(
      `Profile ${profile.id} ${exposed[0]} is the public fixture identity ${exposed[1]} from .env.example`,
    )
  }
}

/** The checked-in deployment environment template at the repository root. */
const environmentTemplate = fileURLToPath(new URL('../../.env.example', import.meta.url))

export function publicFixtureAddresses() {
  const values = parseEnv(readFileSync(environmentTemplate, 'utf8'))
  return new Set(
    Object.entries(values).flatMap(([name, value]) =>
      name.endsWith('_PRIVATE_KEY') &&
      typeof value === 'string' &&
      /^0x[0-9a-fA-F]{64}$/.test(value)
        ? [getAddress(privateKeyToAccount(value as Hex).address)]
        : [],
    ),
  )
}

/** Compiles one release contract with the deploy profile and reads its immutable slots. */
function compiledRuntimeCode(
  root: string,
  contract: string,
  environment: Readonly<Record<string, string | undefined>>,
): CompiledRuntimeCode {
  const [source, name] = contract.split(':')
  if (!source || !name) throw new Error(`Invalid Foundry contract identifier ${contract}`)
  const bytecode = execFileSync('forge', ['inspect', contract, 'deployedBytecode'], {
    cwd: root,
    encoding: 'utf8',
    env: foundryVerificationEnvironment(environment) as NodeJS.ProcessEnv,
  }).trim()
  if (!isHex(bytecode) || bytecode === '0x') {
    throw new Error(`Forge returned invalid deployed bytecode for ${contract}`)
  }
  const artifact = JSON.parse(
    readFileSync(resolve(root, 'out', 'deploy', basename(source), `${name}.json`), 'utf8'),
  ) as {
    deployedBytecode?: {
      immutableReferences?: Record<string, { start: number; length: number }[]>
    }
  }
  return {
    bytecode,
    references: Object.values(artifact.deployedBytecode?.immutableReferences ?? {}).flat(),
  }
}
