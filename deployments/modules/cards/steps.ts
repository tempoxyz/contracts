import {
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  getAbiItem,
  getAddress,
  parseAbiParameters,
  stringToHex,
  type Address,
  type Hex,
} from 'viem'

import {
  bridgeProviderAbi,
  bridgeSpenderFactoryAbi,
  cardFactoryAbi,
  cardSpenderAbi,
  deployBridgeCardsScriptAbi,
} from '../../abis/index.js'
import type { EarnDeploymentProfile } from '../../core/profile.js'
import { releaseAddress } from '../../core/release.js'
import { releasedContract } from '../../core/releases.js'
import {
  defineAuthorityStep,
  defineFoundryStep,
  deployedOutputs,
  deployerAuthority,
  requiredOutput,
  type CapabilityModule,
  type ChainClient,
  type StepAuthority,
} from '../module.js'
import { releaseCreationCode } from '../zone-router/releases.js'
import { canonicalBridgeClone, configuredCards } from './profile.js'

/** Bridge's role holders on its `SpenderFactory`; no key for either is ever configured here. */
export const bridgeAuthority = {
  id: 'bridge-spender-factory',
  label: "Bridge SpenderFactory admin and governance (Bridge's multisigs)",
  signer: 'BRIDGE_SPENDER_FACTORY_ROLES',
} as const satisfies StepAuthority

/** The "TS" handler prefix the program spends through. */
const tempoSpendPrefix = stringToHex('TS', { size: 2 })

const hasCards = (profile: EarnDeploymentProfile) => profile.cards !== null
const cardOutputs = ['cardRouterFactory', 'cardFactory', 'cardProvider', 'cardProgram'] as const
const programDeployed = getAbiItem({ abi: cardFactoryAbi, name: 'ProgramDeployed' })
const maxLogBlockRange = 100_000n
const cardsScript = 'script/spend/bridge/lifecycle/DeployBridgeCards.s.sol:DeployBridgeCardsScript'
const bridgeProviderContract = 'src/spend/providers/bridge/BridgeProvider.sol:BridgeProvider'

/** `BridgeProvider(factory, spenderId)`'s constructor arguments. */
const bridgeProviderArgs = (spenderFactory: Address, spenderId: Hex) =>
  encodeAbiParameters(parseAbiParameters('address, bytes32'), [spenderFactory, spenderId])

/**
 * The shared contracts a card program uses, which `pnpm release` deploys and profiles never create:
 * the released `CardFactory` and the `ZoneRouterFactory` it binds, and the "TS" handler, all from the
 * network's registry entry; and the address a program's own `BridgeProvider` is created at.
 */
export const cardReleases = {
  cardFactory: (chainId: number) => ({
    routerFactory: releasedContract(chainId, 'zoneRouterFactory'),
    cardFactory: releasedContract(chainId, 'cardFactory'),
  }),
  tempoSpend: (chainId: number) => releasedContract(chainId, 'tempoSpend'),
  /** A program's `BridgeProvider`, created at its release address like the release contracts. */
  bridgeProvider(
    spenderFactory: Address,
    spenderId: Hex,
    compile: (contract: string) => Hex = releaseCreationCode,
  ) {
    return releaseAddress(
      concatHex([compile(bridgeProviderContract), bridgeProviderArgs(spenderFactory, spenderId)]),
    )
  },
}

/**
 * The card capability's lifecycle hooks: before any key is used, the network's released
 * `CardFactory` and "TS" handler are in the registry and hold code, so no card contract is broadcast
 * for a program the deploy cannot finish or hand off.
 */
export const cardsModule: CapabilityModule = {
  async preflight(client, profile, outputs = {}) {
    // A recorded program needs neither release again, so verify and deposit never depend on them.
    if (!profile.cards || outputs.cardProgram) return
    const { cardFactory } = cardReleases.cardFactory(profile.chainId)
    const code = await client.getCode({ address: cardFactory })
    if (!code || code === '0x')
      throw new Error(`Released CardFactory ${cardFactory} has no code; run pnpm release first`)
    // enable-card-program hands the program to Bridge through this handler.
    await requireHandlerCode(client, cardReleases.tempoSpend(profile.chainId))
  },
}

/**
 * Deploys the profile's `BridgeProvider` at its release address, reusing it when it exists, as Bridge's
 * own scripts do. Its address commits to its creation code and constructor arguments, so it is
 * source verified without a creation transaction.
 */
