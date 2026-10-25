import { spawnSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { resolve, sep } from 'node:path'
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

import { foundryVerificationEnvironment } from '../chain/foundry.js'
import { deploymentAddressKeys } from './components.js'
import { readEarnFactory, runtimeCodeHash } from './releases.js'
import { isHostedDeploymentChain } from '../chain/tempo.js'
import { deploysEngine, profileEngineFactory, type EarnDeploymentProfile } from './profile.js'
import {
  type ContractSourceVerification,
  type DeploymentSource,
  type EarnDeploymentRecord,
} from './record.js'
import { engineDefinitions } from '../modules/engines/index.js'
import { deploymentSteps } from '../modules/index.js'
import { requiredOutput } from '../modules/module.js'

export const tempoVerifierUrl = 'https://contracts.tempo.xyz'

const implementationSlot =
  '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc' as const
const transientVerifierErrors = new Set(['internal_error', 'compilation_failed'])

type VerifiedContract = {
  match: 'exact_match' | 'match' | null
  name: string | null
  address: string
  fullyQualifiedName?: string | null
  sources?: Record<string, { content?: string }>
  transactionHash?: string | null
}

export type VerificationDependencies = {
  fetch: typeof fetch
  pause: (milliseconds: number) => Promise<void>
  readSource: (path: string) => string
  spawn: typeof spawnSync
}

type SourceVerificationOptions<Record = Pick<EarnDeploymentRecord, 'actions' | 'addresses'>> = {
  client: Pick<PublicClient, 'getCode' | 'getStorageAt' | 'readContract'>
  environment: NodeJS.ProcessEnv
  profile: EarnDeploymentProfile
  record: Record
  root: string
  rpcUrl: string
}

/** Verifies every deployment-owned Solidity artifact and classifies native/proxy outputs. */
export async function verifyDeploymentSources(
  options: SourceVerificationOptions,
  dependencies: Partial<VerificationDependencies> = {},
): Promise<Pick<DeploymentSource, 'contractVerification' | 'contracts' | 'verifierUrl'>> {
  return inspectDeploymentSources(options, true, dependencies)
}

/** Rechecks recorded verifier results and proxy provenance without submitting verifier jobs. */
export async function verifyRecordedDeploymentSources(
  options: SourceVerificationOptions<EarnDeploymentRecord>,
  dependencies: Partial<VerificationDependencies> = {},
) {
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
  const observed = await inspectDeploymentSources(options, false, dependencies)
  if (!isDeepStrictEqual(observed.contracts, options.record.source.contracts)) {
    throw new Error('Recorded deployment source verification does not match current provenance')
  }
}

async function inspectDeploymentSources(
  options: SourceVerificationOptions,
  submitMissing: boolean,
  dependencies: Partial<VerificationDependencies>,
): Promise<Pick<DeploymentSource, 'contractVerification' | 'contracts' | 'verifierUrl'>> {
  if (!isHostedDeploymentChain(options.profile.chainId)) {
    return { contractVerification: 'not-applicable', contracts: {}, verifierUrl: null }
  }
  const context: VerificationContext = {
    ...options,
    chainId: options.profile.chainId,
    verifierUrl: tempoVerifierUrl,
    runtime: verificationRuntime(dependencies),
    submitMissing,
  }
  const addresses = options.record.addresses as Record<string, Address>
  const engine = requiredOutput(addresses, 'engine')
  const earnVault = requiredOutput(addresses, 'earnVault')
  const earnFees = requiredOutput(addresses, 'earnFees')
  const contracts: DeploymentSource['contracts'] = {}

  const { engineContract, engineSource } = engineDefinitions[options.profile.engine.kind]
  if (deploysEngine(options.profile)) {
    contracts.engine = await verifySource(context, {
      address: engine,
      constructorArgs: profileEngineFactory(options.profile).engineConstructorArgs({
        venue: options.profile.engine.venue,
        owner: options.profile.deployer,
      }),
      contract: `${engineSource}:${engineContract}`,
      creationTransactionHash: transactionFor(options.record, 'deploy-engine'),
      name: engineContract,
    })
  } else {
    contracts.engine = await requireExistingSource(context, engine, {
      name: engineContract,
      contract: `${engineSource}:${engineContract}`,
    })
  }

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
  const proxySource = await verifySource(context, {
    address: earnVault,
    constructorArgs: encodeAbiParameters(parseAbiParameters('address implementation, bytes data'), [
      vaultImplementation,
      '0x',
    ]),
    contract: 'lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy',
    creationTransactionHash: transactionFor(options.record, 'deploy-core'),
    name: 'ERC1967Proxy',
  })
  contracts.earnVault = {
    kind: 'erc1967-proxy',
    name: 'ERC1967Proxy',
    match: proxySource.match,
    sourceInputsHash: proxySource.sourceInputsHash,
    implementation: vaultImplementation,
    implementationCodeHash: vaultImplementationCodeHash,
  }

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
        ? [{ id: step.id, ...step.source }]
        : [],
    )
    .sort(
      (left, right) =>
        deploymentAddressKeys.indexOf(left.output) - deploymentAddressKeys.indexOf(right.output),
    )
  for (const { id, output, contract, constructorArgs } of created) {
    contracts[output] = await verifySource(context, {
      address: requiredOutput(addresses, output),
      constructorArgs: constructorArgs(options.profile, addresses),
      contract,
      creationTransactionHash: transactionFor(options.record, id),
      name: contract.slice(contract.lastIndexOf(':') + 1),
    })
  }

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
  },
  dependencies: Partial<VerificationDependencies> = {},
) {
  const { address, contract, constructorArgs, ...target } = options
  return verifySource(
    {
      ...target,
      verifierUrl: tempoVerifierUrl,
      runtime: verificationRuntime(dependencies),
      submitMissing: true,
    },
    { address, constructorArgs, contract, name: contract.slice(contract.lastIndexOf(':') + 1) },
  )
}

