#!/usr/bin/env node
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import {
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  getContractAddress,
  parseAbiParameters,
  type Address,
  type Hex,
} from 'viem'

import { deployBridgeCardsScriptAbi } from '../../abis/index.js'
import { hostedEnvironment, hostedEnvironments } from '../../chain/tempo.js'
import {
  create2Deployer,
  deployRelease,
  predictRelease,
  releaseSalt,
  runReleases,
  type FactoryReleaseDependencies,
  type ReleaseOptions,
  type ReleasePlan,
  type ReleaseResult,
} from '../../core/factory-release.js'
import { releaseCreationCode } from '../zone-router/releases.js'
import { bridgeSpenderFactories } from './profile.js'

const script = 'script/spend/bridge/lifecycle/DeployBridgeCards.s.sol:DeployBridgeCardsScript'

/**
 * The card integration's shared ownerless contracts, released by the shared release engine
 * (`deployRelease`) at their deterministic addresses: the `CardFactory` bound to the release
 * `ZoneRouterFactory`, and Bridge's "TS" handler for the network's declared `SpenderFactory`.
 * Each profile's program deploys with the profile (`deploy-card-program`).
 */
export const cardReleaseKinds = ['cardFactory', 'tempoSpend'] as const

export type CardReleaseKind = (typeof cardReleaseKinds)[number]

const zoneRouterFactoryContract = {
  name: 'ZoneRouterFactory',
  contract: 'src/zone/ZoneRouterFactory.sol:ZoneRouterFactory',
}
const address = parseAbiParameters('address')

/** The release entry point and the contracts it creates for one card release on one chain. */
export function planCardRelease(kind: string, chainId: number): ReleasePlan<CardReleaseKind> {
  if (kind === 'cardFactory') return cardFactoryPlan(chainId)
  if (kind === 'tempoSpend') {
    const network = hostedEnvironment(chainId)
    const factory = network ? bridgeSpenderFactories[network.id] : null
    if (!factory)
      throw new Error(
        `No Bridge SpenderFactory is declared for chain ${chainId} (bridgeSpenderFactories in deployments/modules/cards/profile.ts)`,
      )
    return tempoSpendPlan(chainId, factory)
  }
  throw new Error(
    `Unknown card release ${kind}; expected all or one of ${cardReleaseKinds.join(', ')}`,
  )
}

/** The CardFactory, after the release ZoneRouterFactory it binds, which it deploys when missing. */
function cardFactoryPlan(chainId: number): ReleasePlan<CardReleaseKind> {
  return {
    kind: 'cardFactory',
    script,
    parameters: {},
    calldata: encodeFunctionData({
      abi: deployBridgeCardsScriptAbi,
      functionName: 'cardFactory',
      args: [BigInt(chainId)],
    }),
    contracts: [
      zoneRouterFactoryContract,
      {
        name: 'CardFactory',
        contract: 'src/spend/CardFactory.sol:CardFactory',
        constructorArgs: (addresses) =>
          encodeAbiParameters(address, [addresses[zoneRouterFactoryContract.name]!]),
      },
    ],
    forgeArguments: [],
  }
}

function tempoSpendPlan(chainId: number, factory: Address): ReleasePlan<CardReleaseKind> {
  return {
    kind: 'tempoSpend',
    script,
    parameters: { factory },
    calldata: encodeFunctionData({
      abi: deployBridgeCardsScriptAbi,
      functionName: 'tempoSpend',
      args: [BigInt(chainId), factory],
    }),
    contracts: [
      {
        name: 'SpenderTempoSpend',
        contract: 'src/spend/providers/bridge/SpenderTempoSpend.sol:SpenderTempoSpend',
        constructorArgs: () => encodeAbiParameters(address, [factory]),
      },
    ],
    forgeArguments: [],
  }
}

/**
 * The kinds one selection releases on a network. `all` releases both only where the network declares
 * Bridge's `SpenderFactory`, since no profile can declare a card program elsewhere.
 */
