#!/usr/bin/env node
import { spawnSync } from 'node:child_process'
import { readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import {
  createPublicClient,
  encodeFunctionData,
  getAddress,
  keccak256,
  type Address,
  type Hex,
} from 'viem'

import { deployFactoryReleaseScriptAbi } from '../abis/index.js'
import {
  assertFoundryVersion,
  foundryProcessEnvironment,
  sourceVerificationCompilerArguments,
} from '../chain/foundry.js'
import { configuredRpcTransport, rpcConfiguration } from '../chain/runtime.js'
import { hostedEnvironments, type HostedEnvironmentId } from '../chain/tempo.js'
import { engineFactories } from '../modules/earn/engines/index.js'
import { compiledRuntimeCode } from './deploy.js'
import type { EarnDeploymentProfile } from './profile.js'
import {
  resolveEarnFactoryRelease,
  runtimeCodeHash,
  sharedFactoryRuntimeCodeHashes,
  validateSharedFactoryRelease,
} from './releases.js'
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

/**
 * Replaces the authenticated RPC URL and its credentials, raw and percent-encoded, in text that is
 * written to the result, the job summary, or an artifact, where GitHub's secret masking does not
 * reach.
 */
export function redactRpcCredentials(
  text: string,
  authenticatedUrl: string,
  environment: Readonly<Record<string, string | undefined>>,
) {
  const url = new URL(authenticatedUrl)
  const secrets = new Set<string>([authenticatedUrl, authenticatedUrl.replace(/\/+$/, '')])
  for (const value of [
    url.username,
    url.password,
    environment.TEMPO_RPC_URL,
    environment.TEMPO_RPC_USERNAME,
    environment.TEMPO_RPC_PASSWORD,
  ]) {
    if (!value) continue
    secrets.add(value)
    secrets.add(encodeURIComponent(value))
    try {
      secrets.add(decodeURIComponent(value))
    } catch {
      // Not percent-encoded.
    }
  }
  // Longest first, so a URL is replaced whole before any credential inside it.
  return [...secrets]
    .filter((secret) => secret.length > 0)
    .sort((left, right) => right.length - left.length)
    .reduce((redacted, secret) => redacted.split(secret).join('***'), text)
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
  /**
   * Set when the registry's release on this network already runs exactly this checkout's code, so
   * nothing was deployed and ${BT}registry${BT} names that existing release.
   */
  current?: true
  /** The release registry entry to review into deployments/core/releases.ts, when it names one. */
  registry: Record<string, Address> | null
}

export type FactoryReleaseDependencies = {
  /** Runs Forge from Earn's project, where its `solc` wrapper path resolves. */
  forge: (arguments_: string[], environment: Record<string, string>, cwd: string) => void
  readFile: (path: string) => string
  /**
   * The registry entry of this release on the chain when its live code already matches this
   * checkout's compiled code, or null when the release needs deploying.
   */
  currentRelease: (options: {
    plan: FactoryReleasePlan
    chainId: number
    rpc: ReturnType<typeof rpcConfiguration>
    root: string
    environment: Readonly<Record<string, string | undefined>>
  }) => Promise<Record<string, Address> | null>
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
  currentRelease: async ({ plan, chainId, rpc, root, environment }) => {
    if (!plan.registryKey) return null
    const registry = resolveEarnFactoryRelease(chainId)
    const address = registry[plan.registryKey as keyof typeof registry]
    if (!address) return null
    const client = createPublicClient({ transport: configuredRpcTransport(rpc) })
    const compile = (contract: string) => compiledRuntimeCode(root, contract, environment)
    try {
      if (plan.kind === 'core') {
        // The same check a profile deployment runs against its release: the factory, its immutable
        // implementations, and the TIP-20 factory it binds.
        await validateSharedFactoryRelease(
          client,
          { factories: registry } as EarnDeploymentProfile,
          sharedFactoryRuntimeCodeHashes(compile),
        )
      } else {
        const [contract] = plan.contracts
        if (!contract) return null
        const expected = keccak256(compile(contract.contract).bytecode)
        const actual = await runtimeCodeHash(client, address, contract.name)
        if (actual.toLowerCase() !== expected.toLowerCase()) return null
      }
    } catch (error) {
      // A different or missing release needs deploying; any other failure, such as the RPC, stops.
      if (
        error instanceof Error &&
        /does not match this checkout|uses TIP-20 factory|No runtime code/.test(error.message)
      ) {
        return null
      }
      throw error
    }
    return { [plan.registryKey]: address }
  },
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
  const current = await runtime.currentRelease({
    plan,
    chainId: network.chainId,
    rpc,
    root: options.root,
    environment: options.environment,
  })
  if (current) {
    return {
      network: network.id,
      chainId: network.chainId,
      kind: plan.kind,
      broadcast: options.broadcast,
      contracts: [],
      registry: current,
      current: true,
    }
  }
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
        // Forge's stderr can echo the --rpc-url, and this lands in the uploaded result artifact.
        verificationError: redactRpcCredentials(
          error instanceof Error ? error.message : String(error),
          rpc.authenticatedUrl,
          options.environment,
        ),
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

/** The releases the registry names, in deploy order; `all` deploys these. */
export const registryReleaseKinds = factoryReleaseKinds.filter((kind) => kind !== 'rewards')

/** The release kinds one selection deploys: `all`, or a single kind. */
export function releaseKindsFor(selection: string): string[] {
  if (selection === 'all') return [...registryReleaseKinds]
  if (!(factoryReleaseKinds as readonly string[]).includes(selection)) {
    throw new Error(
      `Unknown factory release ${selection}; expected all or one of ${factoryReleaseKinds.join(', ')}`,
    )
  }
  return [selection]
}

/** One network's run of one or more releases, written after each release so a failure keeps the rest. */
export type FactoryReleaseRun = {
  network: string
  chainId: number | null
  broadcast: boolean
  releases: FactoryReleaseResult[]
  /** The release that stopped the run, when one did. */
  failed?: { kind: string }
}

type RegistryUpdate = { network: string; key: string; address: Address; kind: string }

/**
 * The registry entries a set of runs proves: each broadcast release that names a registry entry and
 * whose every contract source verified. Anything else is skipped with its reason.
 */
export function registryUpdates(runs: readonly FactoryReleaseRun[]) {
  const updates: RegistryUpdate[] = []
  const skipped: { network: string; kind: string; reason: string }[] = []
  for (const run of runs) {
    if (run.failed) skipped.push({ network: run.network, kind: run.failed.kind, reason: 'failed' })
    for (const release of run.releases) {
      // An unchanged release needs no registry update.
      if (!release.registry || release.current) continue
      if (!release.broadcast) {
        skipped.push({ network: run.network, kind: release.kind, reason: 'dry run' })
        continue
      }
      const unverified = release.contracts.filter((contract) => contract.match === null)
      if (unverified.length > 0) {
        skipped.push({
          network: run.network,
          kind: release.kind,
          reason: `not source verified: ${unverified.map((contract) => contract.name).join(', ')}`,
        })
        continue
      }
      for (const [key, address] of Object.entries(release.registry)) {
        updates.push({ network: run.network, key, address, kind: release.kind })
      }
    }
  }
  return { updates, skipped }
}

/** Rewrites one network's entries in releases.ts, refusing an entry the file does not declare. */
export function updateReleaseRegistry(
  source: string,
  updates: readonly Pick<RegistryUpdate, 'network' | 'key' | 'address'>[],
) {
  let result = source
  for (const { network, key, address } of updates) {
    const start = result.indexOf(`\n  ${network}: {\n    factories: {\n`)
    const end = start < 0 ? -1 : result.indexOf('\n    },\n', start)
    if (start < 0 || end < 0) throw new Error(`releases.ts has no ${network} release`)
    const block = result.slice(start, end)
    const entry = new RegExp(`^(      ${key}: )(?:getAddress\\('0x[0-9a-fA-F]{40}'\\)|null),$`, 'm')
    if (!entry.test(block)) throw new Error(`releases.ts has no ${network}.${key} entry`)
    result =
      result.slice(0, start) +
      block.replace(entry, `$1getAddress('${getAddress(address)}'),`) +
      result.slice(end)
  }
  return result
}

/** The pull request body that records the updates, with each contract's verification. */
export function registryPullRequestBody(
  runs: readonly FactoryReleaseRun[],
  summary: ReturnType<typeof registryUpdates>,
  runUrl?: string,
) {
  const lines = [
    `Records the shared factory releases${runUrl ? ` from [the Factory Release run](${runUrl})` : ''} in [\`releases.ts\`](deployments/core/releases.ts). Each was broadcast from \`main\` and source verified on contracts.tempo.xyz.`,
    '',
    '| Network | Release | Contract | Address | Transaction | Source match |',
    '| --- | --- | --- | --- | --- | --- |',
  ]
  const recorded = new Set(summary.updates.map((update) => `${update.network}:${update.kind}`))
  for (const run of runs) {
    for (const release of run.releases) {
      if (!recorded.has(`${run.network}:${release.kind}`)) continue
      for (const contract of release.contracts) {
        lines.push(
          `| ${run.network} | ${release.kind} | ${contract.name} | \`${contract.address}\` | \`${contract.transaction ?? '-'}\` | ${contract.match} |`,
        )
      }
    }
  }
  if (summary.skipped.length > 0) {
    lines.push('', 'Not recorded:', '')
    for (const skip of summary.skipped) lines.push(`- ${skip.network} ${skip.kind}: ${skip.reason}`)
  }
  lines.push(
    '',
    "Finish or discard any pending profile deployment on these networks before merging: a pending deployment must use its chain's current release.",
  )
  return `${lines.join('\n')}\n`
}

const usage =
  'Usage: pnpm factory-release <network> <release|all> [--broadcast] [--output <file>]\n' +
  '       pnpm factory-release registry <result.json>... [--body <file>]\n' +
  `  network: ${Object.keys(hostedEnvironments).join(' | ')}\n` +
  `  release: all (${registryReleaseKinds.join(', ')}) | ${factoryReleaseKinds.join(' | ')}`

/** Applies every verified release in the result files to releases.ts. */
function registryMain(files: string[], body: string | undefined) {
  if (files.length === 0) throw new Error(usage)
  const runs = files.map((file) => JSON.parse(readFileSync(file, 'utf8')) as FactoryReleaseRun)
  const summary = registryUpdates(runs)
  const path = fileURLToPath(new URL('./releases.ts', import.meta.url))
  writeFileSync(path, updateReleaseRegistry(readFileSync(path, 'utf8'), summary.updates))
  const server = process.env.GITHUB_SERVER_URL
  const runUrl =
    server && process.env.GITHUB_REPOSITORY && process.env.GITHUB_RUN_ID
      ? `${server}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`
      : undefined
  if (body) writeFileSync(body, registryPullRequestBody(runs, summary, runUrl))
  console.log(JSON.stringify(summary, null, 2))
}

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
      body: { type: 'string' },
      help: { type: 'boolean', short: 'h' },
    },
  })
  if (values.help) {
    console.log(usage)
    return
  }
  if (positionals[0] === 'registry') {
    registryMain(positionals.slice(1), values.body)
    return
  }
  const [network, selection] = positionals
  if (!network || !selection || positionals.length !== 2) throw new Error(usage)
  const kinds = releaseKindsFor(selection)
  const run: FactoryReleaseRun = {
    network,
    chainId: hostedEnvironments[network as HostedEnvironmentId]?.chainId ?? null,
    broadcast: values.broadcast,
    releases: [],
  }
  const record = () => {
    const json = `${JSON.stringify(run, null, 2)}\n`
    if (values.output) writeFileSync(values.output, json)
    return json
  }
  for (const kind of kinds) {
    try {
      run.releases.push(
        await deployFactoryRelease({
          network,
          kind,
          broadcast: values.broadcast,
          root,
          environment: process.env,
        }),
      )
      record()
    } catch (error) {
      // Earlier releases are deployed; keep them in the result before stopping.
      run.failed = { kind }
      record()
      throw error
    }
  }
  console.log(record())
  const unverified = run.releases.flatMap((release) =>
    release.contracts.filter((contract) => contract.verificationError),
  )
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