export const deployCardProvider = defineFoundryStep({
  id: 'deploy-card-provider',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: "Deploy the card program's BridgeProvider at its release address.",
  phase: 'deployment',
  intent: ['cards'],
  script: cardsScript,
  enabled: hasCards,
  input: (profile, _outputs, outputPath) => {
    const { spenderFactory, spenderId } = configuredCards(profile)
    return encodeFunctionData({
      abi: deployBridgeCardsScriptAbi,
      functionName: 'provider',
      args: [{ expectedChainId: BigInt(profile.chainId), spenderFactory, spenderId, outputPath }],
    })
  },
  source: {
    output: 'cardProvider',
    contract: bridgeProviderContract,
    constructorArgs: (profile) => {
      const { spenderFactory, spenderId } = configuredCards(profile)
      return bridgeProviderArgs(spenderFactory, spenderId)
    },
    release: true,
  },
  async satisfied(client, profile, outputs) {
    if (!(await deployedOutputs(client, outputs, ['cardProvider']))) return false
    const { spenderFactory, spenderId } = configuredCards(profile)
    const provider = requiredOutput(outputs, 'cardProvider')
    // The release address is the provider's creation evidence, so a provider anywhere else is not it.
    if (getAddress(provider) !== cardReleases.bridgeProvider(spenderFactory, spenderId))
      return false
    const bridge = { address: provider, abi: bridgeProviderAbi }
    try {
      const [factory, id, clone] = await Promise.all([
        client.readContract({ ...bridge, functionName: 'FACTORY' }),
        client.readContract({ ...bridge, functionName: 'SPENDER_ID' }),
        client.readContract({ ...bridge, functionName: 'CLONE' }),
      ])
      return (
        getAddress(factory) === getAddress(spenderFactory) &&
        id.toLowerCase() === spenderId.toLowerCase() &&
        getAddress(clone) === getAddress(canonicalBridgeClone(spenderFactory, spenderId))
      )
    } catch {
      // A contract that does not answer as a provider is not this program's.
      return false
    }
  },
})

/**
 * Deploys the profile's card program: its `CardSpender` through the released `CardFactory`, over the
 * program's `BridgeProvider`, reusing it when it exists, as Bridge's own scripts do.
 */
export const deployCardProgram = defineFoundryStep({
  id: 'deploy-card-program',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: "Deploy the card program's CardSpender through the released CardFactory.",
  phase: 'deployment',
  intent: ['cards'],
  script: cardsScript,
  enabled: hasCards,
  input: (profile, _outputs, outputPath) => {
    const { spenderFactory, spenderId } = configuredCards(profile)
    return encodeFunctionData({
      abi: deployBridgeCardsScriptAbi,
      functionName: 'run',
      args: [
        {
          expectedChainId: BigInt(profile.chainId),
          cardFactory: cardReleases.cardFactory(profile.chainId).cardFactory,
          spenderFactory,
          spenderId,
          outputPath,
        },
      ],
    })
  },
  // The released CardFactory source-verifies with its release, before any program trusts its event.
  creationEvent: (_profile, outputs) => ({
    address: requiredOutput(outputs, 'cardFactory'),
    event: programDeployed,
    argument: 'program',
    output: 'cardProgram',
    source: { contract: 'src/spend/CardFactory.sol:CardFactory' },
  }),
  source: {
    output: 'cardProgram',
    contract: 'src/spend/CardSpender.sol:CardSpender',
    // A program spending Earn positions moves EarnShare and the vault asset through its Bridge clone.
    accessMember: {
      abi: cardSpenderAbi,
      principals: {
        PAYOUT_TARGET: (profile) => {
          const { spenderFactory, spenderId } = configuredCards(profile)
          return canonicalBridgeClone(spenderFactory, spenderId)
        },
      },
    },
    constructorArgs: (_profile, outputs) =>
      encodeAbiParameters(parseAbiParameters('address, address'), [
        requiredOutput(outputs, 'cardProvider'),
        requiredOutput(outputs, 'cardRouterFactory'),
      ]),
    // A program is never replaced for a new build: cardholder keys and routers point at its address, so
    // a new program is a deliberate change of spenderId or provider.
  },
  async satisfied(client, profile, outputs) {
    if (!(await deployedOutputs(client, outputs, cardOutputs))) return false
    return cardProgramBound(client, profile, outputs)
  },
  // Bridge deploying the same program with its own scripts lands on the same address; the
  // CardFactory's ProgramDeployed event then names its creation.
  adopt: (client, profile, outputs) => adoptCardProgram(client, profile, outputs),
})

/**
 * Bridge's admin registers this checkout's release "TS" handler and governance lets it serve the
 * program. Both hold roles on Bridge's factory, so this step only verifies and hands off.
 */
