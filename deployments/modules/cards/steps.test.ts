import {
  decodeFunctionData,
  encodeAbiParameters,
  getAbiItem,
  getAddress,
  parseAbiParameters,
  stringToHex,
  type Address,
  type Hex,
} from 'viem'
import { describe, expect, test, vi } from 'vitest'

import {
  bridgeSpenderFactoryAbi,
  cardFactoryAbi,
  deployBridgeCardsScriptAbi,
} from '../../abis/index.js'
import type { SingletonReleaseKey } from '../../core/releases.js'
import { activationActions, deploymentActions, presentEarnDeploymentPlan } from '../../core/plan.js'
import { parseEarnDeploymentProfile } from '../../core/profile.js'
import { accessMemberContracts, deploymentSteps } from '../index.js'
import type { AccessMember } from '../module.js'
import {
  adoptCardProgram,
  cardProgramBound,
  cardProgramEnabled,
  cardProgramHandoff,
  cardReleases,
  cardsModule,
  deployCardProgram,
  deployCardProvider,
  enableCardProgram,
  profileCardProgram,
  requireHandlerCode,
} from './steps.js'

/**
 * The registry entry the tests release on mainnet, filled in once the fixtures exist; moderato
 * releases nothing, whatever the committed registry holds.
 */
const registry = vi.hoisted(() => ({}) as Partial<Record<SingletonReleaseKey, `0x${string}`>>)
vi.mock(import('../../core/releases.js'), async (original) => {
  const actual = await original()
  return {
    ...actual,
    releasedContract: vi.fn((chainId: number, key: SingletonReleaseKey) => {
      if (chainId === 42431) throw actual.missingRelease(chainId, key)
      // Mainnet releases only what the test registry holds, whatever releases.ts records.
      if (chainId !== 4217) return actual.releasedContract(chainId, key)
      const released = registry[key]
      if (!released) throw actual.missingRelease(chainId, key)
      return released
    }),
  }
})

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as Address
const spenderId = `0x${'5'.repeat(64)}` as Hex
const spenderFactory = address('bf')
const tx = `0x${'a'.repeat(64)}` as Hex
const profile = {
  ...parseEarnDeploymentProfile(
    {
      version: 1,
      id: 'cards-steps',
      chainId: 4217,
      engine: { kind: 'erc4626', venue: address('2') },
    },
    { deployer: address('3'), factories: { earn: address('4'), erc4626Engine: address('1') } },
  ),
  cards: { provider: 'bridge' as const, spenderFactory, spenderId },
}
const outputs = {
  cardRouterFactory: address('f0'),
  cardFactory: address('cf'),
  cardProvider: address('b0'),
  cardProgram: address('c0'),
}
// The forge-checked Solady prediction for this factory and spender ID.
const clone = getAddress('0xcff1550C6f04F082aEBA19bB1b085B1D4f0bf639'),
  handler = address('75')
Object.assign(registry, {
  zoneRouterFactory: outputs.cardRouterFactory,
  cardFactory: outputs.cardFactory,
  tempoSpend: handler,
})

/** A program, provider, CardFactory and Bridge factory that agree, with one answer overridable. */
function chain(overrides: Record<string, unknown> = {}) {
  const answers: Record<string, unknown> = {
    isDeployed: true,
    predict: outputs.cardProgram,
    'cf:ROUTER_FACTORY': outputs.cardRouterFactory,
    'c0:ROUTER_FACTORY': outputs.cardRouterFactory,
    PROVIDER: outputs.cardProvider,
    PAYOUT_TARGET: clone,
    FACTORY: spenderFactory,
    SPENDER_ID: spenderId,
    CLONE: clone,
    getSpenderAddress: clone,
    ...overrides,
  }
  return {
    readContract: vi.fn(
      async ({ address: target, functionName }: { address: Address; functionName: string }) => {
        const key = `${target.slice(-2).toLowerCase()}:${functionName}`
        const answer = key in answers ? answers[key] : answers[functionName]
        if (answer instanceof Error) throw answer
        return answer
      },
    ),
  }
}