export function cardReleaseKindsFor(selection: string, network: string): CardReleaseKind[] {
  if (selection === 'all')
    return bridgeSpenderFactories[network as keyof typeof bridgeSpenderFactories]
      ? [...cardReleaseKinds]
      : []
  if (!(cardReleaseKinds as readonly string[]).includes(selection))
    throw new Error(
      `Unknown card release ${selection}; expected all or one of ${cardReleaseKinds.join(', ')}`,
    )
  return [selection as CardReleaseKind]
}

/** The addresses this checkout's build releases at, which the profile lifecycle checks programs against. */
export const cardReleases = {
  /** The release ZoneRouterFactory and the CardFactory bound to it. */
  cardFactory(compile: (contract: string) => Hex = releaseCreationCode) {
    const [routerFactory, cardFactory] = predictRelease(cardFactoryPlan(0), compile)
    return { routerFactory: routerFactory!.address, cardFactory: cardFactory!.address }
  },
  /** The "TS" handler for `factory`. */
  tempoSpend(factory: Address, compile: (contract: string) => Hex = releaseCreationCode) {
    return predictRelease(tempoSpendPlan(0, factory), compile)[0]!.address
  },
  /** A program's `BridgeProvider`, created at its release address like the release contracts. */
  bridgeProvider(
    factory: Address,
    spenderId: Hex,
    compile: (contract: string) => Hex = releaseCreationCode,
  ) {
    return getContractAddress({
      opcode: 'CREATE2',
      from: create2Deployer,
      salt: releaseSalt,
      bytecode: concatHex([
        compile('src/spend/providers/bridge/BridgeProvider.sol:BridgeProvider'),
        encodeAbiParameters(parseAbiParameters('address, bytes32'), [factory, spenderId]),
      ]),
    })
  },
}

/** Deploys one card release on a hosted network, then source verifies its contracts (`deployRelease`). */
export function deployCardRelease(
  options: ReleaseOptions & { kind: string },
  dependencies: Partial<FactoryReleaseDependencies> = {},
): Promise<ReleaseResult<CardReleaseKind>> {
  const { kind, ...release } = options
  return deployRelease(
    { ...release, plan: (chainId) => planCardRelease(kind, chainId) },
    dependencies,
  )
}

const usage =
  'Usage: pnpm card-release <network> <release|all> [--broadcast] [--resubmit-verification] [--output <file>]\n' +
  `  network: ${Object.keys(hostedEnvironments).join(' | ')}\n` +
  `  release: all | ${cardReleaseKinds.join(' | ')}; all releases nothing on a network that declares no Bridge SpenderFactory`

/** CLI boundary; reads DEPLOYER_PRIVATE_KEY and the optional TEMPO_RPC_* from the environment. */
export async function main(
  argv: string[] = process.argv.slice(2),
  root = resolve(fileURLToPath(new URL('../../..', import.meta.url))),
) {
  const { positionals, values } = parseArgs({
    args: argv,
    allowPositionals: true,
    options: {
      broadcast: { type: 'boolean', default: false },
      'resubmit-verification': { type: 'boolean', default: false },
      output: { type: 'string' },
      help: { type: 'boolean', short: 'h' },
    },
  })
  if (values.help) {
    console.log(usage)
    return
  }
  const [network, selection] = positionals
  if (!network || !selection || positionals.length !== 2) throw new Error(usage)
  if (!Object.hasOwn(hostedEnvironments, network))
    throw new Error(
      `Unknown hosted network ${network}; expected one of ${Object.keys(hostedEnvironments).join(', ')}`,
    )
  await runReleases({
    network,
    kinds: cardReleaseKindsFor(selection, network),
    broadcast: values.broadcast,
    output: values.output,
    deploy: (kind) =>
      deployCardRelease({
        network,
        kind,
        broadcast: values.broadcast,
        resubmit: values['resubmit-verification'],
        root,
        environment: process.env,
      }),
    retry: 'docs/deployment/deployment.md#card-releases',
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