export const enableCardProgram = defineAuthorityStep({
  id: 'enable-card-program',
  authority: bridgeAuthority,
  execution: 'authority',
  summary: 'Register the release "TS" handler on the SpenderFactory and let it serve the program.',
  handoffSummary:
    'Verify the program can spend through the release "TS" handler, and emit a Bridge handoff if not.',
  phase: 'activation',
  intent: ['cards'],
  enabled: hasCards,
  signerAvailable: () => false,
  satisfied: async (client, profile) => {
    const { spenderFactory, spenderId } = configuredCards(profile)
    const handler = cardReleases.tempoSpend(profile.chainId)
    await requireHandlerCode(client, handler)
    return cardProgramEnabled(client, { factory: spenderFactory, handler, spenderId })
  },
  handoff: (profile, outputs) =>
    cardProgramHandoff({
      ...configuredCards(profile),
      handler: cardReleases.tempoSpend(profile.chainId),
      program: requiredOutput(outputs, 'cardProgram'),
    }),
  execute: () => Promise.resolve(undefined),
})

/**
 * Whether the recorded program is the released `CardFactory`'s program for the profile's Bridge
 * program, paying through its clone and taking spends only from that factory's router factory.
 */
export async function cardProgramBound(
  client: Pick<ChainClient, 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  const { spenderFactory, spenderId } = configuredCards(profile)
  const [routerFactory, cardFactory, provider, program] = cardOutputs.map((key) =>
    requiredOutput(outputs, key),
  ) as [Address, Address, Address, Address]
  const same = (left: Address, right: Address) => getAddress(left) === getAddress(right)
  try {
    const factory = { address: cardFactory, abi: cardFactoryAbi } as const
    const spender = { address: program, abi: cardSpenderAbi } as const
    const bridge = { address: provider, abi: bridgeProviderAbi } as const
    const [deployed, predicted, factoryRouters, programProvider, programRouters, payoutTarget] =
      await Promise.all([
        client.readContract({ ...factory, functionName: 'isDeployed', args: [program] }),
        client.readContract({ ...factory, functionName: 'predict', args: [spenderId, provider] }),
        client.readContract({ ...factory, functionName: 'ROUTER_FACTORY' }),
        client.readContract({ ...spender, functionName: 'PROVIDER' }),
        client.readContract({ ...spender, functionName: 'ROUTER_FACTORY' }),
        client.readContract({ ...spender, functionName: 'PAYOUT_TARGET' }),
      ])
    const [providerFactory, providerSpenderId, clone, factoryClone] = await Promise.all([
      client.readContract({ ...bridge, functionName: 'FACTORY' }),
      client.readContract({ ...bridge, functionName: 'SPENDER_ID' }),
      client.readContract({ ...bridge, functionName: 'CLONE' }),
      client.readContract({
        address: spenderFactory,
        abi: bridgeSpenderFactoryAbi,
        functionName: 'getSpenderAddress',
        args: [spenderId],
      }),
    ])
    return (
      deployed &&
      same(predicted, program) &&
      same(factoryRouters, routerFactory) &&
      same(programRouters, routerFactory) &&
      same(programProvider, provider) &&
      same(providerFactory, spenderFactory) &&
      providerSpenderId.toLowerCase() === spenderId.toLowerCase() &&
      same(clone, factoryClone) &&
      // Bridge can register an ID against an existing clone, which the "TS" handler rejects.
      same(clone, canonicalBridgeClone(spenderFactory, spenderId)) &&
      same(payoutTarget, clone)
    )
  } catch {
    // A contract that does not answer as a program, provider or factory is not this program.
    return false
  }
}

/**
 * The program another deployer already created through the released `CardFactory`, such as Bridge
 * with its own scripts, with the transaction its `ProgramDeployed` event names.
 */
export async function adoptCardProgram(
  client: Pick<ChainClient, 'getBlockNumber' | 'getCode' | 'getLogs' | 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
  releases: Pick<typeof cardReleases, 'cardFactory' | 'bridgeProvider'> = cardReleases,
) {
  const { spenderFactory, spenderId } = configuredCards(profile)
  const recorded = cardOutputs.every((key) => outputs[key])
  const { routerFactory, cardFactory } = recorded
    ? { routerFactory: outputs.cardRouterFactory!, cardFactory: outputs.cardFactory! }
    : releases.cardFactory(profile.chainId)
  const provider = outputs.cardProvider ?? releases.bridgeProvider(spenderFactory, spenderId)
  const code = await client.getCode({ address: cardFactory })
  if (!code || code === '0x') return undefined
  const contract = { address: cardFactory, abi: cardFactoryAbi } as const
  const program = await client.readContract({
    ...contract,
    functionName: 'predict',
    args: [spenderId, provider],
  })
  if (!(await client.readContract({ ...contract, functionName: 'isDeployed', args: [program] })))
    return undefined
  for (
    let toBlock = await client.getBlockNumber({ cacheTime: 0 });
    toBlock >= 0n;
    toBlock -= maxLogBlockRange
  ) {
    const fromBlock = toBlock >= maxLogBlockRange ? toBlock - maxLogBlockRange + 1n : 0n
    const [log] = await client.getLogs({
      address: cardFactory,
      event: programDeployed,
      args: { program },
      fromBlock,
      toBlock,
    })
    if (log)
      return {
        outputs: {
          ...outputs,
          cardRouterFactory: getAddress(routerFactory),
          cardFactory: getAddress(cardFactory),
          cardProvider: getAddress(provider),
          cardProgram: getAddress(program),
        },
        transaction: log.transactionHash,
      }
    if (fromBlock === 0n) break
  }
  throw new Error(
    `CardFactory ${cardFactory} lists program ${program}, but no ProgramDeployed event names it`,
  )
}