describe('card program plan', () => {
  test('deploys the program, then hands every Bridge call off', () => {
    const deployments = deploymentActions(profile).map(({ id }) => id)
    // The provider exists before the CardFactory creates the program over it.
    expect(deployments).toContain('deploy-card-provider')
    expect(deployments.indexOf('deploy-card-provider')).toBeLessThan(
      deployments.indexOf('deploy-card-program'),
    )
    expect(activationActions(profile).map(({ id }) => id)).toContain('enable-card-program')
    const plan = presentEarnDeploymentPlan(profile, {
      DEPLOYER_PRIVATE_KEY: `0x${'1'.repeat(64)}`,
      BRIDGE_SPENDER_FACTORY_ROLES: 'set',
    })
    expect(plan.find(({ id }) => id === 'enable-card-program')).toMatchObject({
      authority: 'bridge-spender-factory',
      execution: 'handoff',
    })
    expect(plan.find(({ id }) => id === 'deploy-card-provider')?.execution).toBe('foundry')
    expect(plan.find(({ id }) => id === 'deploy-card-program')?.execution).toBe('foundry')
    const without = { ...profile, cards: null }
    expect(deploymentActions(without).map(({ id }) => id)).not.toContain('deploy-card-provider')
    expect(deploymentActions(without).map(({ id }) => id)).not.toContain('deploy-card-program')
    expect(activationActions(without).map(({ id }) => id)).not.toContain('enable-card-program')
  })

  test("never executes Bridge's roles", async () => {
    expect(
      enableCardProgram.signerAvailable?.(profile, { BRIDGE_SPENDER_FACTORY_ROLES: 'x' }, true),
    ).toBe(false)
    await expect(enableCardProgram.execute({} as never, {} as never)).resolves.toBeUndefined()
  })
})

describe('cards preflight', () => {
  test('refuses a profile before any broadcast when the released CardFactory or TS handler is missing', async () => {
    const getCode = vi.fn(async () => '0x' as const)
    await expect(cardsModule.preflight!({ getCode } as never, profile)).rejects.toThrow(
      `Released CardFactory ${outputs.cardFactory} has no code; run pnpm release first`,
    )
    await expect(
      cardsModule.preflight!({ getCode } as never, { ...profile, chainId: 42431 }),
    ).rejects.toThrow('No zoneRouterFactory release on moderato')
    await expect(
      cardsModule.preflight!({ getCode: vi.fn(async () => '0x60') } as never, profile),
    ).resolves.toBeUndefined()
    await expect(
      cardsModule.preflight!({ getCode } as never, { ...profile, cards: null }),
    ).resolves.toBeUndefined()
    // A CardFactory without a released handler stops too, before the provider and program deploy.
    const factoryOnly = vi.fn(async ({ address }: { address: Address }) =>
      address === outputs.cardFactory ? ('0x60' as const) : ('0x' as const),
    )
    await expect(
      cardsModule.preflight!({ getCode: factoryOnly } as never, profile),
    ).rejects.toThrow(
      `Released "TS" handler ${handler} has no code; run pnpm release <network> first`,
    )
    // A recorded program is checked by verify, not by these releases.
    await expect(
      cardsModule.preflight!({ getCode } as never, profile, outputs),
    ).resolves.toBeUndefined()
    const withoutHandler = registry.tempoSpend
    delete registry.tempoSpend
    try {
      await expect(
        cardsModule.preflight!({ getCode: vi.fn(async () => '0x60') } as never, profile),
      ).rejects.toThrow('No tempoSpend release on mainnet')
    } finally {
      registry.tempoSpend = withoutHandler
    }
  })
})

