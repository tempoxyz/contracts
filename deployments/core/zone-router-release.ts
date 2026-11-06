#!/usr/bin/env node
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import {
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  getAddress,
  parseEventLogs,
  zeroAddress,
  zeroHash,
  type Abi,
  type Address,
  type Hex,
} from 'viem'

import {
  deployRouterReleaseScriptAbi,
  sendSpenderAbi,
  zoneRouterAbi,
  zoneRouterFactoryAbi,
} from '../abis/index.js'
import { hostedEnvironments } from '../chain/tempo.js'
import {
  deployRelease,
  runReleases,
  type FactoryReleaseDependencies,
  type ReleaseOptions,
  type ReleasePlan,
  type ReleaseResult,
  type ReleaseRun,
} from './factory-release.js'
import { address, exactKeys, isBytes32, object, positiveInteger, unique } from './parse.js'

const routerReleaseScript = 'script/deploy/DeployRouterRelease.s.sol:DeployRouterReleaseScript'

/**
 * The router project's ownerless contracts, released by the shared factory release engine
 * (`deployRelease`) from their own CLI and workflow, and named by no registry entry: the
 * ZoneRouterFactory, a SendSpender, and a ZoneRouter its factory creates. A card program's
 * spender, its CardSpender, releases with the card integration (cards/script/bridge/deploy/release.sh).
 */
export const routerReleaseKinds = ['zoneRouterFactory', 'sendSpender', 'zoneRouter'] as const

export type RouterReleaseKind = (typeof routerReleaseKinds)[number]

/** A ZoneRouter's `ZoneRouter.Mode`, its constructor argument. */
export type ZoneRouterMode = {
  zoneId: number
  enabledOps: number
  earnVault: Address
  privateAsset: Address
  pool: Address
  customerId: Hex
  spenders: Address[]
}

/** A router release's validated parameters, as the result records them. */
export type RouterReleaseParameters =
  | Record<string, never>
  | { factory?: Address; vault: Address; pool: Address; customerId: Hex }
  | { factory: Address; mode: ZoneRouterMode }

export type RouterReleasePlan = ReleasePlan<RouterReleaseKind> & {
  parameters: RouterReleaseParameters
}

const constructorInputs = (abi: Abi) =>
  (abi.find((item) => item.type === 'constructor') as Extract<Abi[number], { type: 'constructor' }>)
    .inputs
const zoneRouterFactoryContract = {
  name: 'ZoneRouterFactory',
  contract: 'src/ZoneRouterFactory.sol:ZoneRouterFactory',
}
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
 * A SendSpender's settings: the ZoneRouterFactory whose routers may call it, omitted for the release
 * ZoneRouterFactory, and its optional conversion binding: the vault whose asset it converts at par,
 * the pool and the customer ID all set, or all omitted for a spender that never converts.
 */
export function parseSendSpenderParameters(value: unknown): {
  factory?: Address
  vault: Address
  pool: Address
  customerId: Hex
} {
  const parameters = object(value, 'parameters')
  const keys = ['vault', 'pool', 'customerId'] as const
  exactKeys(parameters, 'parameters', [], ['factory', ...keys])
  const factory =
    parameters.factory === undefined
      ? {}
      : { factory: address(parameters.factory, 'parameters.factory') }
  const set = keys.filter((key) => parameters[key] !== undefined)
  if (set.length === 0) {
    return { ...factory, vault: zeroAddress, pool: zeroAddress, customerId: zeroHash }
  }
  if (set.length !== keys.length) {
    throw new Error(
      'parameters.vault, parameters.pool and parameters.customerId are set together or not at all',
    )
  }
  return {
    ...factory,
    vault: address(parameters.vault, 'parameters.vault'),
    pool: address(parameters.pool, 'parameters.pool'),
    customerId: nonzeroBytes32(parameters.customerId, 'parameters.customerId'),
  }
}