/**
 * The program `deploy-card-program` creates or adopts for the profile, with the released
 * `ZoneRouterFactory` it takes spends from; `undefined` without a program. A released `CardFactory`
 * the network's registry lacks, or that has no code, fails: profiles never create it.
 */
export async function profileCardProgram(
  client: Pick<ChainClient, 'getCode' | 'readContract'>,
  profile: Pick<EarnDeploymentProfile, 'cards' | 'chainId'>,
  releases: Pick<typeof cardReleases, 'cardFactory' | 'bridgeProvider'> = cardReleases,
) {
  if (!profile.cards) return undefined
  const { spenderFactory, spenderId } = profile.cards
  const { routerFactory, cardFactory } = releases.cardFactory(profile.chainId)
  const code = await client.getCode({ address: cardFactory })
  if (!code || code === '0x')
    throw new Error(`Released CardFactory ${cardFactory} has no code; run pnpm release first`)
  const program = await client.readContract({
    address: cardFactory,
    abi: cardFactoryAbi,
    functionName: 'predict',
    args: [spenderId, releases.bridgeProvider(spenderFactory, spenderId)],
  })
  return { program: getAddress(program), routerFactory: getAddress(routerFactory) }
}

/** Refuses a released "TS" handler with no code, which Bridge must never be handed. */
export async function requireHandlerCode(client: Pick<ChainClient, 'getCode'>, handler: Address) {
  const code = await client.getCode({ address: handler })
  if (!code || code === '0x')
    throw new Error(
      `Released "TS" handler ${handler} has no code; run pnpm release <network> first`,
    )
}

/**
 * Whether Bridge's factory runs `handler` as its "TS" handler and lets it serve the program's
 * clone: enabled for every program, or gated with the clone allowlisted.
 */
export async function cardProgramEnabled(
  client: Pick<ChainClient, 'readContract'>,
  options: { factory: Address; handler: Address; spenderId: Hex },
) {
  const contract = { address: options.factory, abi: bridgeSpenderFactoryAbi } as const
  const clone = await client.readContract({
    ...contract,
    functionName: 'getSpenderAddress',
    args: [options.spenderId],
  })
  // One read: the factory refuses a disabled handler and a gated one for a clone it has not
  // allowlisted, and otherwise returns the handler it runs for "TS".
  return client
    .readContract({
      ...contract,
      functionName: 'getSpenderHandlerWithCheckedPermissions',
      args: [tempoSpendPrefix, clone],
    })
    .then(
      (served) => getAddress(served) === getAddress(options.handler),
      () => false,
    )
}

/** The calls Bridge's role holders submit, in order, with their calldata. */
export function cardProgramHandoff(options: {
  spenderFactory: Address
  spenderId: Hex
  handler: Address
  program: Address
}) {
  const call = (functionName: string, args: readonly unknown[]) =>
    encodeFunctionData({ abi: bridgeSpenderFactoryAbi, functionName, args } as never)
  const register = call('setSpenderHandler', [tempoSpendPrefix, options.handler])
  // SpenderStatus: Disabled 0, Enabled 1, Gated 2.
  const gate = call('updateSpenderHandlerStatus', [tempoSpendPrefix, 2])
  const allowlist = call('updateSpenderHandlerAllowlist', [
    tempoSpendPrefix,
    options.spenderId,
    true,
  ])
  return [
    `Card program ${options.program} spends through the "TS" handler ${options.handler} of SpenderFactory ${options.spenderFactory}, which Bridge must register and open to the program. Submit to ${options.spenderFactory}, in order, each only if still needed:`,
    `1. Admin (timelock), unless "TS" already runs this handler: setSpenderHandler("TS", ${options.handler}), calldata ${register}.`,
    `2. Governance, only for a first registration while "TS" is Disabled: updateSpenderHandlerStatus("TS", Gated), calldata ${gate}. A replacement keeps the prefix's status.`,
    `3. Governance, while "TS" is Gated: updateSpenderHandlerAllowlist("TS", ${options.spenderId}, true), calldata ${allowlist}.`,
    'Allowing an Earn vault for the program (governorCall with "TS" "UV") follows docs/spend/bridge/deploy.md. Re-run the same pnpm earn deploy command; it will verify the handler and the program onchain and continue.',
  ].join('\n')
}