describe('deploy-card-provider', () => {
  const providerChain = (overrides: Record<string, unknown> = {}, code: Hex = '0x60') => ({
    ...chain(overrides),
    getCode: vi.fn(async () => code),
  })
  // The provider's release address, without compiling it.
  const release = (at: Address = outputs.cardProvider) =>
    vi.spyOn(cardReleases, 'bridgeProvider').mockReturnValue(at)

  test("calls the script's typed provider with the profile's program", () => {
    expect(
      decodeFunctionData({
        abi: deployBridgeCardsScriptAbi,
        data: deployCardProvider.input(profile, {}, '/out.json'),
      }),
    ).toEqual({
      functionName: 'provider',
      args: [{ expectedChainId: 4217n, spenderFactory, spenderId, outputPath: '/out.json' }],
    })
  })

  test('verifies the BridgeProvider source at its release address, without a creation transaction', () => {
    expect(deployCardProvider.intent).toEqual(['cards'])
    expect(deployCardProvider.creationEvent).toBeUndefined()
    expect(deployCardProvider.source).toMatchObject({
      output: 'cardProvider',
      contract: 'src/spend/providers/bridge/BridgeProvider.sol:BridgeProvider',
      release: true,
    })
    expect(deployCardProvider.source!.constructorArgs(profile, {})).toBe(
      encodeAbiParameters(parseAbiParameters('address, bytes32'), [spenderFactory, spenderId]),
    )
  })

  test.each([
    ['agrees', {}, '0x60', true],
    ['has no code', {}, '0x', false],
    ['binds another SpenderFactory', { FACTORY: address('96') }, '0x60', false],
    ['binds another program ID', { SPENDER_ID: `0x${'6'.repeat(64)}` }, '0x60', false],
    ['pays through another clone', { CLONE: address('95') }, '0x60', false],
    ['does not answer', { CLONE: new Error('reverted') }, '0x60', false],
  ] as const)('is satisfied only when the recorded provider %s', async (_, overrides, code, ok) => {
    const predicted = release()
    await expect(
      deployCardProvider.satisfied(providerChain(overrides, code) as never, profile, outputs),
    ).resolves.toBe(ok)
    if (code !== '0x') expect(predicted).toHaveBeenCalledWith(spenderFactory, spenderId)
    predicted.mockRestore()
  })

  test('is unsatisfied by a provider away from its release address', async () => {
    const predicted = release(address('99'))
    await expect(
      deployCardProvider.satisfied(providerChain() as never, profile, outputs),
    ).resolves.toBe(false)
    predicted.mockRestore()
  })

  test('is unsatisfied before a provider is recorded', async () => {
    const { cardProvider: _, ...unrecorded } = outputs
    await expect(
      deployCardProvider.satisfied(providerChain() as never, profile, unrecorded),
    ).resolves.toBe(false)
  })
})

describe('deploy-card-program', () => {
  test("calls the script's typed run with the profile's program and the released CardFactory", () => {
    expect(
      decodeFunctionData({
        abi: deployBridgeCardsScriptAbi,
        data: deployCardProgram.input(profile, {}, '/out.json'),
      }),
    ).toEqual({
      functionName: 'run',
      args: [
        {
          expectedChainId: 4217n,
          cardFactory: outputs.cardFactory,
          spenderFactory,
          spenderId,
          outputPath: '/out.json',
        },
      ],
    })
  })

  test('refuses to plan a program on a network without a released CardFactory', () => {
    expect(() => deployCardProgram.input({ ...profile, chainId: 42431 }, {}, '/out.json')).toThrow(
      'No zoneRouterFactory release on moderato; run pnpm release moderato and record its registry entry first',
    )
  })

  test('proves creation by the CardFactory event and verifies the CardSpender source', () => {
    expect(deployCardProgram.creationEvent!(profile, outputs)).toEqual({
      address: outputs.cardFactory,
      event: getAbiItem({ abi: cardFactoryAbi, name: 'ProgramDeployed' }),
      argument: 'program',
      output: 'cardProgram',
      source: { contract: 'src/spend/CardFactory.sol:CardFactory' },
    })
    expect(deployCardProgram.source).toMatchObject({
      output: 'cardProgram',
      contract: 'src/spend/CardSpender.sol:CardSpender',
    })
    const member = deployCardProgram.source!.accessMember as Exclude<AccessMember, true>
    expect(Object.keys(member.principals)).toEqual(['PAYOUT_TARGET'])
    expect(member.principals.PAYOUT_TARGET!(profile)).toBe(clone)
    expect(deployCardProgram.source!.constructorArgs(profile, outputs)).toBe(
      encodeAbiParameters(parseAbiParameters('address, address'), [
        outputs.cardProvider,
        outputs.cardRouterFactory,
      ]),
    )
    expect(deployCardProgram.source!.replaceOnCodeChange).toBeUndefined()
    expect(accessMemberContracts.map(({ output }) => output)).toContain('cardProgram')
  })

  test.each([
    ['agrees', {}, true],
    ['is not the CardFactory program', { isDeployed: false }, false],
    ['is another program ID', { predict: address('99') }, false],
    ['takes spends from another router factory', { 'c0:ROUTER_FACTORY': address('98') }, false],
    ['pays through another provider', { PROVIDER: address('97') }, false],
    ['binds another SpenderFactory', { FACTORY: address('96') }, false],
    ['binds another program ID', { SPENDER_ID: `0x${'6'.repeat(64)}` }, false],
    ['pays through a stale clone', { getSpenderAddress: address('95') }, false],
    [
      'pays through a clone the ID was added to',
      { getSpenderAddress: address('95'), CLONE: address('95'), PAYOUT_TARGET: address('95') },
      false,
    ],
    ['does not answer', { PAYOUT_TARGET: new Error('reverted') }, false],
  ])('is bound only when the recorded program %s', async (_, overrides, bound) => {
    expect(await cardProgramBound(chain(overrides) as never, profile, outputs)).toBe(bound)
  })
})

