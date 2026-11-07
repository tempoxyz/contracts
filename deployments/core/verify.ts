import { execFileSync, spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { isAbsolute, relative, resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'

import {
  encodeAbiParameters,
  getAddress,
  keccak256,
  parseAbiParameters,
  stringToBytes,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'

import {
  assertFoundryProjectEnvironment,
  foundryProjectRoot,
  foundryRpcEnvironment,
  foundryVerificationEnvironment,
  sourceVerificationCompilerArguments,
} from '../chain/foundry.js'
import { deploymentAddressKeys } from './components.js'
import { readEarnFactory, runtimeCodeHash } from './releases.js'
import { isHostedDeploymentChain } from '../chain/tempo.js'
import { deploysEngine, profileEngineFactory, type EarnDeploymentProfile } from './profile.js'
import {
  type ContractSourceVerification,
  type CreationFactoryVerification,
  type DeploymentSource,
  type EarnDeploymentRecord,
} from './record.js'
import { engineDefinitions } from '../modules/earn/engines/index.js'
import {
  deploymentStep,
  deploymentSteps,
  type EarnDeploymentActionId,
} from '../../deployments/modules/index.js'
import {
  assertCreationReceipt,
  assertDirectCreationTransaction,
  assertVerifiedCreationTransaction,
} from '../chain/creation.js'
import { redactRpcCredentials } from '../chain/rpc-credentials.js'
import { requiredOutput } from '../../deployments/modules/module.js'

export const tempoVerifierUrl = 'https://contracts.tempo.xyz'

const implementationSlot =
  '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc' as const
const transientVerifierErrors = new Set(['internal_error', 'compilation_failed'])
/** forge output when the verifier was unreachable, rate-limited or failing (429 or 5xx) on submission. */
const verifierUnavailableOutput =
  /status code:? (429|5\d\d)|too many requests|service unavailable|bad gateway|gateway time-?out|internal server error|error sending request|connection (refused|reset|closed)|timed out|dns error|failed to lookup address/i

type VerifiedContract = {
  match: 'exact_match' | 'match' | null
  name: string | null
  address: string
  fullyQualifiedName?: string | null
  sources?: Record<string, { content?: string }>
  transactionHash?: string | null
  /** Compiler output, not a claim that the deployment executed this initcode. */
  creationBytecode?: { bytecode?: string | null; cborAuxdata?: unknown } | null
  compiler?: string | null
  compilerVersion?: string | null
  language?: string | null
}

export type VerificationDependencies = {
  fetch: typeof fetch
  pause: (milliseconds: number) => Promise<void>
  readSource: (path: string) => string
  spawn: typeof spawnSync
  /** Extra `forge verify-contract` arguments naming the deploy profile's compiler build. */
  compilerArguments: (root: string, environment: NodeJS.ProcessEnv) => string[]
  /** The independent compiler input manifest, never paths supplied by the verifier. */
  sourcePaths: (root: string, contract: string, environment: NodeJS.ProcessEnv) => readonly string[]
}

type SourceVerificationOptions<
  Record = Pick<EarnDeploymentRecord, 'actions' | 'addresses'> & {
    source?: DeploymentSource | undefined
  },
> = {
  client: Pick<
    PublicClient,
    'getCode' | 'getStorageAt' | 'readContract' | 'getTransactionReceipt' | 'getTransaction'
  >
  environment: NodeJS.ProcessEnv
  profile: EarnDeploymentProfile
  record: Record
  root: string
  rpcUrl: string
  /** Request canonical re-verification of invalid entries; matching entries are left unchanged. */
  resubmit?: boolean
}

/** Verifies every deployment-owned Solidity artifact and classifies native/proxy outputs. */
export async function verifyDeploymentSources(
  options: SourceVerificationOptions,
  dependencies: Partial<VerificationDependencies> = {},
): Promise<Pick<DeploymentSource, 'contractVerification' | 'contracts' | 'verifierUrl'>> {
  try {
    const source = options.record.source
    const retained =
      source &&
      (source.contractVerification === 'verified' || Object.keys(source.contracts).length > 0)
        ? source.contracts
        : undefined
    if (retained && source?.verifierUrl?.replace(/\/+$/, '') !== tempoVerifierUrl)
      throw new Error(
        'Retained deployment requires recorded verification from the trusted verifier',
      )
    const observed = await inspectDeploymentSources(options, true, dependencies, retained)
    // Pending retries can add evidence for new outputs, never replace an admitted historical identity.
    for (const [key, previous] of Object.entries(retained ?? {})) {
      const output = key as keyof typeof observed.contracts
      const current = observed.contracts[output]
      const compatible =
        current &&
        previous &&
        'match' in current &&
        'match' in previous &&
        current.match === 'exact_match' &&
        previous.match === 'match'
          ? { ...current, match: 'match' }
          : current
      if (!isDeepStrictEqual(compatible, previous))
        throw new Error(
          `Recorded deployment source verification does not match current provenance for ${key}`,
        )
      observed.contracts[output] = previous
    }
    return observed
  } catch (error) {
    throw verificationError(error, options)
  }
}

/** Rechecks recorded evidence; explicit resubmission repairs verifier entries, never the recorded source identity. */
export async function verifyRecordedDeploymentSources(
  options: SourceVerificationOptions<EarnDeploymentRecord>,
  dependencies: Partial<VerificationDependencies> = {},
) {
  try {
    // A parsed record of a local chain is always `not-applicable`, with no verifier results.
    if (!isHostedDeploymentChain(options.profile.chainId)) return
    if (
      options.record.source.contractVerification !== 'verified' ||
      !options.record.source.verifierUrl
    ) {
      throw new Error(
        'Hosted deployment source verification is incomplete; rerun the deployment command',
      )
    }
    const verifierUrl = tempoVerifierUrl
    if (options.record.source.verifierUrl.replace(/\/+$/, '') !== verifierUrl) {
      throw new Error(
        `Recorded deployment verifier ${options.record.source.verifierUrl} does not match trusted verifier ${verifierUrl}`,
      )
    }
    const observed = await inspectDeploymentSources(
      options,
      options.resubmit === true,
      dependencies,
      options.record.source.contracts,
    )
    const compatible = Object.fromEntries(
      Object.entries(observed.contracts).map(([key, value]) => {
        const previous =
          options.record.source.contracts[key as keyof typeof options.record.source.contracts]
        // A stricter verifier match strengthens the same source evidence; downgrades remain a failure.
        return [
          key,
          value &&
          previous &&
          'match' in value &&
          'match' in previous &&
          value.match === 'exact_match' &&
          previous.match === 'match'
            ? { ...value, match: 'match' }
            : value,
        ]
      }),
    )
    if (!isDeepStrictEqual(compatible, options.record.source.contracts)) {
      throw new Error('Recorded deployment source verification does not match current provenance')
    }
  } catch (error) {
    throw verificationError(error, options)
  }
}

/** Rechecks one retained direct deployment against its recorded source identity and historical compilation. */
export async function verifyRecordedStepCreation(
  options: SourceVerificationOptions<EarnDeploymentRecord> & { action: EarnDeploymentActionId },
  dependencies: Partial<VerificationDependencies> = {},
) {
  try {
    const step = deploymentStep(options.action)
    if (
      step.execution !== 'foundry' ||
      !step.source ||
      step.creationEvent ||
      !step.enabled(options.profile)
    )
      throw new Error(`No direct source deployment is declared for ${options.action}`)
    if (
      !['verified', 'pending'].includes(options.record.source.contractVerification) ||
      options.record.source.verifierUrl?.replace(/\/+$/, '') !== tempoVerifierUrl
    )
      throw new Error(
        'Retained deployment requires recorded verification from the trusted verifier',
      )
    const addresses = options.record.addresses as Record<string, Address>
    const address = requiredOutput(addresses, step.source.output)
    const previous = options.record.source.contracts[step.source.output]
    if (previous?.kind !== 'source')
      throw new Error(`Recorded source identity is missing for ${address}`)
    const context: VerificationContext = {
      ...options,
      chainId: options.profile.chainId,
      verifierUrl: tempoVerifierUrl,
      runtime: verificationRuntime(dependencies),
      submitMissing: false,
      resubmit: false,
      recordedSources: new Map([[address.toLowerCase(), previous]]),
      compilerArguments: new Map(),
      directCreation: {
        client: options.client,
        deployer: options.profile.deployer,
        transactions: new Map(),
      },
    }
    const observed = await verifySource(context, {
      root: foundryProjectRoot(options.root, step.project),
      address,
      constructorArgs: step.source.constructorArgs(options.profile, addresses),
      contract: step.source.contract,
      creationTransactionHash: await creationTransactionFor(
        options,
        options.action,
        address,
        context,
      ),
      name: step.source.contract.slice(step.source.contract.lastIndexOf(':') + 1),
    })
    // A stronger match can preserve the record, but no source identity or creation evidence may change.
    const compatible =
      observed.match === 'exact_match' && previous.match === 'match'
        ? { ...observed, match: 'match' }
        : observed
    if (!isDeepStrictEqual(compatible, previous))
      throw new Error('Recorded deployment source verification does not match current provenance')
  } catch (error) {
    throw verificationError(error, options)
  }
}

async function inspectDeploymentSources(
  options: SourceVerificationOptions,
  submitMissing: boolean,
  dependencies: Partial<VerificationDependencies>,
  recordedSources?: DeploymentSource['contracts'],
): Promise<Pick<DeploymentSource, 'contractVerification' | 'contracts' | 'verifierUrl'>> {
  if (!isHostedDeploymentChain(options.profile.chainId)) {
    return { contractVerification: 'not-applicable', contracts: {}, verifierUrl: null }
  }
  const addresses = options.record.addresses as Record<string, Address>
  const context: VerificationContext = {
    ...options,
    chainId: options.profile.chainId,
    verifierUrl: tempoVerifierUrl,
    runtime: verificationRuntime(dependencies),
    submitMissing,
    recordedSources: recordedSources
      ? new Map(
          Object.entries(addresses)
            .filter(
              ([key]) =>
                options.record.source?.contractVerification !== 'pending' ||
                recordedSources[key as keyof typeof recordedSources] !== undefined,
            )
            .map(([key, address]) => [
              address.toLowerCase(),
              recordedSources[key as keyof typeof recordedSources],
            ]),
        )
      : undefined,
    compilerArguments: new Map(),
    creationFactories: new Map(),
    directCreation: {
      client: options.client,
      deployer: options.profile.deployer,
      transactions: new Map(),
    },
  }
  const engine = requiredOutput(addresses, 'engine')
  const earnVault = requiredOutput(addresses, 'earnVault')
  const earnFees = requiredOutput(addresses, 'earnFees')
  const contracts: DeploymentSource['contracts'] = {}

  const { engineContract, engineSource } = engineDefinitions[options.profile.engine.kind]
  const verifyEngine = deploysEngine(options.profile)
    ? await prepareSource(context, {
        address: engine,
        constructorArgs: profileEngineFactory(options.profile).engineConstructorArgs({
          venue: options.profile.engine.venue,
          owner: options.profile.deployer,
        }),
        contract: `${engineSource}:${engineContract}`,
        creationTransactionHash: await creationTransactionFor(
          options,
          'deploy-engine',
          engine,
          context,
        ),
        name: engineContract,
      })
    : await prepareExistingSource(context, engine, {
        name: engineContract,
        contract: `${engineSource}:${engineContract}`,
      })

  const {
    tip20Factory,
    earnVaultImplementation: vaultImplementation,
    earnFeesImplementation: feesImplementation,
  } = await readEarnFactory(options.client, options.profile.factories.earn)
  const [vaultImplementationCodeHash, feesImplementationCodeHash] = await Promise.all([
    runtimeCodeHash(options.client, vaultImplementation, 'EarnVault implementation'),
    runtimeCodeHash(options.client, feesImplementation, 'EarnFees implementation'),
  ])

  const proxyImplementation = await options.client.getStorageAt({
    address: earnVault,
    slot: implementationSlot,
  })
  const decodedProxyImplementation = storageAddress(proxyImplementation)
  if (decodedProxyImplementation !== vaultImplementation) {
    throw new Error(
      `EarnVault proxy implementation is ${decodedProxyImplementation}, expected ${vaultImplementation}`,
    )
  }
  const verifyProxy = await prepareSource(context, {
    address: earnVault,
    constructorArgs: encodeAbiParameters(parseAbiParameters('address implementation, bytes data'), [
      vaultImplementation,
      '0x',
    ]),
    contract: 'lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy',
    creationTransactionHash: await creationTransactionFor(
      options,
      'deploy-core',
      earnVault,
      context,
    ),
    name: 'ERC1967Proxy',
  })

  await requireMinimalProxy(options.client, earnFees, feesImplementation)
  contracts.earnFees = {
    kind: 'minimal-proxy',
    implementation: feesImplementation,
    implementationCodeHash: feesImplementationCodeHash,
  }
  contracts.earnShare = { kind: 'protocol-native', factory: tip20Factory }

  // Step-created contracts, in record address order.
  const created = deploymentSteps
    .flatMap((step) =>
      step.execution === 'foundry' && step.source && step.enabled(options.profile)
        ? [{ id: step.id, project: step.project, ...step.source }]
        : [],
    )
    .sort(
      (left, right) =>
        deploymentAddressKeys.indexOf(left.output) - deploymentAddressKeys.indexOf(right.output),
    )
  const prepared = []
  for (const { id, project, output, contract, constructorArgs } of created) {
    const verify = await prepareSource(context, {
      root: foundryProjectRoot(options.root, project),
      address: requiredOutput(addresses, output),
      constructorArgs: constructorArgs(options.profile, addresses),
      contract,
      creationTransactionHash: await creationTransactionFor(
        options,
        id,
        requiredOutput(addresses, output),
        context,
      ),
      name: contract.slice(contract.lastIndexOf(':') + 1),
    })
    prepared.push({ output, verify })
  }

  // Validate every planned repair before any verifier submission can change historical evidence.
  contracts.engine = await verifyEngine()
  const proxySource = await verifyProxy()
  contracts.earnVault = {
    kind: 'erc1967-proxy',
    name: 'ERC1967Proxy',
    match: proxySource.match,
    sourceInputsHash: proxySource.sourceInputsHash,
    ...(proxySource.creationFactory ? { creationFactory: proxySource.creationFactory } : {}),
    implementation: vaultImplementation,
    implementationCodeHash: vaultImplementationCodeHash,
  }
  for (const { output, verify } of prepared) contracts[output] = await verify()

  return { contractVerification: 'verified', contracts, verifierUrl: context.verifierUrl }
}

/**
 * Submits the source of one contract the profile lifecycle does not deploy, such as a test
 * fixture's existing engine, and waits for a match against the canonical checkout.
 */
export async function verifyContractSource(
  options: {
    chainId: number
    environment: NodeJS.ProcessEnv
    root: string
    rpcUrl: string
    address: Address
    /** Fully qualified `<source>:<name>`. */
    contract: string
    constructorArgs: Hex
    creationTransactionHash?: Hex
    resubmit?: boolean
  },
  dependencies: Partial<VerificationDependencies> = {},
) {
  try {
    const { address, contract, constructorArgs, creationTransactionHash, ...target } = options
    return await verifySource(
      {
        ...target,
        verifierUrl: tempoVerifierUrl,
        runtime: verificationRuntime(dependencies),
        submitMissing: true,
        compilerArguments: new Map(),
      },
      {
        address,
        constructorArgs,
        creationTransactionHash,
        contract,
        name: contract.slice(contract.lastIndexOf(':') + 1),
      },
    )
  } catch (error) {
    throw verificationError(error, options)
  }
}

// Rebuild the error: subprocess causes, enumerable fields and old stacks can retain credentials.
function verificationError(
  error: unknown,
  options: { rpcUrl: string; environment: NodeJS.ProcessEnv },
) {
  const message = redactRpcCredentials(
    error instanceof Error ? error.message : String(error),
    options.rpcUrl,
    options.environment,
  )
  return error instanceof VerifierUnavailableError
    ? new VerifierUnavailableError(message)
    : new Error(message)
}

function verificationRuntime(
  dependencies: Partial<VerificationDependencies>,
): VerificationDependencies {
  return {
    fetch,
    pause: (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
    readSource: (path) => readFileSync(path, 'utf8'),
    spawn: spawnSync,
    compilerArguments: sourceVerificationCompilerArguments,
    sourcePaths: (root, contract, environment) => {
      assertFoundryProjectEnvironment(root)
      const input = JSON.parse(
        execFileSync(
          'forge',
          [
            'verify-contract',
            '0x0000000000000000000000000000000000000001',
            contract,
            '--show-standard-json-input',
            ...sourceVerificationCompilerArguments(root, environment),
          ],
          {
            cwd: root,
            encoding: 'utf8',
            env: foundryVerificationEnvironment(environment),
            maxBuffer: 32 * 1024 * 1024,
          },
        ),
      ) as { sources?: Record<string, unknown> }
      if (!input.sources || Object.keys(input.sources).length === 0)
        throw new Error('Compiler returned no source input manifest')
      return Object.keys(input.sources)
    },
    ...dependencies,
  }
}

async function prepareExistingSource(
  context: VerificationContext,
  address: Address,
  target: { contract: string; name: string },
) {
  const contract = await lookupContract(context, address)
  if (!contract) {
    throw new Error(`Existing ${target.name} ${address} is not source verified`)
  }
  const verified = sourceMatch(context, contract, { ...target, address })
  return async () => verified
}

type SourceTarget = {
  /** The Foundry project that built the contract; Earn's when omitted. */
  root?: string | undefined
  address: Address
  constructorArgs?: Hex | undefined
  contract: string
  creationTransactionHash?: Hex | undefined
  name: string
}

async function verifySource(context: VerificationContext, target: SourceTarget) {
  return (await prepareSource(context, target))()
}

async function prepareSource(context: VerificationContext, target: SourceTarget) {
  const existing = await lookupContract(context, target.address)
  if (existing?.match) {
    let verified: ReturnType<typeof sourceMatch> | undefined
    try {
      // Even an explicit repair must leave good entries alone: exact matches cannot be replaced.
      verified = sourceMatch(context, existing, target)
    } catch (error) {
      if (!context.submitMissing || !context.resubmit) {
        throw new Error(
          `${error instanceof Error ? error.message : String(error)} Retry with --resubmit-verification to request canonical re-verification; the verifier may require operator repair.`,
          { cause: error },
        )
      }
    }
    if (verified) {
      // Source resubmission cannot change a mined constructor, so invalid initcode is never repairable here.
      await assertSourceCreation(context, existing, target)
      const source = verified
      return async () => source
    }
  }
  if (!context.submitMissing) {
    throw new Error(`${target.name} ${target.address} does not have a source match`)
  }

  requireRecordedRepairSources(context, target)
  return () => submitSource(context, target, existing)
}

async function submitSource(
  context: VerificationContext,
  target: SourceTarget,
  existing: VerifiedContract | undefined,
): Promise<Extract<ContractSourceVerification, { kind: 'source' }>> {
  const root = target.root ?? context.root
  let compilerArguments = context.compilerArguments.get(root)
  if (!compilerArguments) {
    compilerArguments = context.runtime.compilerArguments(root, context.environment)
    context.compilerArguments.set(root, compilerArguments)
  }
  let lastError = 'verification did not complete'
  let lastTransient = false
  const maximumAttempts = 6
  for (let attempt = 1; attempt <= maximumAttempts; attempt++) {
    assertFoundryProjectEnvironment(root)
    // Inputs can change while another repair runs or while a transient failure backs off.
    requireRecordedRepairSources(context, target)
    const result = context.runtime.spawn(
      'forge',
      [
        'verify-contract',
        target.address,
        target.contract,
        '--root',
        root,
        '--chain',
        String(context.chainId),
        '--verifier',
        'sourcify',
        '--verifier-url',
        context.verifierUrl,
        '--skip-is-verified-check',
        ...compilerArguments,
        ...(target.constructorArgs && target.constructorArgs !== '0x'
          ? ['--constructor-args', target.constructorArgs]
          : []),
        ...(target.creationTransactionHash
          ? ['--creation-transaction-hash', target.creationTransactionHash]
          : []),
      ],
      {
        cwd: root,
        encoding: 'utf8',
        env: foundryRpcEnvironment(
          foundryVerificationEnvironment(context.environment),
          context.rpcUrl,
        ) as NodeJS.ProcessEnv,
      },
    )
    if (result.error) throw result.error
    const verifierOutput = `${result.stdout}\n${result.stderr}`
    const jobId =
      result.status === 0 ? verifierOutput.match(/Verification Job ID: `([^`]+)`/)?.[1] : undefined
    if (!jobId) {
      // Tempo's verifier refuses replacement of exact matches, including entries missing creation metadata.
      if (existing?.match && /already[_ ]verified/i.test(verifierOutput))
        throw new Error(
          `Source verification failed for ${target.name} ${target.address}: the verifier refused replacement of its existing entry. Verifier-side repair is required; creation and source identity checks remain enforced.`,
        )
      // A submission the verifier rate-limited, failed or never answered is retried; a compile or argument error is definitive.
      lastError =
        result.status === 0
          ? 'verifier did not return a job ID'
          : `could not submit: ${result.stderr.trim()}`
      lastTransient = result.status === 0 || verifierUnavailableOutput.test(verifierOutput)
      if (!lastTransient || attempt === maximumAttempts) break
      await context.runtime.pause(Math.min(5_000 * 2 ** (attempt - 1), 30_000))
      continue
    }
    const outcome = await pollVerification(context, jobId)
    // A failed job still carries a contract object, with no match.
    if (outcome.contract?.match) {
      const verified = await lookupContract(context, target.address)
      // The lookup can lag a job that just completed; rerunning finds the source.
      if (!verified) {
        throw new VerifierUnavailableError(
          `${target.name} ${target.address} verified, but the verifier does not list its source yet`,
        )
      }
      const source = sourceMatch(context, verified, target)
      await assertSourceCreation(context, verified, target)
      return source
    }
    lastError = `${outcome.error?.customCode ?? 'unknown'}: ${outcome.error?.message ?? 'unknown error'}`
    lastTransient = transientVerifierErrors.has(outcome.error?.customCode ?? '')
    if (!lastTransient || attempt === maximumAttempts) break
    await context.runtime.pause(Math.min(5_000 * 2 ** (attempt - 1), 30_000))
  }
  const message = `Source verification failed for ${target.name} ${target.address}: ${lastError}`
  throw lastTransient ? new VerifierUnavailableError(message) : new Error(message)
}

async function lookupContract(context: VerificationContext, address: Address) {
  const url = `${context.verifierUrl}/v2/contract/${context.chainId}/${address}?fields=all`
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const response = await context.runtime.fetch(url)
      if (response.status === 404) return undefined
      if (response.ok) return (await response.json()) as VerifiedContract
      if (!transientStatus(response.status)) {
        throw new VerifierRefusedError(
          `Tempo verifier lookup failed for ${address}: HTTP ${response.status}`,
        )
      }
      if (attempt === 5) {
        throw new VerifierUnavailableError(
          `Tempo verifier lookup failed for ${address}: HTTP ${response.status}`,
        )
      }
    } catch (error) {
      // A refusal (a 4xx other than 408, 425 or 429) is definitive; anything else is the verifier being unreachable.
      if (error instanceof VerifierRefusedError) throw error
      if (attempt === 5) {
        throw error instanceof VerifierUnavailableError
          ? error
          : new VerifierUnavailableError(
              `Tempo verifier lookup failed for ${address}: ${String(error)}`,
            )
      }
    }
    await context.runtime.pause(attempt * 500)
  }
  return undefined
}

/** Whether an HTTP error status means the verifier may answer later: a timeout, too early, rate limit or 5xx. */
function transientStatus(status: number) {
  return status === 408 || status === 425 || status === 429 || status >= 500
}

async function pollVerification(context: VerificationContext, jobId: string) {
  for (let poll = 0; poll < 30; poll++) {
    const response = await context.runtime
      .fetch(`${context.verifierUrl}/v2/verify/${jobId}`)
      .catch((error: unknown) => {
        throw new VerifierUnavailableError(
          `Tempo verifier job ${jobId} is unreachable: ${String(error)}`,
        )
      })
    if (!response.ok) {
      const message = `Tempo verifier job ${jobId} returned HTTP ${response.status}`
      throw transientStatus(response.status)
        ? new VerifierUnavailableError(message)
        : new Error(message)
    }
    type Outcome = {
      contract: VerifiedContract | null
      error: { customCode: string; message: string } | null
      isJobCompleted: boolean
    }
    // The connection can drop while the body streams after a 200.
    const outcome = (await response.json().catch((error: unknown) => {
      throw new VerifierUnavailableError(
        `Tempo verifier job ${jobId} reply was cut off: ${String(error)}`,
      )
    })) as Outcome
    if (outcome.isJobCompleted) return outcome
    await context.runtime.pause(1_000)
  }
  throw new VerifierUnavailableError(`Tempo verifier job ${jobId} did not complete`)
}

function sourceMatch(
  context: VerificationContext,
  contract: VerifiedContract,
  target: {
    root?: string | undefined
    address: Address
    contract: string
    creationTransactionHash?: Hex | undefined
    name: string
  },
): Extract<ContractSourceVerification, { kind: 'source' }> {
  if (contract.match !== 'match' && contract.match !== 'exact_match') {
    throw new Error(`${target.name} ${target.address} has no source match`)
  }
  if (
    contract.name !== target.name ||
    getAddress(contract.address) !== getAddress(target.address)
  ) {
    throw new Error(
      `Verifier identified ${target.address} as ${contract.name ?? 'unknown'}, expected ${target.name}`,
    )
  }
  if (contract.fullyQualifiedName !== target.contract) {
    throw new Error(
      `Verifier identified ${target.address} as ${contract.fullyQualifiedName ?? 'unknown source'}, expected ${target.contract}`,
    )
  }
  if (
    target.creationTransactionHash &&
    contract.transactionHash?.toLowerCase() !== target.creationTransactionHash.toLowerCase()
  ) {
    throw new Error(
      `Verifier creation transaction for ${target.name} does not match the recorded deployment transaction`,
    )
  }
  const sourceInputsHash = requireCanonicalSources(
    context,
    contract,
    target.contract,
    target.root ?? context.root,
  )
  const recorded = recordedSource(context, target)
  if (
    recorded &&
    (recorded.sourceInputsHash !== sourceInputsHash ||
      (recorded.match === 'exact_match' && contract.match !== 'exact_match'))
  )
    throw new Error(
      `Recorded deployment source verification does not match current provenance for ${target.name}`,
    )
  return {
    kind: 'source',
    name: target.name,
    match: contract.match,
    sourceInputsHash,
    ...(context.creationFactories?.has(target.address.toLowerCase())
      ? { creationFactory: context.creationFactories.get(target.address.toLowerCase())! }
      : {}),
  }
}

async function assertSourceCreation(
  context: VerificationContext,
  contract: VerifiedContract,
  target: SourceTarget,
) {
  const direct = context.directCreation
  const transaction = direct?.transactions.get(target.address.toLowerCase())
  if (!direct || !transaction) return
  // The caller admits source identity first; this compilation also belongs to historical rechecks, not today's checkout.
  const creationBytecode = contract.creationBytecode?.bytecode
  if (typeof creationBytecode !== 'string' || !/^0x(?:[0-9a-fA-F]{2})+$/.test(creationBytecode))
    throw new Error(`Verifier did not return compiled creation bytecode for ${target.name}`)
  if (target.constructorArgs === undefined)
    throw new Error(`Constructor arguments are not declared for ${target.name}`)
  const options = {
    address: target.address,
    transaction,
    deployer: direct.deployer,
    creationBytecode: creationBytecode as Hex,
    constructorArgs: target.constructorArgs,
    minedTransaction: await direct.client.getTransaction({ hash: transaction }),
  }
  // Deployment separately proves fresh checkout initcode exactly; a verifier recompilation may differ only in metadata.
  if (contract.match === 'match' || recordedSource(context, target)?.match === 'match')
    assertVerifiedCreationTransaction({
      ...options,
      compiler: {
        name: contract.compiler ?? null,
        version: contract.compilerVersion ?? null,
        language: contract.language ?? null,
      },
      cborAuxdata: contract.creationBytecode?.cborAuxdata,
    })
  else assertDirectCreationTransaction(options)
}

function recordedSource(context: VerificationContext, target: Pick<SourceTarget, 'address'>) {
  if (!context.recordedSources?.has(target.address.toLowerCase())) return undefined
  const recorded = context.recordedSources.get(target.address.toLowerCase())
  if (!recorded || !('sourceInputsHash' in recorded))
    throw new Error(`Recorded source identity is missing for ${target.address}`)
  return recorded
}

function requireRecordedRepairSources(context: VerificationContext, target: SourceTarget) {
  const recorded = recordedSource(context, target)
  if (!recorded) return
  try {
    const root = target.root ?? context.root
    const paths = context.runtime.sourcePaths(root, target.contract, context.environment)
    const sourcePath = target.contract.slice(0, target.contract.lastIndexOf(':'))
    if (!paths.includes(sourcePath)) throw new Error('Compiler input manifest omits the target')
    const sources = paths.map((path): [string, string] => [
      path,
      context.runtime.readSource(checkedSourcePath(context, root, path)),
    ])
    if (sourceInputsHash(sources) !== recorded.sourceInputsHash)
      throw new Error('Current checkout does not reproduce the recorded source-input hash')
  } catch (cause) {
    throw new Error(
      `Cannot repair ${target.name} ${target.address} from this checkout. Use the recorded source revision and its pinned dependencies before resubmitting.`,
      { cause },
    )
  }
}

function checkedSourcePath(context: VerificationContext, projectRoot: string, path: string) {
  const localPath = resolve(projectRoot, path)
  const fromRoot = relative(resolve(context.root, '..'), localPath)
  if (fromRoot === '' || fromRoot.startsWith('..') || isAbsolute(fromRoot))
    throw new Error(`Verifier source path ${path} escapes the repository root`)
  return localPath
}

function sourceInputsHash(sources: [string, string][]) {
  // Fixed collation preserves hashes across operator locales, including Czech/Slovak 'ch'.
  return keccak256(
    stringToBytes(
      JSON.stringify(
        sources
          .sort(([left], [right]) => left.localeCompare(right, 'en'))
          .map(([path, content]) => [path, keccak256(stringToBytes(content))]),
      ),
    ),
  )
}

function requireCanonicalSources(
  context: VerificationContext,
  contract: VerifiedContract,
  fullyQualifiedName: string,
  projectRoot: string,
) {
  const sources = contract.sources
  const sourcePath = fullyQualifiedName.slice(0, fullyQualifiedName.lastIndexOf(':'))
  if (!sources || !sources[sourcePath]) {
    throw new Error(`Verifier did not return canonical source ${sourcePath}`)
  }
  // Source paths are relative to the contract's Foundry project, and a sibling project may import
  // Earn's sources (`../earn/src/...`); every one must resolve inside this checkout.
  const entries = Object.entries(sources)
  const recorded = recordedSource(context, { address: getAddress(contract.address) })
  if (!recorded) {
    const expected = context.runtime.sourcePaths(
      projectRoot,
      fullyQualifiedName,
      context.environment,
    )
    if (!isDeepStrictEqual([...expected].sort(), Object.keys(sources).sort()))
      throw new Error(
        `Verifier source paths do not match the complete compiler input manifest for ${fullyQualifiedName}`,
      )
  }
  for (const [relativePath, source] of entries) {
    if (typeof source.content !== 'string')
      throw new Error(`Verifier did not return source content for ${relativePath}`)
    const localPath = checkedSourcePath(context, projectRoot, relativePath)
    if (recorded) continue
    let canonical: string
    try {
      canonical = context.runtime.readSource(localPath)
    } catch {
      throw new Error(`Verifier source ${relativePath} is not present in the canonical checkout`)
    }
    if (canonical !== source.content) {
      throw new Error(`Verifier source ${relativePath} does not match the canonical checkout`)
    }
  }
  return sourceInputsHash(entries.map(([path, source]) => [path, source.content!]))
}

async function requireMinimalProxy(
  client: Pick<PublicClient, 'getCode'>,
  proxy: Address,
  implementation: Address,
) {
  const code = await client.getCode({ address: proxy })
  const expected =
    `0x363d3d373d3d3d363d73${implementation.slice(2).toLowerCase()}5af43d82803e903d91602b57fd5bf3` as Hex
  if (code?.toLowerCase() !== expected) {
    throw new Error(`EarnFees ${proxy} is not the expected minimal proxy to ${implementation}`)
  }
}

function storageAddress(value: Hex | undefined) {
  if (!value || value.length !== 66) throw new Error('EarnVault proxy has no implementation slot')
  return getAddress(`0x${value.slice(-40)}`)
}

async function creationTransactionFor(
  options: SourceVerificationOptions,
  action: EarnDeploymentActionId,
  address: Address,
  context: VerificationContext,
) {
  const transactions = options.record.actions[action]?.transactions
  if (!transactions || transactions.length !== 1 || !/^0x[0-9a-fA-F]{64}$/.test(transactions[0]!))
    throw new Error(
      `Missing or ambiguous creation transaction for ${action}. Recover its original creation receipt before verifying; source matches cannot replace creation evidence.`,
    )
  const transaction = transactions[0]!
  const step = deploymentStep(action)
  const factory =
    step.execution === 'foundry'
      ? step.creationEvent?.(options.profile, options.record.addresses as Record<string, Address>)
      : undefined
  if (factory?.source) {
    // Admit the factory canonically once, then recheck its own recorded identity, not the router's.
    const previous = recordedSource(context, { address })?.creationFactory
    if (previous && getAddress(previous.address) !== getAddress(factory.address))
      throw new Error(`Recorded creation factory for ${address} does not match ${factory.address}`)
    const verifyFactory = await prepareExistingSource(
      {
        ...context,
        root: foundryProjectRoot(options.root, factory.source.project),
        recordedSources: previous
          ? new Map([[factory.address.toLowerCase(), { kind: 'source', ...previous }]])
          : undefined,
      },
      factory.address,
      {
        contract: factory.source.contract,
        name: factory.source.contract.slice(factory.source.contract.lastIndexOf(':') + 1),
      },
    )
    const admitted = await verifyFactory()
    // Records without factory evidence still require canonical admission, without silently rewriting history.
    if (!recordedSource(context, { address }) || previous)
      context.creationFactories!.set(address.toLowerCase(), {
        address: getAddress(factory.address),
        name: admitted.name,
        match: previous?.match ?? admitted.match,
        sourceInputsHash: admitted.sourceInputsHash,
      })
  }
  assertCreationReceipt({
    address,
    transaction,
    receipt: await options.client.getTransactionReceipt({ hash: transaction }),
    factory,
  })
  if (!factory) context.directCreation!.transactions.set(address.toLowerCase(), transaction)
  return transaction
}

type VerificationContext = {
  chainId: number
  environment: NodeJS.ProcessEnv
  root: string
  rpcUrl: string
  verifierUrl: string
  runtime: VerificationDependencies
  submitMissing: boolean
  /** Completed records trust their recorded inputs, independently of permission to submit repairs. */
  recordedSources?: Map<string, ContractSourceVerification | undefined> | undefined
  resubmit?: boolean | undefined
  /** External factory identities admitted for each created target. */
  creationFactories?: Map<string, CreationFactoryVerification>
  /** Only profile-owned direct creations require mined constructor input; generic source verification may name factory transactions. */
  directCreation?: {
    client: Pick<PublicClient, 'getTransaction'>
    deployer: Address
    transactions: Map<string, Hex>
  }
  /** Each project's compiler arguments, resolved on its first submission. */
  compilerArguments: Map<string, string[]>
}

/** The verifier could not be reached or kept failing transiently: retrying later can succeed. */
export class VerifierUnavailableError extends Error {
  override name = 'VerifierUnavailableError'
}

/** The verifier refused a request (a 4xx other than 429), which retrying does not change. */
class VerifierRefusedError extends Error {
  override name = 'VerifierRefusedError'
}
