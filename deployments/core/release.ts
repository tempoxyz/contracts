#!/usr/bin/env node
import { randomUUID } from 'node:crypto'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
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
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'
import { Addresses } from 'viem/tempo'

import {
  deployBridgeCardsScriptAbi,
  deployFactoryReleaseScriptAbi,
  deployRouterReleaseScriptAbi,
} from '../abis/index.js'
import {
  assertFoundryVersion,
  assertFoundryProjectEnvironment,
  foundryRpcEnvironment,
  foundryProcessEnvironment,
  foundryVerificationEnvironment,
  sourceVerificationCompilerArguments,
} from '../chain/foundry.js'
import { redactRpcCredentials } from '../chain/rpc-credentials.js'
import { configuredRpcTransport, rpcConfiguration } from '../chain/runtime.js'
import { hostedEnvironment, hostedEnvironments, type HostedEnvironmentId } from '../chain/tempo.js'
import { engineFactories } from '../modules/earn/engines/index.js'
import {
  address,
  array,
  exactKeys,
  object,
  positiveInteger,
  nonemptyString as string,
} from './parse.js'
import { bridgeSpenderFactories, releaseKeys, type ReleaseKey } from './releases.js'
import { verifyContractSource } from './verify.js'

const releaseScript = 'script/earn/deploy/DeployFactoryRelease.s.sol:DeployFactoryReleaseScript'
const routerReleaseScript = 'script/zone/deploy/DeployRouterRelease.s.sol:DeployRouterReleaseScript'
const cardReleaseScript =
  'script/spend/bridge/lifecycle/DeployBridgeCards.s.sol:DeployBridgeCardsScript'

/**
 * Every shared contract `pnpm release` deploys, in deploy order: the core release (EarnVault and
 * EarnFees implementations and the EarnFactory bound to them), the rewards factory, each engine
 * factory by its `releaseKey`, the ZoneRouterFactory, the SendSpender bound to it, the CardFactory
 * bound to it, and Bridge's "TS" handler. Each is ownerless and immutable, created at its CREATE2
 * release address, and recorded in the network's registry entry (`releases.ts`).
 */
export const releaseKinds = [
  'core',
  'rewards',
  ...engineFactories.map((factory) => factory.releaseKey),
  'zoneRouterFactory',
  'sendSpender',
  'cardFactory',
  'tempoSpend',
] as const

export type ReleaseKind = (typeof releaseKinds)[number]

/** The card releases, deployed only where the network declares Bridge's SpenderFactory. */
const cardReleaseKinds: readonly ReleaseKind[] = ['cardFactory', 'tempoSpend']

/**
 * The CREATE2 deployer every release contract is created through: forge-std's `CREATE2_FACTORY`, which
 * Forge routes salted creations to and which every Tempo network has.
 */
export const create2Deployer = getAddress('0x4e59b44847b379578588920cA78FbF26c0B4956C')

/** The salt of every release contract; it must equal `RELEASE_SALT` in DeterministicRelease.sol. */
export const releaseSalt = keccak256(stringToBytes('tempoxyz/earn shared factory release'))

export type ReleaseContract = {
  name: string
  /** Fully qualified `<source>:<name>`, in the plan's Foundry project. */
  contract: string
  /** ABI-encoded constructor arguments, given the addresses of the release's earlier contracts. */
  constructorArgs?: (addresses: Readonly<Record<string, Address>>) => Hex
}

/** A release's validated parameters, as its result records them; empty for a kind that takes none. */
export type ReleaseParameters = Readonly<Record<string, unknown>>

/**
 * One release: its entry point and the contracts it creates, the last of them the one its registry
 * key names. A contract it binds that another release creates (the ZoneRouterFactory) comes first,
 * created only when missing, so each release simulates alone.
 */
export type ReleasePlan = {
  kind: ReleaseKind
  /** `path:Contract` of the Foundry script. */
  script: string
  parameters: ReleaseParameters
  /** Calldata of the release entry point, which takes the expected chain ID. */
  calldata: Hex
  /** The contracts the entry point creates, each exactly once. */
  contracts: readonly ReleaseContract[]
  /** The release's key in the network's registry entry, which names its last contract. */
  registryKey: ReleaseKey
  /** Extra `forge script` arguments. */
  forgeArguments: readonly string[]
}