describe('profileCardProgram', () => {
  const releases = {
    cardFactory: () => ({
      routerFactory: outputs.cardRouterFactory,
      cardFactory: outputs.cardFactory,
    }),
    bridgeProvider: () => outputs.cardProvider,
  }

  test('predicts the program the profile deploys, with the release router factory', async () => {
    const client = { ...chain(), getCode: vi.fn(async () => '0x60' as Hex) }
    await expect(profileCardProgram(client as never, profile, releases)).resolves.toEqual({
      program: outputs.cardProgram,
      routerFactory: outputs.cardRouterFactory,
    })
  })

  test('has none without a program', async () => {
    const client = { ...chain(), getCode: vi.fn(async () => '0x60' as Hex) }
    await expect(
      profileCardProgram(client as never, { cards: null, chainId: 4217 }, releases),
    ).resolves.toBeUndefined()
  })

  test('fails when the released CardFactory has no code', async () => {
    const client = { ...chain(), getCode: vi.fn(async () => '0x' as Hex) }
    await expect(profileCardProgram(client as never, profile, releases)).rejects.toThrow(
      `Released CardFactory ${outputs.cardFactory} has no code; run pnpm release first`,
    )
  })

  test('reads the released CardFactory and router factory from the registry by default', async () => {
    const client = { ...chain(), getCode: vi.fn(async () => '0x60' as Hex) }
    await expect(
      profileCardProgram(client as never, profile, {
        cardFactory: cardReleases.cardFactory,
        bridgeProvider: () => outputs.cardProvider,
      }),
    ).resolves.toEqual({ program: outputs.cardProgram, routerFactory: outputs.cardRouterFactory })
    expect(client.getCode).toHaveBeenCalledWith({ address: outputs.cardFactory })
  })

  test('deploys before the Zone router that may list it as a spender', () => {
    const ids = deploymentSteps.map(({ id }) => id)
    expect(ids.indexOf('deploy-card-provider')).toBeLessThan(ids.indexOf('deploy-card-program'))
    expect(ids.indexOf('deploy-card-program')).toBeLessThan(ids.indexOf('deploy-zone-router'))
  })
})