/**
 * A ZoneRouter's factory and mode. The constructor's rules that need no chain state hold at parse
 * time: Earn bindings exactly with Deposit or Redeem (a pool and customer ID together), and distinct
 * spenders exactly with Spend. Omitted bindings and spenders are zero.
 */
export function parseZoneRouterParameters(value: unknown) {
  const parameters = object(value, 'parameters')
  exactKeys(parameters, 'parameters', ['factory', 'mode'])
  const factory = address(parameters.factory, 'parameters.factory')
  const path = 'parameters.mode'
  const mode = object(parameters.mode, path)
  const earnKeys = ['earnVault', 'privateAsset', 'pool', 'customerId'] as const
  exactKeys(mode, path, ['zoneId', 'enabledOps'], [...earnKeys, 'spenders'])
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
    spenders: [],
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
  if (spends !== (mode.spenders !== undefined)) {
    throw new Error(
      spends
        ? `${path}.spenders is required with spend`
        : `${path}.spenders is not supported without spend`,
    )
  }
  if (spends) {
    const spenders = mode.spenders
    if (!Array.isArray(spenders) || spenders.length === 0) {
      throw new Error(`${path}.spenders must list at least one spender`)
    }
    result.spenders = spenders.map((spender, index) =>
      address(spender, `${path}.spenders[${index}]`),
    )
    unique(result.spenders, `${path}.spenders spender`)
  }
  return { factory, mode: result }
}

function nonzeroBytes32(value: unknown, path: string): Hex {
  if (!isBytes32(value) || BigInt(value) === 0n)
    throw new Error(`${path} must be a nonzero bytes32`)
  return value
}

/**
 * The release entry point and the contracts it creates for one router release kind on one chain,
 * with the kind's parameters: a SendSpender's optional factory and conversion binding and a
 * ZoneRouter's factory and mode. The ZoneRouterFactory takes none.
 */
