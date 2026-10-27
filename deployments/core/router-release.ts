#!/usr/bin/env node
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import {
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  zeroAddress,
  zeroHash,
  type Abi,
  type Address,
  type Hex,
} from 'viem'

import { deployRouterReleaseScriptAbi, sendSettlerAbi, zoneRouterAbi } from '../abis/index.js'
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
 * ZoneRouterFactory, a SendSettler, and a ZoneRouter its factory creates.
 */
export const routerReleaseKinds = ['zoneRouterFactory', 'sendSettler', 'zoneRouter'] as const

export type RouterReleaseKind = (typeof routerReleaseKinds)[number]

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

/** A router release's validated parameters, as the result records them. */
export type RouterReleaseParameters =
  | Record<string, never>
  | { vault: Address; pool: Address; customerId: Hex }
  | { factory: Address; mode: ZoneRouterMode }

export type RouterReleasePlan = ReleasePlan<RouterReleaseKind> & {
  parameters: RouterReleaseParameters
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
 * The release entry point and the contract it creates for one router release kind on one chain,
 * with the kind's parameters: a SendSettler's optional conversion binding, and a ZoneRouter's
 * factory and mode. The ZoneRouterFactory takes none.
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
  'Usage: pnpm router-release <network> <release> [--parameters <json>] [--broadcast] [--output <file>]\n' +
  `  network: ${Object.keys(hostedEnvironments).join(' | ')}\n` +
  `  release: ${routerReleaseKinds.join(' | ')}\n` +
  '  parameters (JSON object; only these kinds take any):\n' +
  '    sendSettler: {} for a settler that never converts, or {"vault": <address>, "pool": <address>,\n' +
  '                "customerId": <bytes32>} for one that converts the vault asset at par\n' +
  '    zoneRouter: {"factory": <address>, "mode": {"zoneId", "enabledOps", "earnVault", "privateAsset",\n' +
  '                "pool", "customerId", "settlers"}}; bindings and settlers default to zero and []\n' +
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
    retry: 'docs/deployment/deployment.md#router-releases',
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