const zoneRouterFactoryContract = {
  name: 'ZoneRouterFactory',
  contract: 'src/zone/ZoneRouterFactory.sol:ZoneRouterFactory',
}
const addressArgument = parseAbiParameters('address')

/** The release entry point and the contracts it creates for one release kind on one chain. */
export function planRelease(kind: string, chainId: number): ReleasePlan {
  const expectedChainId = BigInt(chainId)
  if (kind === 'core') {
    return {
      kind,
      script: releaseScript,
      parameters: {},
      calldata: encodeFunctionData({
        abi: deployFactoryReleaseScriptAbi,
        functionName: 'earnFactoryRelease',
        args: [expectedChainId],
      }),
      contracts: [
        { name: 'EarnVault', contract: 'src/earn/core/EarnVault.sol:EarnVault' },
        { name: 'EarnFees', contract: 'src/earn/core/EarnFees.sol:EarnFees' },
        {
          name: 'EarnFactory',
          contract: 'src/earn/core/EarnFactory.sol:EarnFactory',
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
      // 30M gas cap (docs/deployment/deployment.md#releases).
      forgeArguments: ['--gas-estimate-multiplier', '100'],
    }
  }
  if (kind === 'rewards') {
    return {
      kind,
      script: releaseScript,
      parameters: {},
      calldata: encodeFunctionData({
        abi: deployFactoryReleaseScriptAbi,
        functionName: 'earnRewardsFactory',
        args: [expectedChainId],
      }),
      contracts: [
        {
          name: 'EarnRewardsFactory',
          contract: 'src/earn/rewards/EarnRewardsFactory.sol:EarnRewardsFactory',
        },
      ],
      registryKey: 'rewards',
      forgeArguments: [],
    }
  }
  if (kind === 'zoneRouterFactory') {
    return {
      kind,
      script: routerReleaseScript,
      parameters: {},
      calldata: encodeFunctionData({
        abi: deployRouterReleaseScriptAbi,
        functionName: 'zoneRouterFactory',
        args: [expectedChainId],
      }),
      contracts: [zoneRouterFactoryContract],
      registryKey: 'zoneRouterFactory',
      forgeArguments: [],
    }
  }
  if (kind === 'sendSpender') {
    // The SendSpender that never converts, bound to the release ZoneRouterFactory.
    return {
      kind,
      script: routerReleaseScript,
      parameters: {},
      calldata: encodeFunctionData({
        abi: deployRouterReleaseScriptAbi,
        functionName: 'sendSpender',
        args: [expectedChainId, zeroAddress, zeroAddress, zeroAddress, zeroHash],
      }),
      contracts: [
        zoneRouterFactoryContract,
        {
          name: 'SendSpender',
          contract: 'src/zone/spenders/SendSpender.sol:SendSpender',
          constructorArgs: (addresses) =>
            encodeAbiParameters(parseAbiParameters('address, address, address, bytes32'), [
              requiredAddress(addresses, zoneRouterFactoryContract.name),
              zeroAddress,
              zeroAddress,
              zeroHash,
            ]),
        },
      ],
      registryKey: 'sendSpender',
      forgeArguments: [],
    }
  }
  if (kind === 'cardFactory') {
    return {
      kind,
      script: cardReleaseScript,
      parameters: {},
      calldata: encodeFunctionData({
        abi: deployBridgeCardsScriptAbi,
        functionName: 'cardFactory',
        args: [expectedChainId],
      }),
      contracts: [
        zoneRouterFactoryContract,
        {
          name: 'CardFactory',
          contract: 'src/spend/CardFactory.sol:CardFactory',
          constructorArgs: (addresses) =>
            encodeAbiParameters(addressArgument, [
              requiredAddress(addresses, zoneRouterFactoryContract.name),
            ]),
        },
      ],
      registryKey: 'cardFactory',
      forgeArguments: [],
    }
  }
  if (kind === 'tempoSpend') {
    const network = hostedEnvironment(chainId)
    const spenderFactory = network ? bridgeSpenderFactories[network.id] : null
    if (!spenderFactory)
      throw new Error(
        `No Bridge SpenderFactory is declared for chain ${chainId} (bridgeSpenderFactories in deployments/core/releases.ts)`,
      )
    return {
      kind,
      script: cardReleaseScript,
      parameters: { factory: spenderFactory },
      calldata: encodeFunctionData({
        abi: deployBridgeCardsScriptAbi,
        functionName: 'tempoSpend',
        args: [expectedChainId, spenderFactory],
      }),
      contracts: [
        {
          name: 'SpenderTempoSpend',
          contract: 'src/spend/providers/bridge/SpenderTempoSpend.sol:SpenderTempoSpend',
          constructorArgs: () => encodeAbiParameters(addressArgument, [spenderFactory]),
        },
      ],
      registryKey: 'tempoSpend',
      forgeArguments: [],
    }
  }
  const factory = engineFactories.find((candidate) => candidate.releaseKey === kind)
  if (!factory) {
    throw new Error(`Unknown release ${kind}; expected one of ${releaseKinds.join(', ')}`)
  }
  return {
    kind: factory.releaseKey,
    script: factory.deployScript,
    parameters: {},
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
    /** Contracts the transaction created inside its call. */
    additionalContracts?: {
      transactionType?: string
      contractName?: string | null
      address?: string | null
      initCode?: string | null
    }[]
  }[]
  receipts?: { transactionHash?: string; status?: string }[]
}

export type CreatedContract = Omit<ReleaseContract, 'constructorArgs'> & {
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

/** The address `initCode` (creation code and constructor arguments) is released at. */
export function releaseAddress(initCode: Hex) {
  return getContractAddress({
    opcode: 'CREATE2',
    from: create2Deployer,
    salt: releaseSalt,
    bytecode: initCode,
  })
}

/**
 * The deterministic address of each release contract: its creation code and constructor arguments
 * created through `create2Deployer` with `releaseSalt`, in the release's order, so a contract that
 * binds earlier ones (the EarnFactory) is predicted from their addresses.
 */
export function predictRelease(
  plan: ReleasePlan,
  creationBytecode: (contract: string) => Hex,
): PredictedContract[] {
  const addresses: Record<string, Address> = {}
  return plan.contracts.map(({ constructorArgs: encode, ...contract }) => {
    const constructorArgs = encode?.(addresses) ?? '0x'
    const initCode = concatHex([creationBytecode(contract.contract), constructorArgs])
    const address = releaseAddress(initCode)
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
  plan: ReleasePlan,
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
 * and each contract a transaction created inside its call.
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
 * deterministic address, from its locally compiled creation code, and, after a broadcast, each in a
 * transaction with a successful receipt. Contracts that existed keep a null transaction.
 */
export function createdContracts(
  plan: ReleasePlan,
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

/** Preserves previous evidence without allowing Forge's no-op run to claim it as fresh output. */
export function archiveReleaseBroadcast(path: string) {
  if (existsSync(path)) renameSync(path, `${path}.previous-${randomUUID()}`)
}

/** Reconciles Forge's simulated creations against the mined transaction and receipt. */
export async function confirmReleaseCreations(
  client: Pick<PublicClient, 'getTransactionReceipt' | 'getTransaction'>,
  created: readonly CreatedContract[],
  predicted: readonly PredictedContract[],
): Promise<CreatedContract[]> {
  return Promise.all(
    created.map(async (contract) => {
      if (!contract.transaction) return contract
      const receipt = await client.getTransactionReceipt({ hash: contract.transaction })
      if (
        receipt.status !== 'success' ||
        receipt.transactionHash.toLowerCase() !== contract.transaction.toLowerCase()
      )
        throw new Error(`${contract.name} creation has no successful mined receipt`)
      const transaction = await client.getTransaction({ hash: contract.transaction })
      const expected = predicted.find((entry) => entry.name === contract.name)!
      if (
        transaction.to?.toLowerCase() !== create2Deployer.toLowerCase() ||
        transaction.input.toLowerCase() !==
          concatHex([releaseSalt, expected.initCode]).toLowerCase()
      )
        throw new Error(`${contract.name} mined transaction is not its deterministic creation`)
      return contract
    }),
  )
}

// Preserve the release module's existing redaction API for its callers.
export { redactRpcCredentials } from '../chain/rpc-credentials.js'

export type ReleaseResult = {
  network: HostedEnvironmentId
  chainId: number
  kind: ReleaseKind
  /** The release's parameters, for a kind that takes them. */
  parameters?: ReleaseParameters
  broadcast: boolean
  contracts: (CreatedContract & {
    match: 'exact_match' | 'match' | null
    /** Why source verification failed; the contract is still deployed. */
    verificationError?: string
  })[]
  /** Set when every contract already existed at its deterministic address, so nothing was created. */
  current?: true
  /** The registry entry to record in deployments/core/releases.ts. */
  registry: Partial<Record<ReleaseKey, Address>>
}

export type ReleaseDependencies = {
  /** RPC reads are made before even an already-deployed release can be certified. */
  client: (
    rpc: ReturnType<typeof rpcConfiguration>,
  ) => Pick<
    PublicClient,
    'getChainId' | 'readContract' | 'getTransactionReceipt' | 'getTransaction'
  >
  /** Moves aside the previous selector-latest artifact before starting Forge. */
  archiveBroadcast: (path: string) => void
  /** Confirms attributed creations with mined RPC evidence. */
  confirmCreations: typeof confirmReleaseCreations
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

const defaultDependencies: ReleaseDependencies = {
  client: (rpc) => createPublicClient({ transport: configuredRpcTransport(rpc) }),
  archiveBroadcast: archiveReleaseBroadcast,
  confirmCreations: confirmReleaseCreations,
  forge: (arguments_, environment, cwd) => {
    assertFoundryProjectEnvironment(cwd)
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
    assertFoundryProjectEnvironment(root)
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

/** Where and how one release runs. */
export type ReleaseOptions = {
  /** Request canonical re-verification of invalid verifier entries after deployment. */
  resubmit?: boolean
  network: string
  broadcast: boolean
  /** The repository root, the Foundry project every release builds and runs in. */
  root: string
  environment: Readonly<Record<string, string | undefined>>
}

/**
 * Deploys one release on a hosted network with the repository's deploy profile, then source verifies
 * every contract in it against Tempo's verifier. Each contract is created at its deterministic
 * address only when that address has no code yet, so a release that already exists is reconciled
 * without broadcasting. Without `broadcast`, Forge only simulates, and nothing is signed or verified.
 */
export async function deployRelease(
  options: ReleaseOptions & { kind: string },
  dependencies: Partial<ReleaseDependencies> = {},
): Promise<ReleaseResult> {
  if (options.resubmit && !options.broadcast)
    throw new Error('--resubmit-verification requires --broadcast')
  const runtime = { ...defaultDependencies, ...dependencies }
  const network = hostedEnvironments[options.network as HostedEnvironmentId]
  if (!network) {
    throw new Error(
      `Unknown hosted network ${options.network}; expected one of ${Object.keys(hostedEnvironments).join(', ')}`,
    )
  }
  const plan = planRelease(options.kind, network.chainId)
  if (!options.environment.DEPLOYER_PRIVATE_KEY) throw new Error('DEPLOYER_PRIVATE_KEY is required')
  const rpc = rpcConfiguration('TEMPO', options.environment, network.rpcUrl)
  if (!rpc.authenticatedUrl) throw new Error(`No RPC for ${network.id}`)
  const root = options.root

  const client = runtime.client(rpc)
  const actualChainId = await client.getChainId()
  if (actualChainId !== network.chainId)
    throw new Error(
      `Release RPC chain ${actualChainId} does not match ${network.id} (${network.chainId})`,
    )
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
    const path = broadcastPath(root, plan, network.chainId, options.broadcast)
    runtime.archiveBroadcast(path)
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
          '--slow',
          ...plan.forgeArguments,
          ...(options.broadcast ? ['--broadcast'] : []),
        ],
        foundryRpcEnvironment(foundryProcessEnvironment(options.environment), rpc.authenticatedUrl),
        root,
      )
    } finally {
      runtime.removeScriptCache(root, basename(plan.script.split(':')[0]!))
    }
    let contents: string | undefined
    try {
      contents = runtime.readFile(path)
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
    if (contents === undefined) {
      // Another deployment can win before Forge simulates. No new artifact means no creation claim.
      const observed = await runtime.existingCode(
        rpc,
        predicted.map((contract) => contract.address),
      )
      if (!predicted.every((contract) => observed.has(contract.address)))
        throw new Error(
          'Forge produced no fresh release artifact and release contracts are missing',
        )
    } else {
      created = createdContracts(
        plan,
        JSON.parse(contents) as BroadcastFile,
        predicted,
        existing,
        options.broadcast,
      )
      if (options.broadcast) created = await runtime.confirmCreations(client, created, predicted)
    }
  }

  const contracts: ReleaseResult['contracts'] = []
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
        resubmit: options.resubmit,
        ...(contract.transaction ? { creationTransactionHash: contract.transaction } : {}),
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
  return {
    network: network.id,
    chainId: network.chainId,
    kind: plan.kind,
    ...(Object.keys(plan.parameters).length > 0 ? { parameters: plan.parameters } : {}),
    broadcast: options.broadcast,
    contracts,
    ...(current ? { current: true as const } : {}),
    registry: { [plan.registryKey]: created.at(-1)!.address },
  }
}

/**
 * Every release a network takes, in deploy order: all of them, except the card releases where the
 * network declares no Bridge SpenderFactory, since no profile can declare a card program there.
 */
export function networkReleaseKinds(network: string): ReleaseKind[] {
  if (!Object.hasOwn(hostedEnvironments, network))
    throw new Error(
      `Unknown hosted network ${network}; expected one of ${Object.keys(hostedEnvironments).join(', ')}`,
    )
  const cards = bridgeSpenderFactories[network as HostedEnvironmentId] !== null
  return releaseKinds.filter((kind) => cards || !cardReleaseKinds.includes(kind))
}

/** One network's run of its releases, written after each release so a failure keeps the rest. */
export type ReleaseRun = {
  network: string
  chainId: number | null
  broadcast: boolean
  releases: ReleaseResult[]
  /** The release that stopped the run, when one did. */
  failed?: { kind: string }
}

/**
 * Runs each release in turn on one network, writing the run to `output` after each so a failure
 * keeps the releases before it, then fails on any deployed contract whose source verification
 * failed, pointing to `retry` for how to retry it without redeploying.
 */
export async function runReleases(options: {
  network: string
  kinds: readonly ReleaseKind[]
  broadcast: boolean
  output: string | undefined
  deploy: (kind: ReleaseKind) => Promise<ReleaseResult>
  retry: string
}): Promise<ReleaseRun> {
  const run: ReleaseRun = {
    network: options.network,
    chainId: hostedEnvironments[options.network as HostedEnvironmentId]?.chainId ?? null,
    broadcast: options.broadcast,
    releases: [],
  }
  const record = () => {
    const json = `${JSON.stringify(run, null, 2)}\n`
    if (options.output) writeFileSync(options.output, json)
    return json
  }
  for (const kind of options.kinds) {
    try {
      run.releases.push(await options.deploy(kind))
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
      `Deployed but not source verified: ${unverified.map((contract) => `${contract.name} ${contract.address} (${contract.verificationError})`).join('; ')}. Retry with forge verify-contract (${options.retry}); do not rerun the release.`,
    )
  }
  return run
}

/** Parses result files before they can become a reviewed registry change. */
export function parseReleaseRun(value: unknown): ReleaseRun {
  const run = object(value, 'release run')
  exactKeys(run, 'release run', ['network', 'chainId', 'broadcast', 'releases'], ['failed'])
  const network = string(run.network, 'network')
  if (!Object.hasOwn(hostedEnvironments, network))
    throw new Error(`Unknown hosted network ${network}`)
  const chainId = positiveInteger(run.chainId, 'chainId')
  if (chainId !== hostedEnvironments[network as HostedEnvironmentId].chainId)
    throw new Error(`Release run chainId does not match ${network}`)
  if (typeof run.broadcast !== 'boolean') throw new Error('broadcast must be boolean')
  const broadcast = run.broadcast
  const releases = array(run.releases, 'releases').map((value, index): ReleaseResult => {
    const path = `releases.${index}`
    const release = object(value, path)
    exactKeys(
      release,
      path,
      ['network', 'chainId', 'kind', 'broadcast', 'contracts', 'registry'],
      ['parameters', 'current'],
    )
    if (
      release.network !== network ||
      release.chainId !== chainId ||
      release.broadcast !== broadcast
    )
      throw new Error(`${path} does not match its run`)
    const plan = planRelease(string(release.kind, `${path}.kind`), chainId)
    if (
      JSON.stringify(release.parameters ?? {}) !== JSON.stringify(plan.parameters) ||
      (release.parameters !== undefined && Object.keys(plan.parameters).length === 0)
    )
      throw new Error(`${path}.parameters do not match the ${plan.kind} release`)
    if (release.current !== undefined && release.current !== true)
      throw new Error(`${path}.current must be true`)
    const contracts = array(release.contracts, `${path}.contracts`).map((value) => {
      const contract = object(value, `${path}.contract`)
      exactKeys(
        contract,
        `${path}.contract`,
        ['name', 'contract', 'address', 'transaction', 'constructorArgs', 'match'],
        ['verificationError'],
      )
      const input = string(contract.constructorArgs, 'constructorArgs')
      if (!/^0x(?:[0-9a-fA-F]{2})*$/.test(input)) throw new Error('Invalid constructorArgs')
      const transaction = contract.transaction
      if (
        transaction !== null &&
        (typeof transaction !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(transaction))
      )
        throw new Error('Invalid creation transaction')
      if (contract.match !== null && contract.match !== 'match' && contract.match !== 'exact_match')
        throw new Error('Invalid source match')
      return {
        name: string(contract.name, 'name'),
        contract: string(contract.contract, 'contract'),
        address: address(contract.address, 'address'),
        transaction: transaction as Hex | null,
        constructorArgs: input as Hex,
        match: contract.match as 'match' | 'exact_match' | null,
        ...(contract.verificationError === undefined
          ? {}
          : { verificationError: string(contract.verificationError, 'verificationError') }),
      }
    })
    const registry = Object.fromEntries(
      Object.entries(object(release.registry, 'registry')).map(([key, value]) => [
        key,
        address(value, `registry.${key}`),
      ]),
    )
    return {
      network: network as HostedEnvironmentId,
      chainId,
      kind: plan.kind,
      ...(Object.keys(plan.parameters).length > 0 ? { parameters: plan.parameters } : {}),
      broadcast,
      contracts,
      registry,
      ...(release.current ? { current: true } : {}),
    }
  })
  if (new Set(releases.map((release) => release.kind)).size !== releases.length)
    throw new Error('Duplicate release kind')
  const failed = run.failed === undefined ? undefined : object(run.failed, 'failed')
  if (failed) exactKeys(failed, 'failed', ['kind'])
  return {
    network,
    chainId,
    broadcast,
    releases,
    ...(failed
      ? { failed: { kind: planRelease(string(failed.kind, 'failed.kind'), chainId).kind } }
      : {}),
  }
}

type RegistryUpdate = { network: string; key: ReleaseKey; address: Address; kind: string }

/**
 * The registry entries a set of runs proves: each broadcast release whose every contract source
 * verified. Anything else is skipped with its reason.
 */
export function registryUpdates(
  values: readonly unknown[],
  compile: (contract: string) => Hex = (contract) =>
    defaultDependencies.creationBytecode(
      fileURLToPath(new URL('../..', import.meta.url)),
      contract,
      process.env,
    ),
) {
  const runs = values.map(parseReleaseRun)
  const updates: RegistryUpdate[] = []
  const skipped: { network: string; kind: string; reason: string }[] = []
  for (const run of runs) {
    if (run.failed) skipped.push({ network: run.network, kind: run.failed.kind, reason: 'failed' })
    for (const release of run.releases) {
      const plan = planRelease(release.kind, release.chainId)
      if (!run.broadcast || !release.broadcast) {
        skipped.push({ network: run.network, kind: release.kind, reason: 'dry run' })
        continue
      }
      const unverified = release.contracts.filter(
        (contract) => contract.match !== 'match' && contract.match !== 'exact_match',
      )
      if (unverified.length > 0) {
        skipped.push({
          network: run.network,
          kind: release.kind,
          reason: `not source verified: ${unverified.map((contract) => contract.name).join(', ')}`,
        })
        continue
      }
      const predicted = predictRelease(plan, compile)
      if (
        release.contracts.length !== predicted.length ||
        new Set(release.contracts.map((contract) => contract.name)).size !== predicted.length
      )
        throw new Error(`Release ${release.kind} must contain its complete expected contract set`)
      for (const expected of predicted) {
        const actual = release.contracts.find((contract) => contract.name === expected.name)
        if (
          !actual ||
          actual.contract !== expected.contract ||
          actual.address !== expected.address ||
          actual.constructorArgs.toLowerCase() !== expected.constructorArgs.toLowerCase()
        )
          throw new Error(
            `Release ${release.kind} ${expected.name} does not match the locally compiled CREATE2 release`,
          )
      }
      if (
        Object.keys(release.registry).length !== 1 ||
        release.registry[plan.registryKey] !== predicted.at(-1)!.address
      )
        throw new Error(`Release ${release.kind} registry does not match its deterministic address`)
      updates.push({
        network: run.network,
        key: plan.registryKey,
        address: predicted.at(-1)!.address,
        kind: release.kind,
      })
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
    if (!Object.hasOwn(hostedEnvironments, network))
      throw new Error(`releases.ts has no ${network} release`)
    if (!(releaseKeys as readonly string[]).includes(key))
      throw new Error(`releases.ts has no ${network}.${key} entry`)
    const start = result.indexOf(`\n  ${network}: {\n`)
    const end = start < 0 ? -1 : result.indexOf('\n  },\n', start)
    if (start < 0 || end < 0) throw new Error(`releases.ts has no ${network} release`)
    const block = result.slice(start, end)
    const entry = new RegExp(`^(    ${key}: )(?:getAddress\\('0x[0-9a-fA-F]{40}'\\)|null),$`, 'm')
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
  runs: readonly ReleaseRun[],
  summary: ReturnType<typeof registryUpdates>,
  runUrl?: string,
) {
  const lines = [
    `Records the releases${runUrl ? ` from [the Deploy run](${runUrl})` : ''} in [\`releases.ts\`](deployments/core/releases.ts). Each was broadcast from \`main\` and source verified on contracts.tempo.xyz.`,
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
  'Usage: pnpm release <network> [--broadcast] [--resubmit-verification] [--output <file>]\n' +
  '       pnpm release registry <result.json>... [--body <file>]\n' +
  `  network: ${Object.keys(hostedEnvironments).join(' | ')}\n` +
  `  deploys or reuses, in order: ${releaseKinds.join(', ')} (the card releases only where the network declares Bridge's SpenderFactory)`

/** Applies every verified release in the result files to releases.ts. */
function registryMain(files: string[], body: string | undefined) {
  if (files.length === 0) throw new Error(usage)
  const runs = files.map((file) => parseReleaseRun(JSON.parse(readFileSync(file, 'utf8'))))
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
  root = resolve(fileURLToPath(new URL('../..', import.meta.url))),
) {
  const { positionals, values } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      broadcast: { type: 'boolean', default: false },
      'resubmit-verification': { type: 'boolean', default: false },
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
    if (values['resubmit-verification'])
      throw new Error('--resubmit-verification is not supported by registry')
    registryMain(positionals.slice(1), values.body)
    return
  }
  const [network] = positionals
  if (!network || positionals.length !== 1) throw new Error(usage)
  await runReleases({
    network,
    kinds: networkReleaseKinds(network),
    broadcast: values.broadcast,
    output: values.output,
    deploy: (kind) =>
      deployRelease({
        network,
        kind,
        broadcast: values.broadcast,
        resubmit: values['resubmit-verification'],
        root,
        environment: process.env,
      }),
    retry: 'docs/deployment/deployment.md#releases',
  })
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
