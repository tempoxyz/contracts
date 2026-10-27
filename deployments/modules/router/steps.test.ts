import { decodeFunctionData, getAddress, zeroAddress, zeroHash, type Address } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { Addresses } from 'viem/tempo'
import { describe, expect, test, vi } from 'vitest'

import { deployZoneRouterScriptAbi, propAMMPoolAbi, zonePortalAbi } from '../../abis/index.js'
import { planEarnDeployment } from '../../core/plan.js'
import { parseEarnDeploymentProfile } from '../../core/profile.js'
import { accessMembers } from '../earn/access-policy/membership.js'
import { accessMemberContracts, deploymentStep, executeAvailableAuthority } from '../index.js'
import type { ChainClient, FoundryStep } from '../module.js'
import { zoneRouterModeModule } from './index.js'
import { zoneRouterConstructorArgs, zoneRouterMode } from './profile.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as Address
const customerId = `0x${'c'.repeat(64)}` as const
const authorityKey = `0x${'3'.repeat(64)}` as const
const authorityAccount = privateKeyToAccount(authorityKey).address
const receiptHash = `0x${'a'.repeat(64)}` as const

const earnBinding = { privateAsset: address('a'), pool: address('b'), customerId }
const settler = address('5e771e')

function profileWith(zoneRouter: unknown, extra: Record<string, unknown> = {}) {
  return parseEarnDeploymentProfile(
    {
      version: 1,
      id: 'zone-router-steps',
      chainId: 42431,
      engine: { kind: 'erc4626', venue: address('2') },
      zoneRouter,
      ...extra,
    },
    { deployer: address('3'), factories: { earn: address('4'), erc4626Engine: address('1') } },
  )
}

const cardAndEarn = profileWith({
  zoneId: 7,
  ops: ['deposit', 'redeem', 'spend'],
  earn: earnBinding,
  settlers: [settler],
})
const card = profileWith({
  zoneId: 7,
  ops: ['spend'],
  settlers: [settler],
  factory: address('fac'),
})

const outputs = {
  asset: address('a55e7'),
  earnShare: address('5ba4e'),
  earnVault: address('e'),
  zoneRouterFactory: address('f'),
  zoneRouter: address('9'),
  zoneRouterPortal: address('8'),
}

const routerSteps = (profile: typeof card) =>
  planEarnDeployment(profile)
    .map((action) => action.id)
    .filter((id) => id.includes('zone-router'))

/**
 * A chain where `outputs.zoneRouter` is the factory's router for `mode`; `overrides` replace single
 * reads by function name.
 */
function chain(profile: typeof card, overrides: Record<string, unknown> = {}) {
  const mode = zoneRouterMode(profile, outputs)
  const factory = profile.zoneRouter?.factory ?? outputs.zoneRouterFactory
  const reads: Record<string, unknown> = {
    isRouter: true,
    predict: outputs.zoneRouter,
    enabledOps: mode.enabledOps,
    settlers: mode.settlers,
    allowedZoneId: mode.zoneId,
    earnVault: mode.earnVault,
    privateAsset: mode.privateAsset,
    vaultAsset: mode.earnVault === zeroAddress ? zeroAddress : outputs.asset,
    earnShare: mode.earnVault === zeroAddress ? zeroAddress : outputs.earnShare,
    pool: mode.pool,
    customerId: mode.customerId,
    privateAssetIsBase: mode.pool !== zeroAddress,
    baseToken: mode.privateAsset,
    quoteToken: outputs.asset,
    ...overrides,
  }
  const readContract = vi.fn(
    async ({ address: target, functionName }: { address: Address; functionName: string }) => {
      // The factory answers isRouter and predict; everything else is the router or its pool.
      if (functionName === 'isRouter' && target !== factory) throw new Error('not a factory')
      return reads[functionName]
    },
  )
  return {
    getCode: vi.fn(async () => '0x6080' as const),
    readContract,
  } as unknown as ChainClient
}