function verificationRuntime(
  dependencies: Partial<VerificationDependencies>,
): VerificationDependencies {
  return {
    fetch,
    pause: (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
    readSource: (path) => readFileSync(path, 'utf8'),
    spawn: spawnSync,
    ...dependencies,
  }
}

async function requireExistingSource(
  context: VerificationContext,
  address: Address,
  target: { contract: string; name: string },
): Promise<Extract<ContractSourceVerification, { kind: 'source' }>> {
  const contract = await lookupContract(context, address)
  if (!contract) {
    throw new Error(`Existing ${target.name} ${address} is not source verified`)
  }
  return sourceMatch(context, contract, { ...target, address })
}

async function verifySource(
  context: VerificationContext,
  target: {
    address: Address
    constructorArgs?: Hex | undefined
    contract: string
    creationTransactionHash?: Hex | undefined
    name: string
  },
): Promise<Extract<ContractSourceVerification, { kind: 'source' }>> {
  const existing = await lookupContract(context, target.address)
  if (existing?.match) {
    return sourceMatch(context, existing, target)
  }
  if (!context.submitMissing) {
    throw new Error(`${target.name} ${target.address} does not have a source match`)
  }

  let lastError = 'verification did not complete'
  const maximumAttempts = 6
  for (let attempt = 1; attempt <= maximumAttempts; attempt++) {
    const result = context.runtime.spawn(
      'forge',
      [
        'verify-contract',
        target.address,
        target.contract,
        '--root',
        context.root,
        '--chain',
        String(context.chainId),
        '--rpc-url',
        context.rpcUrl,
        '--verifier',
        'sourcify',
        '--verifier-url',
        context.verifierUrl,
        '--skip-is-verified-check',
        ...(target.constructorArgs ? ['--constructor-args', target.constructorArgs] : []),
        ...(target.creationTransactionHash
          ? ['--creation-transaction-hash', target.creationTransactionHash]
          : []),
      ],
      {
        cwd: context.root,
        encoding: 'utf8',
        env: foundryVerificationEnvironment(context.environment) as NodeJS.ProcessEnv,
      },
    )
    if (result.error) throw result.error
    if (result.status !== 0) {
      throw new Error(`Could not submit ${target.name} source verification: ${result.stderr}`)
    }
    const verifierOutput = `${result.stdout}\n${result.stderr}`
    const jobId = verifierOutput.match(/Verification Job ID: `([^`]+)`/)?.[1]
    if (!jobId) throw new Error(`Tempo verifier did not return a job ID for ${target.name}`)
    const outcome = await pollVerification(context, jobId)
    if (outcome.contract) {
      const verified = await lookupContract(context, target.address)
      if (!verified) {
        throw new Error(`${target.name} ${target.address} completed verification without a source`)
      }
      return sourceMatch(context, verified, target)
    }
    lastError = `${outcome.error?.customCode ?? 'unknown'}: ${outcome.error?.message ?? 'unknown error'}`
    if (
      !transientVerifierErrors.has(outcome.error?.customCode ?? '') ||
      attempt === maximumAttempts
    )
      break
    await context.runtime.pause(Math.min(5_000 * 2 ** (attempt - 1), 30_000))
  }
  throw new Error(`Source verification failed for ${target.name} ${target.address}: ${lastError}`)
}

async function lookupContract(context: VerificationContext, address: Address) {
  const url = `${context.verifierUrl}/v2/contract/${context.chainId}/${address}?fields=all`
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const response = await context.runtime.fetch(url)
      if (response.status === 404) return undefined
      if (response.ok) return (await response.json()) as VerifiedContract
      if (response.status !== 429 && response.status < 500) {
        throw new Error(`Tempo verifier lookup failed for ${address}: HTTP ${response.status}`)
      }
      if (attempt === 5) {
        throw new Error(`Tempo verifier lookup failed for ${address}: HTTP ${response.status}`)
      }
    } catch (error) {
      if (attempt === 5) throw error
    }
    await context.runtime.pause(attempt * 500)
  }
  return undefined
}

async function pollVerification(context: VerificationContext, jobId: string) {
  for (let poll = 0; poll < 30; poll++) {
    const response = await context.runtime.fetch(`${context.verifierUrl}/v2/verify/${jobId}`)
    if (!response.ok)
      throw new Error(`Tempo verifier job ${jobId} returned HTTP ${response.status}`)
    const outcome = (await response.json()) as {
      isJobCompleted: boolean
      contract: VerifiedContract | null
      error: { customCode: string; message: string } | null
    }
    if (outcome.isJobCompleted) return outcome
    await context.runtime.pause(1_000)
  }
  throw new Error(`Tempo verifier job ${jobId} did not complete`)
}

function sourceMatch(
  context: VerificationContext,
  contract: VerifiedContract,
  target: {
    address: Address
    contract: string
    creationTransactionHash?: Hex | undefined
    name: string
  },
): Extract<ContractSourceVerification, { kind: 'source' }> {
  if (!contract.match) {
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
    contract.transactionHash &&
    contract.transactionHash?.toLowerCase() !== target.creationTransactionHash.toLowerCase()
  ) {
    throw new Error(
      `Verifier creation transaction for ${target.name} does not match the recorded deployment transaction`,
    )
  }
  const sourceInputsHash = requireCanonicalSources(context, contract, target.contract)
  return {
    kind: 'source',
    name: target.name,
    match: contract.match,
    sourceInputsHash,
  }
}

function requireCanonicalSources(
  context: VerificationContext,
  contract: VerifiedContract,
  fullyQualifiedName: string,
) {
  const sources = contract.sources
  const sourcePath = fullyQualifiedName.slice(0, fullyQualifiedName.lastIndexOf(':'))
  if (!sources || !sources[sourcePath]) {
    throw new Error(`Verifier did not return canonical source ${sourcePath}`)
  }
  const root = resolve(context.root)
  const entries = Object.entries(sources).sort(([left], [right]) => left.localeCompare(right))
  for (const [relativePath, source] of entries) {
    if (typeof source.content !== 'string')
      throw new Error(`Verifier did not return source content for ${relativePath}`)
    const localPath = resolve(root, relativePath)
    if (localPath !== root && !localPath.startsWith(`${root}${sep}`)) {
      throw new Error(`Verifier source path ${relativePath} escapes the repository root`)
    }
    if (!context.submitMissing) continue
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
  return keccak256(
    stringToBytes(
      JSON.stringify(
        entries.map(([path, source]) => [path, keccak256(stringToBytes(source.content!))]),
      ),
    ),
  )
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

function transactionFor(record: Pick<EarnDeploymentRecord, 'actions'>, action: string) {
  return record.actions[action as keyof typeof record.actions]?.transactions[0]
}

type VerificationContext = {
  chainId: number
  environment: NodeJS.ProcessEnv
  root: string
  rpcUrl: string
  verifierUrl: string
  runtime: VerificationDependencies
  submitMissing: boolean
}