export function planRouterRelease(
  kind: string,
  chainId: number,
  parameters: unknown = {},
): RouterReleasePlan {
  const expectedChainId = BigInt(chainId)
  if (kind === 'zoneRouterFactory') {
    return {
      kind,
      project: 'zone-router',
      script: routerReleaseScript,
      parameters: noParameters(kind, parameters),
      calldata: encodeFunctionData({
        abi: deployRouterReleaseScriptAbi,
        functionName: 'zoneRouterFactory',
        args: [expectedChainId],
      }),
      contracts: [zoneRouterFactoryContract],
      forgeArguments: [],
    }
  }
  if (kind === 'sendSpender') {
    const spender = parseSendSpenderParameters(parameters)
    // Without a factory the entry point binds the release ZoneRouterFactory, deploying it first when it
    // is not there yet, so the spender's address follows from this build alone.
    const routerFactory = (addresses: Readonly<Record<string, Address>>) => {
      const factory = spender.factory ?? addresses[zoneRouterFactoryContract.name]
      if (!factory) throw new Error('The sendSpender release has no ZoneRouterFactory to bind')
      return factory
    }
    return {
      kind,
      project: 'zone-router',
      script: routerReleaseScript,
      parameters: spender,
      calldata: encodeFunctionData({
        abi: deployRouterReleaseScriptAbi,
        functionName: 'sendSpender',
        args: [
          expectedChainId,
          spender.factory ?? zeroAddress,
          spender.vault,
          spender.pool,
          spender.customerId,
        ],
      }),
      contracts: [
        ...(spender.factory ? [] : [zoneRouterFactoryContract]),
        {
          name: 'SendSpender',
          contract: 'src/spenders/SendSpender.sol:SendSpender',
          constructorArgs: (addresses) =>
            encodeAbiParameters(constructorInputs(sendSpenderAbi), [
              routerFactory(addresses),
              spender.vault,
              spender.pool,
              spender.customerId,
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
      project: 'zone-router',
      script: routerReleaseScript,
      parameters: router,
      validate: async (client) => {
        for (const spender of router.mode.spenders) {
          const bound = await client.readContract({
            address: spender,
            abi: sendSpenderAbi,
            functionName: 'ROUTER_FACTORY',
          })
          if (getAddress(bound) !== router.factory)
            throw new Error(`Spender ${spender} binds factory ${bound}, expected ${router.factory}`)
        }
      },
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
          createdInReceipt: (receipt, address) =>
            parseEventLogs({
              abi: zoneRouterFactoryAbi,
              eventName: 'RouterDeployed',
              logs: receipt.logs,
            }).some(
              (log) =>
                getAddress(log.address) === router.factory &&
                getAddress(log.args.router) === address &&
                log.args.modeHash === keccak256(modeArgs) &&
                encodeAbiParameters(constructorInputs(zoneRouterAbi), [log.args.mode]) === modeArgs,
            ),
        },
      ],
      forgeArguments: [],
    }
  }
  throw unknownRouterRelease(kind)
}

const unknownRouterRelease = (kind: string) =>
  new Error(
    `Unknown router release ${kind}; expected one of ${routerReleaseKinds.join(', ')} (Earn's factory releases run with pnpm factory-release)`,
  )

/** The router release one selection deploys: a single kind, since none is in a registry `all`. */
export function routerReleaseKindFor(selection: string): RouterReleaseKind {
  if (!(routerReleaseKinds as readonly string[]).includes(selection)) {
    throw unknownRouterRelease(selection)
  }
  return selection as RouterReleaseKind
}

export type RouterReleaseResult = ReleaseResult<RouterReleaseKind>
export type RouterReleaseRun = ReleaseRun<RouterReleaseKind>

/**
 * Deploys one router release on a hosted network with the router project's deploy profile, then
 * source verifies its contract against Tempo's verifier (`deployRelease`).
 */
export function deployRouterRelease(
  options: ReleaseOptions & {
    kind: string
    /** The kind's parameters (`planRouterRelease`); none when omitted. */
    parameters?: unknown
  },
  dependencies: Partial<FactoryReleaseDependencies> = {},
): Promise<RouterReleaseResult> {
  const { kind, parameters = {}, ...release } = options
  return deployRelease(
    { ...release, plan: (chainId) => planRouterRelease(kind, chainId, parameters) },
    dependencies,
  )
}

const usage =
  'Usage: pnpm zone-router-release <network> <release> [--parameters <json>] [--broadcast] [--output <file>]\n' +
  `  network: ${Object.keys(hostedEnvironments).join(' | ')}\n` +
  `  release: ${routerReleaseKinds.join(' | ')}\n` +
  '  parameters (JSON object; only these kinds take any):\n' +
  '    sendSpender: {} for a spender that never converts, or {"vault": <address>, "pool": <address>,\n' +
  '                "customerId": <bytes32>} for one that converts the vault asset at par; it binds the\n' +
  '                release ZoneRouterFactory, deployed first if missing, unless "factory": <address> names another\n' +
  '    zoneRouter: {"factory": <address>, "mode": {"zoneId", "enabledOps", "earnVault", "privateAsset",\n' +
  '                "pool", "customerId", "spenders"}}; bindings and spenders default to zero and []\n' +
  "Earn's factory releases run with pnpm factory-release."

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
      help: { type: 'boolean', short: 'h' },
    },
  })
  if (values.help) {
    console.log(usage)
    return
  }
  const [network, kind] = positionals
  if (!network || !kind || positionals.length !== 2) throw new Error(usage)
  let parameters: unknown
  try {
    parameters = JSON.parse(values.parameters)
  } catch {
    throw new Error('--parameters must be a JSON object')
  }
  await runReleases({
    network,
    kinds: [routerReleaseKindFor(kind)],
    broadcast: values.broadcast,
    output: values.output,
    deploy: (release) =>
      deployRouterRelease({
        network,
        kind: release,
        parameters,
        broadcast: values.broadcast,
        root,
        environment: process.env,
      }),
    retry: 'docs/deployment/deployment.md#zone-router-releases',
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