describe('adoptCardProgram', () => {
  const releases = {
    cardFactory: () => ({
      routerFactory: outputs.cardRouterFactory,
      cardFactory: outputs.cardFactory,
    }),
    bridgeProvider: () => outputs.cardProvider,
  }
  const client = (deployed: boolean, code = '0x60') => ({
    ...chain({ isDeployed: deployed }),
    getCode: vi.fn(async () => code as Hex),
    getBlockNumber: vi.fn(async () => 150_000n),
    getLogs: vi.fn(async ({ fromBlock }: { fromBlock: bigint }) =>
      fromBlock === 0n ? [{ transactionHash: tx }] : [],
    ),
  })

  test('records a program another deployer created, with its ProgramDeployed transaction', async () => {
    const chainClient = client(true)
    await expect(adoptCardProgram(chainClient as never, profile, {}, releases)).resolves.toEqual({
      outputs,
      transaction: tx,
    })
    expect(chainClient.getLogs.mock.calls.map(([call]) => call)).toMatchObject([
      { address: outputs.cardFactory, args: { program: outputs.cardProgram }, fromBlock: 50_001n },
      { fromBlock: 0n, toBlock: 50_000n },
    ])
  })

  test('adopts nothing before the CardFactory exists or the program is deployed', async () => {
    await expect(
      adoptCardProgram(client(true, '0x') as never, profile, {}, releases),
    ).resolves.toBeUndefined()
    await expect(
      adoptCardProgram(client(false) as never, profile, {}, releases),
    ).resolves.toBeUndefined()
  })

  test('adopts over the recorded provider before the program is recorded', async () => {
    const bridgeProvider = vi.fn(() => address('99'))
    const {
      cardProgram: _,
      cardFactory: _factory,
      cardRouterFactory: _router,
      ...provided
    } = outputs
    const chainClient = client(true)
    await expect(
      adoptCardProgram(chainClient as never, profile, provided, {
        ...releases,
        bridgeProvider,
      }),
    ).resolves.toEqual({ outputs, transaction: tx })
    expect(bridgeProvider).not.toHaveBeenCalled()
    expect(chainClient.readContract).toHaveBeenCalledWith(
      expect.objectContaining({ functionName: 'predict', args: [spenderId, outputs.cardProvider] }),
    )
  })

  test('refuses a listed program without its creation event', async () => {
    const chainClient = { ...client(true), getLogs: vi.fn(async () => []) }
    await expect(
      adoptCardProgram(chainClient as never, profile, outputs, releases),
    ).rejects.toThrow('no ProgramDeployed event names it')
  })
})

describe('enable-card-program', () => {
  const factory = (registered: Address, permitted: boolean) => ({
    readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
      if (functionName === 'getSpenderAddress') return clone
      if (permitted) return registered
      throw new Error('SpenderHandlerNotAllowed')
    }),
  })

  test('needs the release handler registered and serving the clone', async () => {
    const options = { factory: spenderFactory, handler, spenderId }
    await expect(cardProgramEnabled(factory(handler, true) as never, options)).resolves.toBe(true)
    await expect(cardProgramEnabled(factory(address('76'), true) as never, options)).resolves.toBe(
      false,
    )
    await expect(cardProgramEnabled(factory(handler, false) as never, options)).resolves.toBe(false)
    const permitted = factory(handler, true)
    await cardProgramEnabled(permitted as never, options)
    expect(permitted.readContract.mock.calls.at(-1)![0]).toMatchObject({
      functionName: 'getSpenderHandlerWithCheckedPermissions',
      args: [stringToHex('TS', { size: 2 }), clone],
    })
  })

  test('refuses a release handler with no code', async () => {
    const client = (code: Hex) => ({ getCode: vi.fn(async () => code) })
    await expect(requireHandlerCode(client('0x'), handler)).rejects.toThrow(
      `Released "TS" handler ${handler} has no code; run pnpm release <network> first`,
    )
    await expect(requireHandlerCode(client('0x60'), handler)).resolves.toBeUndefined()
  })

  test('names each Bridge call with its submitter and calldata', () => {
    const text = cardProgramHandoff({
      spenderFactory,
      spenderId,
      handler,
      program: outputs.cardProgram,
    })
    const calls = [...text.matchAll(/calldata (0x[0-9a-f]+)/g)].map(([, data]) =>
      decodeFunctionData({ abi: bridgeSpenderFactoryAbi, data: data as Hex }),
    )
    const prefix = stringToHex('TS', { size: 2 })
    expect(calls).toEqual([
      { functionName: 'setSpenderHandler', args: [prefix, handler] },
      { functionName: 'updateSpenderHandlerStatus', args: [prefix, 2] },
      { functionName: 'updateSpenderHandlerAllowlist', args: [prefix, spenderId, true] },
    ])
    expect(text).toContain('Admin (timelock)')
    expect(text).toContain(`Card program ${outputs.cardProgram}`)
  })

  test('hands off the registry\'s released "TS" handler', () => {
    const calls = [
      ...enableCardProgram.handoff(profile, outputs).matchAll(/calldata (0x[0-9a-f]+)/g),
    ].map(([, data]) => decodeFunctionData({ abi: bridgeSpenderFactoryAbi, data: data as Hex }))
    expect(calls[0]).toEqual({
      functionName: 'setSpenderHandler',
      args: [stringToHex('TS', { size: 2 }), handler],
    })
  })
})
