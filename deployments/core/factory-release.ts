#!/usr/bin/env node
import { execFileSync, spawnSync } from 'node:child_process'
import { readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import {
  concatHex,
  createPublicClient,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  getContractAddress,
  isHex,
  keccak256,
  parseAbiParameters,
  stringToBytes,
  zeroAddress,
  zeroHash,
  type Abi,
  type Address,
  type Hex,
} from 'viem'
import { Addresses } from 'viem/tempo'

import {
  deployFactoryReleaseScriptAbi,
  deployRouterReleaseScriptAbi,
  sendSettlerAbi,
  zoneRouterAbi,
} from '../abis/index.js'
import {
  assertFoundryVersion,
  foundryProjectRoot,
  foundryProcessEnvironment,
  foundryVerificationEnvironment,
  sourceVerificationCompilerArguments,
} from '../chain/foundry.js'
import { configuredRpcTransport, rpcConfiguration } from '../chain/runtime.js'
import { hostedEnvironments, type HostedEnvironmentId } from '../chain/tempo.js'
import { engineFactories } from '../modules/earn/engines/index.js'
import { address, exactKeys, isBytes32, object, positiveInteger, unique } from './parse.js'
import { verifyContractSource } from './verify.js'

const releaseScript = 'script/deploy/DeployFactoryRelease.s.sol:DeployFactoryReleaseScript'
const routerReleaseScript = 'script/deploy/DeployRouterRelease.s.sol:DeployRouterReleaseScript'

/**
 * The router project's ownerless contracts, released like the shared factories but named by no
 * registry entry: the ZoneRouterFactory, a SendSettler, and a ZoneRouter its factory creates.
 */
export const routerReleaseKinds = ['zoneRouterFactory', 'sendSettler', 'zoneRouter'] as const

/**
 * Every release one run deploys: the core release (EarnVault and EarnFees implementations and the
 * EarnFactory bound to them), the rewards factory, each engine factory by its `releaseKey`, and the
 * router project's contracts.
 */
export const factoryReleaseKinds = [
  'core',
  'rewards',
  ...engineFactories.map((factory) => factory.releaseKey),
  ...routerReleaseKinds,
] as const

export type FactoryReleaseKind = (typeof factoryReleaseKinds)[number]

/**
 * The CREATE2 deployer every release contract is created through: forge-std's `CREATE2_FACTORY`, which
 * Forge routes salted creations to and which every Tempo network has.
 */
export const create2Deployer = getAddress('0x4e59b44847b379578588920cA78FbF26c0B4956C')

/** The salt of every release contract; it must equal `RELEASE_SALT` in DeterministicRelease.sol. */
export const releaseSalt = keccak256(stringToBytes('tempoxyz/earn shared factory release'))

type ReleaseContract = {
  name: string
  /** Fully qualified `<source>:<name>`, in the plan's Foundry project. */
  contract: string
  /** ABI-encoded constructor arguments, given the addresses of the release's earlier contracts. */
  constructorArgs?: (addresses: Readonly<Record<string, Address>>) => Hex
  /**
   * The contract that creates it with CREATE2, and its salt, for one created inside a call (a
   * ZoneRouter its factory creates); `create2Deployer` with `releaseSalt` when omitted.
   */
  creator?: { address: Address; salt: Hex }
}

/** The Foundry project that compiles, deploys and source-verifies a release. */
export type FoundryProject = 'earn' | 'router'

/** A ZoneRouter's `ZoneRouter.Mode`, its constructor argument. */
export type ZoneRouterMode = {
  zoneId: number
  enabledOps: number
  earnVault: Address
  privateAsset: Address
  pool: Address
  customerId: Hex
  settlers: Address[]
}

/** A release's validated parameters, as the result records them; empty for most kinds. */
export type FactoryReleaseParameters =
  | Record<string, never>
  | { pool: Address; customerId: Hex }
  | { factory: Address; mode: ZoneRouterMode }

export type FactoryReleasePlan = {
  kind: FactoryReleaseKind
  /** The Foundry project its script and contracts belong to. */
  project: FoundryProject
  /** `path:Contract` of the Foundry script. */
  script: string
  parameters: FactoryReleaseParameters
  /** Calldata of the release entry point, which takes the expected chain ID. */
  calldata: Hex
  /** The contracts the entry point creates, each exactly once. */
  contracts: readonly ReleaseContract[]
  /** The release's registry entry key, for a release the registry names. */
  registryKey?: string
  /** Extra `forge script` arguments. */
  forgeArguments: readonly string[]
}

const constructorInputs = (abi: Abi) =>
  (abi.find((item) => item.type === 'constructor') as Extract<Abi[number], { type: 'constructor' }>)
    .inputs
const opDeposit = 1
const opRedeem = 2
const opSpend = 4

/** A kind without parameters accepts only an empty object. */
function noParameters(kind: string, value: unknown): Record<string, never> {
  if (Object.keys(object(value, 'parameters')).length > 0) {
    throw new Error(`The ${kind} release takes no parameters`)
  }
  return {}
}

/**
 * A SendSettler's optional conversion binding: the vault whose asset it converts at par, the pool and
 * the customer ID all set, or all omitted for a settler that never converts.
 */
export function parseSendSettlerParameters(value: unknown) {
  const parameters = object(value, 'parameters')
  const keys = ['vault', 'pool', 'customerId'] as const
  exactKeys(parameters, 'parameters', [], keys)
  const set = keys.filter((key) => parameters[key] !== undefined)
  if (set.length === 0) return { vault: zeroAddress, pool: zeroAddress, customerId: zeroHash }
  if (set.length !== keys.length) {
    throw new Error(
      'parameters.vault, parameters.pool and parameters.customerId are set together or not at all',
    )
  }
  return {
    vault: address(parameters.vault, 'parameters.vault'),
    pool: address(parameters.pool, 'parameters.pool'),
    customerId: nonzeroBytes32(parameters.customerId, 'parameters.customerId'),
  }
}

/**
 * A ZoneRouter's factory and mode. The constructor's rules that need no chain state hold at parse
 * time: Earn bindings exactly with Deposit or Redeem (a pool and customer ID together), and distinct
 * settlers exactly with Spend. Omitted bindings and settlers are zero.
 */
export function parseZoneRouterParameters(value: unknown) {
  const parameters = object(value, 'parameters')
  exactKeys(parameters, 'parameters', ['factory', 'mode'])
  const factory = address(parameters.factory, 'parameters.factory')
  const path = 'parameters.mode'
  const mode = object(parameters.mode, path)
  const earnKeys = ['earnVault', 'privateAsset', 'pool', 'customerId'] as const
  exactKeys(mode, path, ['zoneId', 'enabledOps'], [...earnKeys, 'settlers'])
  const zoneId = positiveInteger(mode.zoneId, `${path}.zoneId`)
  if (zoneId > 0xffff_ffff) throw new Error(`${path}.zoneId must fit uint32`)
  const enabledOps = positiveInteger(mode.enabledOps, `${path}.enabledOps`)
  if (enabledOps > (opDeposit | opRedeem | opSpend)) {
    throw new Error(`${path}.enabledOps must combine deposit (1), redeem (2) and spend (4)`)
  }
  const result: ZoneRouterMode = {
    zoneId,
    enabledOps,
    earnVault: zeroAddress,
    privateAsset: zeroAddress,
    pool: zeroAddress,
    customerId: zeroHash,
    settlers: [],
  }
  if (enabledOps & (opDeposit | opRedeem)) {
    result.earnVault = address(mode.earnVault, `${path}.earnVault`)
    result.privateAsset = address(mode.privateAsset, `${path}.privateAsset`)
    if ((mode.pool === undefined) !== (mode.customerId === undefined)) {
      throw new Error(`${path}.pool and ${path}.customerId are set together or not at all`)
    }
    if (mode.pool !== undefined) {
      result.pool = address(mode.pool, `${path}.pool`)
      result.customerId = nonzeroBytes32(mode.customerId, `${path}.customerId`)
    }
  } else {
    const key = earnKeys.find((candidate) => mode[candidate] !== undefined)
    if (key) throw new Error(`${path}.${key} is not supported without deposit or redeem`)
  }
  const spends = (enabledOps & opSpend) !== 0
  if (spends !== (mode.settlers !== undefined)) {
    throw new Error(
      spends
        ? `${path}.settlers is required with spend`
        : `${path}.settlers is not supported without spend`,
    )
  }
  if (spends) {
    const settlers = mode.settlers
    if (!Array.isArray(settlers) || settlers.length === 0) {
      throw new Error(`${path}.settlers must list at least one settler`)
    }
    result.settlers = settlers.map((settler, index) =>
      address(settler, `${path}.settlers[${index}]`),
    )
    unique(result.settlers, `${path}.settlers settler`)
  }
  return { factory, mode: result }
}

function nonzeroBytes32(value: unknown, path: string): Hex {
  if (!isBytes32(value) || BigInt(value) === 0n)
    throw new Error(`${path} must be a nonzero bytes32`)
  return value
}

/**
 * The release entry point and the contracts it creates for one release kind on one chain, with the
 * kind's parameters: a SendSettler's optional conversion binding, and a ZoneRouter's factory and
 * mode. Every other kind takes none.
 */
export function planFactoryRelease(
  kind: string,
  chainId: number,
  parameters: unknown = {},
): FactoryReleasePlan {
  const expectedChainId = BigInt(chainId)
  if (kind === 'core') {
    return {
      kind,
      project: 'earn',
      script: releaseScript,
      parameters: noParameters(kind, parameters),
      calldata: encodeFunctionData({
        abi: deployFactoryReleaseScriptAbi,
        functionName: 'earnFactoryRelease',
        args: [expectedChainId],
      }),
      contracts: [
        { name: 'EarnVault', contract: 'src/core/EarnVault.sol:EarnVault' },
        { name: 'EarnFees', contract: 'src/core/EarnFees.sol:EarnFees' },
        {
          name: 'EarnFactory',
          contract: 'src/core/EarnFactory.sol:EarnFactory',
          constructorArgs: (addresses) =>
            encodeAbiParameters(parseAbiParameters('address, address, address'), [
              Addresses.tip20Factory,
              requiredAddress(addresses, 'EarnVault'),
              requiredAddress(addresses, 'EarnFees'),
            ]),
        },
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
      project: 'earn',
      script: releaseScript,
      parameters: noParameters(kind, parameters),
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
  if (kind === 'zoneRouterFactory') {
    return {
      kind,
      project: 'router',
      script: routerReleaseScript,
      parameters: noParameters(kind, parameters),
      calldata: encodeFunctionData({
        abi: deployRouterReleaseScriptAbi,
        functionName: 'zoneRouterFactory',
        args: [expectedChainId],
      }),
      contracts: [
        { name: 'ZoneRouterFactory', contract: 'src/ZoneRouterFactory.sol:ZoneRouterFactory' },
      ],
      forgeArguments: [],
    }
  }
  if (kind === 'sendSettler') {
    const settler = parseSendSettlerParameters(parameters)
    return {
      kind,
      project: 'router',
      script: routerReleaseScript,
      parameters: settler,
      calldata: encodeFunctionData({
        abi: deployRouterReleaseScriptAbi,
        functionName: 'sendSettler',
        args: [expectedChainId, settler.vault, settler.pool, settler.customerId],
      }),
      contracts: [
        {
          name: 'SendSettler',
          contract: 'src/SendSettler.sol:SendSettler',
          constructorArgs: () =>
            encodeAbiParameters(constructorInputs(sendSettlerAbi), [
              settler.vault,
              settler.pool,
              settler.customerId,
            ]),
        },
      ],
      forgeArguments: [],
    }
  }
  if (kind === 'zoneRouter') {
    const router = parseZoneRouterParameters(parameters)
    // `abi.encode(mode)`: the router's constructor argument, whose hash its factory salts with.
    const modeArgs = encodeAbiParameters(constructorInputs(zoneRouterAbi), [router.mode])
    return {
      kind,
      project: 'router',
      script: routerReleaseScript,
      parameters: router,
      calldata: encodeFunctionData({
        abi: deployRouterReleaseScriptAbi,
        functionName: 'zoneRouter',
        args: [expectedChainId, router.factory, router.mode],
      }),
      contracts: [
        {
          name: 'ZoneRouter',
          contract: 'src/ZoneRouter.sol:ZoneRouter',
          constructorArgs: () => modeArgs,
          creator: { address: router.factory, salt: keccak256(modeArgs) },
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
    project: 'earn',
    script: factory.deployScript,
    parameters: noParameters(kind, parameters),
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
    /** Contracts the transaction created inside its call, such as a ZoneRouter its factory created. */
    additionalContracts?: {
      transactionType?: string
      contractName?: string | null
      address?: string | null
      initCode?: string | null
    }[]
  }[]
  receipts?: { transactionHash?: string; status?: string }[]
}

export type CreatedContract = Omit<ReleaseContract, 'constructorArgs' | 'creator'> & {
  address: Address
  /** The creating transaction; null for a contract that already existed at its address. */
  transaction: Hex | null
  constructorArgs: Hex
}

export type PredictedContract = CreatedContract & { initCode: Hex }

function requiredAddress(addresses: Readonly<Record<string, Address>>, name: string) {
  const address = addresses[name]
  if (!address) throw new Error(`The release has no ${name} before the contract that binds it`)
  return address
}

/**
 * The deterministic address of each release contract: its creation code and constructor arguments
 * created through `create2Deployer` with `releaseSalt`, or by its own `creator`, in the release's
 * order, so a contract that binds earlier ones (the EarnFactory) is predicted from their addresses.
 */
export function predictRelease(
  plan: FactoryReleasePlan,
  creationBytecode: (contract: string) => Hex,
): PredictedContract[] {
  const addresses: Record<string, Address> = {}
  return plan.contracts.map(({ constructorArgs: encode, creator, ...contract }) => {
    const constructorArgs = encode?.(addresses) ?? '0x'
    const initCode = concatHex([creationBytecode(contract.contract), constructorArgs])
    const address = getContractAddress({
      opcode: 'CREATE2',
      from: creator?.address ?? create2Deployer,
      salt: creator?.salt ?? releaseSalt,
      bytecode: initCode,
    })
    addresses[contract.name] = address
    return { ...contract, address, transaction: null, constructorArgs, initCode }
  })
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

type Creation = { name: string | null; address: Address | null; hash: Hex | null; initCode: string }

/**
 * Every contract a broadcast file records as created: each creating transaction's contract (for the
 * CREATE2 deployer, whose calldata is the salt followed by the creation code, that creation code)
 * and each contract a transaction created inside its call, such as a ZoneRouter its factory created.
 */
function broadcastCreations(file: BroadcastFile): Creation[] {
  const optionalAddress = (value: string | null | undefined) => (value ? getAddress(value) : null)
  return (file.transactions ?? []).flatMap((transaction) => {
    const hash = (transaction.hash ?? null) as Hex | null
    const input = (transaction.transaction?.input ?? '').toLowerCase()
    const created: Creation[] = transaction.transactionType?.startsWith('CREATE')
      ? [
          {
            name: transaction.contractName ?? null,
            address: optionalAddress(transaction.contractAddress),
            hash,
            initCode: input.startsWith(releaseSalt.toLowerCase()) ? `0x${input.slice(66)}` : input,
          },
        ]
      : []
    for (const contract of transaction.additionalContracts ?? []) {
      created.push({
        name: contract.contractName ?? null,
        address: optionalAddress(contract.address),
        hash,
        initCode: (contract.initCode ?? '').toLowerCase(),
      })
    }
    return created
  })
}

/**
 * Reads the contracts a release run created from its broadcast file, matched by address. It must
 * have created exactly the predicted contracts that did not exist yet, each once, at its
 * deterministic address, from its locally compiled creation code, whether a transaction created it
 * or a call did (a ZoneRouter its factory creates), and, after a broadcast, each in a transaction
 * with a successful receipt. Contracts that existed keep a null transaction.
 */
export function createdContracts(
  plan: FactoryReleasePlan,
  file: BroadcastFile,
  predicted: readonly PredictedContract[],
  existing: ReadonlySet<Address>,
  broadcast: boolean,
): CreatedContract[] {
  const creations = broadcastCreations(file)
  const missing = predicted.filter((contract) => !existing.has(contract.address))
  const list = (labels: string[]) => labels.sort().join(', ')
  const addresses = (entries: readonly { address: Address | null }[]) =>
    list(entries.map((entry) => entry.address ?? 'none'))
  if (addresses(creations) !== addresses(missing)) {
    const label = (creation: Creation) =>
      predicted.find((contract) => contract.address === creation.address)?.name ??
      `${creation.name ?? 'a contract'} at ${creation.address ?? 'no address'}`
    throw new Error(
      `The ${plan.kind} release created ${list(creations.map(label)) || 'nothing'}, expected ${list(missing.map((contract) => contract.name)) || 'nothing'}`,
    )
  }
  return predicted.map(({ initCode, ...contract }) => {
    if (existing.has(contract.address)) return contract
    const creation = creations.find((candidate) => candidate.address === contract.address)!
    if (broadcast) {
      const receipt = file.receipts?.find(
        (candidate) => candidate.transactionHash?.toLowerCase() === creation.hash?.toLowerCase(),
      )
      if (!creation.hash || receipt?.status !== '0x1') {
        throw new Error(
          `${contract.name} creation ${creation.hash ?? 'without a hash'} has no successful receipt`,
        )
      }
    }
    if (creation.initCode !== initCode.toLowerCase()) {
      throw new Error(
        `${contract.name} creation input is not its locally compiled creation code and constructor arguments`,
      )
    }
    return { ...contract, transaction: creation.hash }
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
  /** The release's parameters, for a kind that takes them. */
  parameters?: FactoryReleaseParameters
  broadcast: boolean
  contracts: (CreatedContract & {
    match: 'exact_match' | 'match' | null
    /** Why source verification failed; the contract is still deployed. */
    verificationError?: string
  })[]
  /** Set when every contract already existed at its deterministic address, so nothing was created. */
  current?: true
  /** The release registry entry to review into deployments/core/releases.ts, when it names one. */
  registry: Record<string, Address> | null
}

export type FactoryReleaseDependencies = {
  /** Runs Forge from the release's Foundry project, where Earn's `solc` wrapper path resolves. */
  forge: (arguments_: string[], environment: Record<string, string>, cwd: string) => void
  readFile: (path: string) => string
  /** A contract's creation bytecode, compiled with the deploy profile. */
  creationBytecode: (
    root: string,
    contract: string,
    environment: Readonly<Record<string, string | undefined>>,
  ) => Hex
  /** Which of these addresses already have code on the chain. */
  existingCode: (
    rpc: ReturnType<typeof rpcConfiguration>,
    addresses: readonly Address[],
  ) => Promise<Set<Address>>
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
  creationBytecode: (root, contract, environment) => {
    const bytecode = execFileSync('forge', ['inspect', contract, 'bytecode'], {
      cwd: root,
      encoding: 'utf8',
      env: foundryVerificationEnvironment(environment) as NodeJS.ProcessEnv,
    }).trim()
    if (!isHex(bytecode) || bytecode === '0x') {
      throw new Error(`Forge returned invalid creation bytecode for ${contract}`)
    }
    return bytecode
  },
  existingCode: async (rpc, addresses) => {
    const client = createPublicClient({ transport: configuredRpcTransport(rpc) })
    const codes = await Promise.all(addresses.map((address) => client.getCode({ address })))
    return new Set(addresses.filter((_, index) => (codes[index] ?? '0x') !== '0x'))
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
 * Deploys one release on a hosted network with its Foundry project's deploy profile, then source
 * verifies every contract in it against Tempo's verifier. Each contract is created at its
 * deterministic address only when that address has no code yet, so a release that already exists
 * is reconciled without broadcasting. Without `broadcast`, Forge only simulates, and nothing is
 * signed or verified.
 */
export async function deployFactoryRelease(
  options: {
    network: string
    kind: string
    /** The kind's parameters (`planFactoryRelease`); none when omitted. */
    parameters?: unknown
    broadcast: boolean
    /** Earn's Foundry project; a router release runs from its sibling `router/`. */
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
  const plan = planFactoryRelease(options.kind, network.chainId, options.parameters ?? {})
  if (!options.environment.DEPLOYER_PRIVATE_KEY) throw new Error('DEPLOYER_PRIVATE_KEY is required')
  const rpc = rpcConfiguration('TEMPO', options.environment, network.rpcUrl)
  if (!rpc.authenticatedUrl) throw new Error(`No RPC for ${network.id}`)
  const root = foundryProjectRoot(options.root, plan.project === 'earn' ? undefined : plan.project)

  runtime.preflight(root, options.environment)
  const predicted = predictRelease(plan, (contract) =>
    runtime.creationBytecode(root, contract, options.environment),
  )
  const existing = await runtime.existingCode(
    rpc,
    predicted.map((contract) => contract.address),
  )
  const current = predicted.every((contract) => existing.has(contract.address))
  let created: CreatedContract[] = predicted.map(({ initCode: _initCode, ...contract }) => contract)
  if (!current) {
    try {
      runtime.forge(
        [
          'script',
          plan.script,
          '--root',
          root,
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
        root,
      )
    } finally {
      runtime.removeScriptCache(root, basename(plan.script.split(':')[0]!))
    }
    const file = JSON.parse(
      runtime.readFile(broadcastPath(root, plan, network.chainId, options.broadcast)),
    ) as BroadcastFile
    created = createdContracts(plan, file, predicted, existing, options.broadcast)
  }

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
        root,
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
    ...(Object.keys(plan.parameters).length > 0 ? { parameters: plan.parameters } : {}),
    broadcast: options.broadcast,
    contracts,
    ...(current ? { current: true as const } : {}),
    registry:
      plan.registryKey && registryContract
        ? { [plan.registryKey]: registryContract.address }
        : null,
  }
}

/** The releases the registry names, in deploy order; `all` deploys these. */
export const registryReleaseKinds: FactoryReleaseKind[] = [
  'core',
  ...engineFactories.map((factory) => factory.releaseKey),
]

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
      if (!release.registry) continue
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
  'Usage: pnpm factory-release <network> <release|all> [--parameters <json>] [--broadcast] [--output <file>]\n' +
  '       pnpm factory-release registry <result.json>... [--body <file>]\n' +
  `  network: ${Object.keys(hostedEnvironments).join(' | ')}\n` +
  `  release: all (${registryReleaseKinds.join(', ')}) | ${factoryReleaseKinds.join(' | ')}\n` +
  '  parameters (JSON object; only these kinds take any):\n' +
  '    sendSettler: {} for a settler that never converts, or {"vault": <address>, "pool": <address>,\n' +
  '                "customerId": <bytes32>} for one that converts the vault asset at par\n' +
  '    zoneRouter: {"factory": <address>, "mode": {"zoneId", "enabledOps", "earnVault", "privateAsset",\n' +
  '                "pool", "customerId", "settlers"}}; bindings and settlers default to zero and []'

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
      parameters: { type: 'string', default: '{}' },
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
  let parameters: unknown
  try {
    parameters = JSON.parse(values.parameters)
  } catch {
    throw new Error('--parameters must be a JSON object')
  }
  // `all` deploys only registry releases, which take no parameters; refuse them before any runs.
  if (selection === 'all' && Object.keys(object(parameters, 'parameters')).length > 0) {
    throw new Error('Parameters apply to a single release, not all')
  }
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
          parameters,
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
