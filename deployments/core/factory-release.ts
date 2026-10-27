#!/usr/bin/env node
import { spawnSync } from 'node:child_process'
import { readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import { encodeFunctionData, getAddress, type Address, type Hex } from 'viem'

import { deployFactoryReleaseScriptAbi } from '../abis/index.js'
import {
  assertFoundryVersion,
  foundryProcessEnvironment,
  sourceVerificationCompilerArguments,
} from '../chain/foundry.js'
import { rpcConfiguration } from '../chain/runtime.js'
import { hostedEnvironments, type HostedEnvironmentId } from '../chain/tempo.js'
import { engineFactories } from '../modules/earn/engines/index.js'
import { verifyContractSource } from './verify.js'

const releaseScript = 'script/deploy/DeployFactoryRelease.s.sol:DeployFactoryReleaseScript'

/**
 * Every shared release one run deploys: the core release (EarnVault and EarnFees implementations
 * and the EarnFactory bound to them), the rewards factory, and each engine factory by its
 * `releaseKey`.
 */
export const factoryReleaseKinds = [
  'core',
  'rewards',
  ...engineFactories.map((factory) => factory.releaseKey),
] as const

export type FactoryReleaseKind = (typeof factoryReleaseKinds)[number]

type ReleaseContract = {
  name: string
  /** Fully qualified `<source>:<name>`. */
  contract: string
}

export type FactoryReleasePlan = {
  kind: FactoryReleaseKind
  /** `path:Contract` of the Foundry script. */
  script: string
  /** Calldata of the release entry point, which takes the expected chain ID. */
  calldata: Hex
  /** The contracts the entry point creates, each exactly once. */
  contracts: readonly ReleaseContract[]
  /** The release's registry entry key, for a release the registry names. */
  registryKey?: string
  /** Extra `forge script` arguments. */
  forgeArguments: readonly string[]
}

/** The release entry point and the contracts it creates for one release kind on one chain. */
export function planFactoryRelease(kind: string, chainId: number): FactoryReleasePlan {
  const expectedChainId = BigInt(chainId)
  if (kind === 'core') {
    return {
      kind,
      script: releaseScript,
      calldata: encodeFunctionData({
        abi: deployFactoryReleaseScriptAbi,
        functionName: 'earnFactoryRelease',
        args: [expectedChainId],
      }),
      contracts: [
        { name: 'EarnVault', contract: 'src/core/EarnVault.sol:EarnVault' },
        { name: 'EarnFees', contract: 'src/core/EarnFees.sol:EarnFees' },
        { name: 'EarnFactory', contract: 'src/core/EarnFactory.sol:EarnFactory' },
      ],
      registryKey: 'earn',
      // Tempo's RPC supplies the large EarnVault creation estimate; default padding can exceed its
      // 30M gas cap (docs/deployment/deployment.md#shared-factory-releases).
      forgeArguments: ['--gas-estimate-multiplier', '100'],
    }
  }
  if (kind === 'rewards') {
    return {
      kind,
      script: releaseScript,
      calldata: encodeFunctionData({
        abi: deployFactoryReleaseScriptAbi,
        functionName: 'earnRewardsFactory',
        args: [expectedChainId],
      }),
      contracts: [
        {
          name: 'EarnRewardsFactory',
          contract: 'src/rewards/EarnRewardsFactory.sol:EarnRewardsFactory',
        },
      ],
      forgeArguments: [],
    }
  }
  const factory = engineFactories.find((candidate) => candidate.releaseKey === kind)
  if (!factory) {
    throw new Error(
      `Unknown factory release ${kind}; expected one of ${factoryReleaseKinds.join(', ')}`,
    )
  }
  return {
    kind: factory.releaseKey,
    script: factory.deployScript,
    calldata: factory.releaseInput(expectedChainId),
    contracts: [{ name: factory.contract, contract: `${factory.source}:${factory.contract}` }],
    registryKey: factory.releaseKey,
    forgeArguments: [],
  }
}

type BroadcastFile = {
  transactions?: {
    transactionType?: string
    contractName?: string | null
    contractAddress?: string | null
    hash?: string | null
    transaction?: { input?: string | null }
  }[]
  receipts?: { transactionHash?: string; status?: string }[]
}

export type CreatedContract = ReleaseContract & {
  address: Address
  transaction: Hex | null
  constructorArgs: Hex
}

/**
 * The broadcast file Forge writes for a calldata entry point: `<selector>-latest.json`, under
 * `dry-run/` for a simulation.
 */
export function broadcastPath(
  root: string,
  plan: FactoryReleasePlan,
  chainId: number,
  broadcast: boolean,
) {
  const script = basename(plan.script.split(':')[0]!)
  return resolve(
    root,
    'broadcast',
    script,
    String(chainId),
    ...(broadcast ? [] : ['dry-run']),
    `${plan.calldata.slice(2, 10)}-latest.json`,
  )
}

/**
 * Reads the contracts a release run created from its broadcast file, requiring exactly the plan's
 * contracts, each created once, and, after a broadcast, a successful receipt for each. Constructor
 * arguments are the creation input past the locally compiled creation bytecode, so a creation that
 * does not start with it is refused.
 */
export function createdContracts(
  plan: FactoryReleasePlan,
  file: BroadcastFile,
  creationBytecode: (contract: string) => Hex,
  broadcast: boolean,
): CreatedContract[] {
  const creations = (file.transactions ?? []).filter((transaction) =>
    transaction.transactionType?.startsWith('CREATE'),
  )
  const expected = new Set(plan.contracts.map((contract) => contract.name))
  const unexpected = creations.filter((creation) => !expected.has(creation.contractName ?? ''))
  if (unexpected.length > 0 || creations.length !== plan.contracts.length) {
    throw new Error(
      `The ${plan.kind} release created ${creations.map((creation) => creation.contractName ?? 'unknown').join(', ') || 'nothing'}, expected ${plan.contracts.map((contract) => contract.name).join(', ')}`,
    )
  }
  return plan.contracts.map((contract) => {
    const matches = creations.filter((creation) => creation.contractName === contract.name)
    const creation = matches[0]
    if (!creation || matches.length !== 1 || !creation.contractAddress) {
      throw new Error(`The ${plan.kind} release did not create ${contract.name} exactly once`)
    }
    const hash = (creation.hash ?? null) as Hex | null
    if (broadcast) {
      const receipt = file.receipts?.find(
        (candidate) => candidate.transactionHash?.toLowerCase() === hash?.toLowerCase(),
      )
      if (!hash || receipt?.status !== '0x1') {
        throw new Error(
          `${contract.name} creation ${hash ?? 'without a hash'} has no successful receipt`,
        )
      }
    }
    const input = (creation.transaction?.input ?? '').toLowerCase()
    const bytecode = creationBytecode(contract.contract).toLowerCase()
    if (!bytecode.startsWith('0x') || bytecode.length <= 2 || !input.startsWith(bytecode)) {
      throw new Error(
        `${contract.name} creation input does not start with its locally compiled creation bytecode`,
      )
    }
    return {
      ...contract,
      address: getAddress(creation.contractAddress),
      transaction: hash,
      constructorArgs: `0x${input.slice(bytecode.length)}` as Hex,
    }
  })
}

export type FactoryReleaseResult = {
  network: HostedEnvironmentId
  chainId: number
  kind: FactoryReleaseKind
  broadcast: boolean
  contracts: (Omit<CreatedContract, 'constructorArgs'> & {
    constructorArgs: Hex
    match: 'exact_match' | 'match' | null
    /** Why source verification failed; the contract is still deployed. */
    verificationError?: string
  })[]
  /** The release registry entry to review into deployments/core/releases.ts, when it names one. */
  registry: Record<string, Address> | null
}

export type FactoryReleaseDependencies = {
  /** Runs Forge from Earn's project, where its `solc` wrapper path resolves. */
  forge: (arguments_: string[], environment: Record<string, string>, cwd: string) => void
  readFile: (path: string) => string
  /** Deletes Forge's script sequences of one script, which record the RPC URL with its credentials. */
  removeScriptCache: (root: string, script: string) => void
  preflight: (root: string, environment: Readonly<Record<string, string | undefined>>) => void
  verify: typeof verifyContractSource
}

const defaultDependencies: FactoryReleaseDependencies = {
  forge: (arguments_, environment, cwd) => {
    const result = spawnSync('forge', arguments_, {
      cwd,
      env: environment as NodeJS.ProcessEnv,
      stdio: 'inherit',
    })
    if (result.error) throw result.error
    if (result.status !== 0)
      throw new Error(`forge script failed (status ${result.status ?? 'unknown'})`)
  },
  readFile: (path) => readFileSync(path, 'utf8'),
  removeScriptCache: (root, script) => {
    // Forge writes the sensitive sequence under <cache_path>/<script file>/, for simulations too.
    const cache = resolve(root, 'cache')
    let profiles: string[]
    try {
      profiles = readdirSync(cache)
    } catch {
      return
    }
    for (const profile of profiles) {
      rmSync(resolve(cache, profile, script), { recursive: true, force: true })
    }
  },
  preflight: (root, environment) => {
    assertFoundryVersion(root)
    // Refuse a compiler build the source verifier cannot reproduce before anything is broadcast.
    sourceVerificationCompilerArguments(root, environment)
  },
  verify: verifyContractSource,
}

/**
 * Deploys one shared factory release on a hosted network with the deploy profile, then source
 * verifies every contract it created against Tempo's verifier. Without `broadcast`, Forge only
 * simulates, and nothing is signed or verified.
 */
export async function deployFactoryRelease(
  options: {
    network: string
    kind: string
    broadcast: boolean
    /** Earn's Foundry project. */
    root: string
    environment: Readonly<Record<string, string | undefined>>
  },
  dependencies: Partial<FactoryReleaseDependencies> = {},
): Promise<FactoryReleaseResult> {
  const runtime = { ...defaultDependencies, ...dependencies }
  const network = hostedEnvironments[options.network as HostedEnvironmentId]
  if (!network) {
    throw new Error(
      `Unknown hosted network ${options.network}; expected one of ${Object.keys(hostedEnvironments).join(', ')}`,
    )
  }
  const plan = planFactoryRelease(options.kind, network.chainId)
  if (!options.environment.DEPLOYER_PRIVATE_KEY) throw new Error('DEPLOYER_PRIVATE_KEY is required')
  const rpc = rpcConfiguration('TEMPO', options.environment, network.rpcUrl)
  if (!rpc.authenticatedUrl) throw new Error(`No RPC for ${network.id}`)

  runtime.preflight(options.root, options.environment)
  try {
    runtime.forge(
      [
        'script',
        plan.script,
        '--root',
        options.root,
        '--sig',
        plan.calldata,
        '--network',
        'tempo',
        '--rpc-url',
        rpc.authenticatedUrl,
        '--slow',
        ...plan.forgeArguments,
        ...(options.broadcast ? ['--broadcast'] : []),
      ],
      foundryProcessEnvironment(options.environment),
      options.root,
    )
  } finally {
    runtime.removeScriptCache(options.root, basename(plan.script.split(':')[0]!))
  }

  const file = JSON.parse(
    runtime.readFile(broadcastPath(options.root, plan, network.chainId, options.broadcast)),
  ) as BroadcastFile
  const created = createdContracts(
    plan,
    file,
    (contract) => {
      const [source, name] = contract.split(':') as [string, string]
      const artifact = JSON.parse(
        runtime.readFile(resolve(options.root, 'out', 'deploy', basename(source), `${name}.json`)),
      ) as { bytecode?: { object?: string } }
      return (artifact.bytecode?.object ?? '0x') as Hex
    },
    options.broadcast,
  )

  const contracts: FactoryReleaseResult['contracts'] = []
  for (const contract of created) {
    if (!options.broadcast) {
      contracts.push({ ...contract, match: null })
      continue
    }
    // A deployed contract stays in the result when its verification fails, so the addresses and
    // registry entry survive and verification can be retried without redeploying.
    try {
      const verification = await runtime.verify({
        chainId: network.chainId,
        environment: options.environment as NodeJS.ProcessEnv,
        root: options.root,
        rpcUrl: rpc.authenticatedUrl,
        address: contract.address,
        contract: contract.contract,
        constructorArgs: contract.constructorArgs,
      })
      contracts.push({ ...contract, match: verification.match })
    } catch (error) {
      contracts.push({
        ...contract,
        match: null,
        verificationError: error instanceof Error ? error.message : String(error),
      })
    }
  }
  const registryContract = plan.registryKey ? created.at(-1) : undefined
  return {
    network: network.id,
    chainId: network.chainId,
    kind: plan.kind,
    broadcast: options.broadcast,
    contracts,
    registry:
      plan.registryKey && registryContract
        ? { [plan.registryKey]: registryContract.address }
        : null,
  }
}

const usage =
  'Usage: pnpm factory-release <network> <release> [--broadcast] [--output <file>]\n' +
  `  network: ${Object.keys(hostedEnvironments).join(' | ')}\n` +
  `  release: ${factoryReleaseKinds.join(' | ')}`

/** CLI boundary; reads DEPLOYER_PRIVATE_KEY and the optional TEMPO_RPC_* from the environment. */
export async function main(
  argv: string[] = process.argv.slice(2),
  root = resolve(fileURLToPath(new URL('../../earn', import.meta.url))),
) {
  const { positionals, values } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      broadcast: { type: 'boolean', default: false },
      output: { type: 'string' },
      help: { type: 'boolean', short: 'h' },
    },
  })
  if (values.help) {
    console.log(usage)
    return
  }
  const [network, kind] = positionals
  if (!network || !kind || positionals.length !== 2) throw new Error(usage)
  const result = await deployFactoryRelease({
    network,
    kind,
    broadcast: values.broadcast,
    root,
    environment: process.env,
  })
  const json = `${JSON.stringify(result, null, 2)}\n`
  if (values.output) writeFileSync(values.output, json)
  console.log(json)
  const unverified = result.contracts.filter((contract) => contract.verificationError)
  if (unverified.length > 0) {
    throw new Error(
      `Deployed but not source verified: ${unverified.map((contract) => `${contract.name} ${contract.address} (${contract.verificationError})`).join('; ')}. Retry with forge verify-contract (docs/deployment/deployment.md#shared-factory-releases); do not rerun the release.`,
    )
  }
}

if (resolve(process.argv[1] ?? '') === fileURLToPath(import.meta.url)) {
  try {
    await main()
  } catch (error) {
    // Plain errors name the failed check; any other error keeps its stack.
    if (!(error instanceof Error) || error.constructor !== Error) throw error
    console.error(error.message)
    process.exitCode = 1
  }
}