describe('Zone router steps', () => {
  test('plans the factory, router, and only the activation its mode needs', () => {
    expect(routerSteps(cardAndEarn)).toEqual([
      'deploy-zone-router-factory',
      'deploy-zone-router',
      'authorize-zone-router',
      'enable-zone-router-tokens',
      'register-zone-router-gateway',
      'admit-zone-router-account',
    ])
    // A named factory is used as is; Spend needs no pool admission or Earn tokens.
    expect(routerSteps(card)).toEqual([
      'deploy-zone-router',
      'register-zone-router-gateway',
      'admit-zone-router-account',
    ])
    expect(
      routerSteps(
        profileWith({ zoneId: 7, ops: ['deposit'], earn: { privateAsset: address('a') } }),
      ),
    ).toEqual([
      'deploy-zone-router-factory',
      'deploy-zone-router',
      'enable-zone-router-tokens',
      'register-zone-router-gateway',
      'admit-zone-router-account',
    ])
    expect(routerSteps(profileWith(undefined))).toEqual([])
  })

  test('runs its Forge steps in the router project and deploys the mode through the factory', () => {
    const step = deploymentStep('deploy-zone-router') as FoundryStep
    expect(step.project).toBe('router')
    expect(deploymentStep('deploy-zone-router-factory')).toMatchObject({ project: 'router' })
    const input = decodeFunctionData({
      abi: deployZoneRouterScriptAbi,
      data: step.input(card, outputs, '/tmp/out.json'),
    })
    expect(input.args[0]).toEqual({
      expectedChainId: 42431n,
      factory: address('fac'),
      mode: zoneRouterMode(card, outputs),
      outputPath: '/tmp/out.json',
    })
    expect(step.source?.constructorArgs(card, outputs)).toBe(
      zoneRouterConstructorArgs(zoneRouterMode(card, outputs)),
    )
  })

  test('is satisfied only by the factory router bound exactly to the profile mode', async () => {
    const step = deploymentStep('deploy-zone-router')
    for (const profile of [card, cardAndEarn]) {
      await expect(step.satisfied(chain(profile), profile, outputs)).resolves.toBe(true)
    }
    const { zoneRouter: _router, ...missing } = outputs
    await expect(step.satisfied(chain(card), card, missing)).resolves.toBe(false)
    for (const override of [
      { isRouter: false },
      { predict: address('99') },
      { enabledOps: 5 },
      { settlers: [address('5e772e')] },
      { allowedZoneId: 8 },
      { earnVault: outputs.earnVault },
    ]) {
      await expect(step.satisfied(chain(card, override), card, outputs)).resolves.toBe(false)
    }
    for (const override of [
      { customerId: zeroHash },
      { pool: address('bb') },
      { earnShare: address('5') },
    ]) {
      await expect(
        step.satisfied(chain(cardAndEarn, override), cardAndEarn, outputs),
      ).resolves.toBe(false)
    }
  })

  test('accepts a deployed factory only when it answers as one', async () => {
    const step = deploymentStep('deploy-zone-router-factory')
    await expect(
      step.satisfied(chain(cardAndEarn, { isRouter: false }), cardAndEarn, outputs),
    ).resolves.toBe(true)
    await expect(
      step.satisfied(chain(cardAndEarn), cardAndEarn, {
        ...outputs,
        zoneRouterFactory: address('1'),
      }),
    ).resolves.toBe(false)
  })

  test('whitelists the router on a protected EarnShare', () => {
    expect(accessMemberContracts.map(({ output }) => output)).toContain('zoneRouter')
    const members = accessMembers(
      profileWith(
        { zoneId: 7, ops: ['deposit', 'redeem'], earn: earnBinding },
        { tip403PolicyId: '469' },
      ),
      outputs,
    )
    expect(members).toContain(outputs.zoneRouter)
  })

  test('whitelists the Zone principals that move EarnShare without a zone section', () => {
    const messenger = address('3e55')
    const sequencer = address('5e9')
    const members = accessMembers(
      profileWith(
        { zoneId: 7, ops: ['deposit', 'redeem'], earn: earnBinding },
        { tip403PolicyId: '469' },
      ),
      { ...outputs, zoneRouterMessenger: messenger, zoneRouterSequencer0: sequencer },
    )
    expect(members).toEqual(
      expect.arrayContaining([
        outputs.zoneRouterPortal,
        messenger,
        sequencer,
        getAddress(Addresses.zoneOutbox),
      ]),
    )
    expect(zoneRouterModeModule.metadataOutput?.('zoneRouterSequencer0')).toBe(true)
    expect(zoneRouterModeModule.metadataOutput?.('zoneRouterPortal')).toBe(false)
  })

  test('adopts the router another deployer created for the same mode', async () => {
    const step = deploymentStep('deploy-zone-router') as FoundryStep
    const creation = `0x${'d'.repeat(64)}` as const
    const getLogs = vi.fn(async () => [{ transactionHash: creation }])
    const client = {
      ...chain(card),
      getBlockNumber: vi.fn(async () => 10n),
      getLogs,
    } as unknown as ChainClient
    const { zoneRouter: _, ...unrecorded } = outputs
    expect(await step.adopt!(client, card, unrecorded)).toEqual({
      outputs: { ...unrecorded, zoneRouter: outputs.zoneRouter },
      transaction: creation,
    })
    expect(getLogs).toHaveBeenCalledWith(
      expect.objectContaining({ address: address('fac'), args: { router: outputs.zoneRouter } }),
    )
    // Nothing to adopt before the factory deployed the mode.
    expect(await step.adopt!(chain(card, { isRouter: false }), card, unrecorded)).toBeUndefined()
  })

  test('hands gateway admission to the Zone administrator with the provenance to check', () => {
    const step = deploymentStep('register-zone-router-gateway')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    const handoff = step.handoff(card, outputs)
    expect(handoff).toContain(`ZoneRouterFactory ${address('fac')}.isRouter(${outputs.zoneRouter})`)
    expect(handoff).toContain(
      `setGateway(${outputs.zoneRouter}, true) on ${outputs.zoneRouterPortal}`,
    )
    expect(handoff).toContain(
      `${address('fac')} is source verified as router/src/ZoneRouterFactory.sol`,
    )
  })

  test('never admits a router from a factory the profile names, even with the admin key', async () => {
    const step = deploymentStep('register-zone-router-gateway')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    const environment = { ZONE_ADMIN_PRIVATE_KEY: authorityKey }
    expect(step.signerAvailable!(card, environment, true)).toBe(false)
    expect(step.signerAvailable!(cardAndEarn, environment, true)).toBe(true)
    const authorityClient = vi.fn()
    const result = await executeAvailableAuthority(
      {
        action: { id: 'register-zone-router-gateway' },
        environment,
        outputs,
        profile: card,
        rpcUrl: 'https://rpc.invalid',
      },
      { authorityClient: authorityClient as never, fundFromFaucet: vi.fn() as never },
    )
    expect(result).toBeUndefined()
    expect(authorityClient).not.toHaveBeenCalled()
  })

  test.each([
    { name: 'an open gateway', gatewayOpen: true, registered: false, sends: false },
    { name: 'a registered router', gatewayOpen: false, registered: true, sends: false },
    { name: 'an unregistered router', gatewayOpen: false, registered: false, sends: true },
  ])('registers the router on its own Zone only for $name', async (scenario) => {
    const readContract = vi
      .fn()
      .mockResolvedValueOnce(authorityAccount)
      .mockResolvedValueOnce(scenario.gatewayOpen)
      .mockResolvedValueOnce(scenario.registered)
    const sendTransactionSync = vi.fn().mockResolvedValue({ transactionHash: receiptHash })
    const result = await executeAvailableAuthority(
      {
        action: { id: 'register-zone-router-gateway' },
        environment: { ZONE_ADMIN_PRIVATE_KEY: authorityKey },
        outputs,
        profile: cardAndEarn,
        rpcUrl: 'https://rpc.invalid',
      },
      {
        authorityClient: ((_options: unknown, account: unknown) => ({
          account,
          chain: {},
          readContract,
          sendTransactionSync,
        })) as never,
        fundFromFaucet: vi.fn() as never,
      },
    )
    expect(readContract.mock.calls[0]![0]).toMatchObject({
      address: outputs.zoneRouterPortal,
      functionName: 'admin',
    })
    if (!scenario.sends) {
      expect(result).toEqual({ transactions: [] })
      expect(sendTransactionSync).not.toHaveBeenCalled()
      return
    }
    expect(result).toEqual({ transactions: [receiptHash] })
    const [call] = sendTransactionSync.mock.calls[0]![0].calls as Array<{
      to: Address
      data: `0x${string}`
    }>
    expect(call!.to).toBe(outputs.zoneRouterPortal)
    expect(decodeFunctionData({ abi: zonePortalAbi, data: call!.data })).toMatchObject({
      functionName: 'setGateway',
      args: [outputs.zoneRouter, true],
    })
  })

  test('leaves pool admission of a router from a factory the profile names to a person', async () => {
    const named = profileWith({
      zoneId: 7,
      ops: ['deposit', 'redeem', 'spend'],
      earn: earnBinding,
      settlers: [settler],
      factory: address('fac'),
    })
    const step = deploymentStep('authorize-zone-router')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    const environment = { DEPLOYER_PRIVATE_KEY: `0x${'4'.repeat(64)}` }
    expect(step.signerAvailable!(named, environment, true)).toBe(false)
    expect(step.signerAvailable!(cardAndEarn, environment, true)).toBe(true)
    expect(step.handoff(named, outputs)).toContain(
      `ZoneRouterFactory ${address('fac')} is source verified as router/src/ZoneRouterFactory.sol`,
    )
    expect(step.handoff(cardAndEarn, outputs)).not.toContain('source verified')
    const authorityClient = vi.fn()
    const result = await executeAvailableAuthority(
      {
        action: { id: 'authorize-zone-router' },
        environment,
        outputs,
        profile: named,
        rpcUrl: 'https://rpc.invalid',
      },
      { authorityClient: authorityClient as never, fundFromFaucet: vi.fn() as never },
    )
    expect(result).toBeUndefined()
    expect(authorityClient).not.toHaveBeenCalled()
  })

  test.each([
    { name: 'an open Portal', access: false, gatewayOpen: true, admitted: false, sends: false },
    {
      name: 'restricted gateways',
      access: true,
      gatewayOpen: false,
      admitted: false,
      sends: false,
    },
    { name: 'an admitted router', access: true, gatewayOpen: true, admitted: true, sends: false },
    { name: 'an unadmitted router', access: true, gatewayOpen: true, admitted: false, sends: true },
  ])('admits the router as an account only for $name', async (scenario) => {
    const reads: Record<string, unknown> = {
      admin: authorityAccount,
      isAccessEnforced: scenario.access,
      isGatewayOpen: scenario.gatewayOpen,
      hasRole: scenario.admitted,
    }
    const readContract = vi.fn(
      async ({ functionName }: { functionName: string }) => reads[functionName],
    )
    const sendTransactionSync = vi.fn().mockResolvedValue({ transactionHash: receiptHash })
    const result = await executeAvailableAuthority(
      {
        action: { id: 'admit-zone-router-account' },
        environment: { ZONE_ADMIN_PRIVATE_KEY: authorityKey },
        outputs,
        profile: cardAndEarn,
        rpcUrl: 'https://rpc.invalid',
      },
      {
        authorityClient: ((_options: unknown, account: unknown) => ({
          account,
          chain: {},
          readContract,
          sendTransactionSync,
        })) as never,
        fundFromFaucet: vi.fn() as never,
      },
    )
    if (!scenario.sends) {
      expect(result).toEqual({ transactions: [] })
      expect(sendTransactionSync).not.toHaveBeenCalled()
      return
    }
    expect(result).toEqual({ transactions: [receiptHash] })
    const [call] = sendTransactionSync.mock.calls[0]![0].calls as Array<{
      to: Address
      data: `0x${string}`
    }>
    expect(call!.to).toBe(outputs.zoneRouterPortal)
    expect(decodeFunctionData({ abi: zonePortalAbi, data: call!.data })).toMatchObject({
      functionName: 'setAllowedAccount',
      args: [outputs.zoneRouter, true],
    })
  })

  test('hands account admission of a router from a named factory to the Zone administrator', () => {
    const step = deploymentStep('admit-zone-router-account')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    const environment = { ZONE_ADMIN_PRIVATE_KEY: authorityKey }
    expect(step.signerAvailable!(card, environment, true)).toBe(false)
    expect(step.signerAvailable!(cardAndEarn, environment, true)).toBe(true)
    const handoff = step.handoff(card, outputs)
    expect(handoff).toContain('is source verified as router/src/ZoneRouterFactory.sol')
    expect(handoff).toContain(
      `setAllowedAccount(${outputs.zoneRouter}, true) on ${outputs.zoneRouterPortal}`,
    )
  })

  test.each([
    {
      name: 'opened gateways move a registered gateway to an account',
      action: 'admit-zone-router-account',
      gatewayOpen: true,
      held: 3,
      calls: [
        ['setGateway', false],
        ['setAllowedAccount', true],
      ],
    },
    {
      name: 'restricted gateways move an admitted account to a gateway',
      action: 'register-zone-router-gateway',
      gatewayOpen: false,
      held: 2,
      calls: [
        ['setAllowedAccount', false],
        ['setGateway', true],
      ],
    },
  ])('$name in one batch', async (scenario) => {
    const readContract = vi.fn(
      async ({ functionName, args }: { functionName: string; args?: readonly unknown[] }) => {
        if (functionName === 'admin') return authorityAccount
        if (functionName === 'isAccessEnforced') return true
        if (functionName === 'isGatewayOpen') return scenario.gatewayOpen
        if (functionName === 'hasRole') return args?.[1] === scenario.held
        return undefined
      },
    )
    const sendTransactionSync = vi.fn().mockResolvedValue({ transactionHash: receiptHash })
    const result = await executeAvailableAuthority(
      {
        action: { id: scenario.action as 'admit-zone-router-account' },
        environment: { ZONE_ADMIN_PRIVATE_KEY: authorityKey },
        outputs,
        profile: cardAndEarn,
        rpcUrl: 'https://rpc.invalid',
      },
      {
        authorityClient: ((_options: unknown, account: unknown) => ({
          account,
          chain: {},
          readContract,
          sendTransactionSync,
        })) as never,
        fundFromFaucet: vi.fn() as never,
      },
    )
    expect(result).toEqual({ transactions: [receiptHash] })
    expect(sendTransactionSync).toHaveBeenCalledTimes(1)
    const calls = sendTransactionSync.mock.calls[0]![0].calls as Array<{
      to: Address
      data: `0x${string}`
    }>
    expect(
      calls.map((call) => {
        const decoded = decodeFunctionData({ abi: zonePortalAbi, data: call.data })
        expect(call.to).toBe(outputs.zoneRouterPortal)
        expect(decoded.args?.[0]).toBe(outputs.zoneRouter)
        return [decoded.functionName, decoded.args?.[1]]
      }),
    ).toEqual(scenario.calls)
  })

  test('admits the router on its conversion pool as the pool owner', async () => {
    const deployerKey = `0x${'4'.repeat(64)}` as const
    const deployer = privateKeyToAccount(deployerKey).address
    // Pool owner, then taker, recipient, and resolved recipient.
    const readContract = vi
      .fn()
      .mockResolvedValueOnce(deployer)
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true)
      .mockResolvedValueOnce(outputs.zoneRouter)
    const sendTransactionSync = vi.fn().mockResolvedValue({ transactionHash: receiptHash })
    const result = await executeAvailableAuthority(
      {
        action: { id: 'authorize-zone-router' },
        environment: { DEPLOYER_PRIVATE_KEY: deployerKey },
        outputs,
        profile: cardAndEarn,
        rpcUrl: 'https://rpc.invalid',
      },
      {
        authorityClient: ((_options: unknown, account: unknown) => ({
          account,
          chain: {},
          readContract,
          sendTransactionSync,
        })) as never,
        fundFromFaucet: vi.fn() as never,
      },
    )
    expect(result).toEqual({ transactions: [receiptHash] })
    const calls = sendTransactionSync.mock.calls[0]![0].calls as Array<{
      to: Address
      data: `0x${string}`
    }>
    expect(calls).toHaveLength(1)
    expect(calls[0]!.to).toBe(earnBinding.pool)
    expect(decodeFunctionData({ abi: propAMMPoolAbi, data: calls[0]!.data })).toMatchObject({
      functionName: 'setTakerAllowed',
      args: [outputs.zoneRouter, true],
    })
  })
})

describe('Zone router inspection', () => {
  test('reports gateway, token, and conversion readiness without failing', async () => {
    const reads = chain(cardAndEarn, {
      isGatewayOpen: false,
      hasRole: false,
      isTokenEnabled: true,
      areDepositsActive: true,
      liquidityStatus: [false, true, true, 1n, 2n],
      oracle: address('0c'),
      maxOracleAge: 60n,
      latestPrice: [1n, 100n],
    })
    // The oracle report is 10 seconds old, within the pool's 60-second maximum.
    const client = { ...reads, getBlock: async () => ({ timestamp: 110n }) }
    const report = await zoneRouterModeModule.inspect!(client, cardAndEarn, outputs)
    expect(report?.zoneRouter).toMatchObject({
      status: 'blocked',
      blockers: ['Zone 7 has not registered the router as a callback gateway'],
    })
    expect(report?.zoneRouterConversion).toMatchObject({
      status: 'ready',
      details: { depositInventory: '1', redeemInventory: '2' },
    })
  })

  test('fails on a router the factory did not deploy for the profile mode', async () => {
    await expect(
      zoneRouterModeModule.inspect!(chain(card, { predict: address('99') }), card, outputs),
    ).rejects.toThrow('router for the profile mode')
  })
})
