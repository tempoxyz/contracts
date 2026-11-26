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
import { activationActions, deploymentActions, presentEarnDeploymentPlan } from '../../core/plan.js'
import { parseEarnDeploymentProfile } from '../../core/profile.js'
import { accessMemberContracts, deploymentSteps } from '../index.js'
import {
  adoptCardProgram,
  cardProgramBound,
  cardProgramEnabled,
  cardProgramHandoff,
  deployCardProgram,
  enableCardProgram,
  profileCardProgram,
} from './steps.js'

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
const clone = address('c1'),
  handler = address('75')

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
    expect(deploymentActions(profile).map(({ id }) => id)).toContain('deploy-card-program')
    expect(activationActions(profile).map(({ id }) => id)).toContain('enable-card-program')
    const plan = presentEarnDeploymentPlan(profile, {
      DEPLOYER_PRIVATE_KEY: `0x${'1'.repeat(64)}`,
      BRIDGE_SPENDER_FACTORY_ROLES: 'set',
    })
    expect(plan.find(({ id }) => id === 'enable-card-program')).toMatchObject({
      authority: 'bridge-spender-factory',
      execution: 'handoff',
    })
    expect(plan.find(({ id }) => id === 'deploy-card-program')?.execution).toBe('foundry')
    const without = { ...profile, cards: null }
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

describe('deploy-card-program', () => {
  test("calls the script's typed run with the profile's program", () => {
    expect(
      decodeFunctionData({
        abi: deployBridgeCardsScriptAbi,
        data: deployCardProgram.input(profile, {}, '/out.json'),
      }),
    ).toEqual({
      functionName: 'run',
      args: [{ expectedChainId: 4217n, spenderFactory, spenderId, outputPath: '/out.json' }],
    })
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
      accessMember: true,
    })
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

  test('has none without a program or a release CardFactory', async () => {
    const client = { ...chain(), getCode: vi.fn(async () => '0x' as Hex) }
    await expect(profileCardProgram(client as never, profile, releases)).resolves.toBeUndefined()
    await expect(
      profileCardProgram(client as never, { cards: null }, releases),
    ).resolves.toBeUndefined()
  })

  test('deploys before the Zone router that may list it as a spender', () => {
    const ids = deploymentSteps.map(({ id }) => id)
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
      if (functionName === 'getSpenderHandler') return registered
      if (functionName === 'getSpenderAddress') return clone
      if (permitted) return handler
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
})
