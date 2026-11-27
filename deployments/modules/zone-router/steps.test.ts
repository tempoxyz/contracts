import {
  CallExecutionError,
  ContractFunctionZeroDataError,
  decodeFunctionData,
  erc20Abi,
  ExecutionRevertedError,
  getAddress,
  HttpRequestError,
  LimitExceededRpcError,
  toEventSelector,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { Addresses } from 'viem/tempo'
import { describe, expect, test, vi } from 'vitest'

import {
  deployZoneRouterScriptAbi,
  propAMMPoolAbi,
  zonePortalAbi,
  zoneRouterAbi,
} from '../../abis/index.js'
import { planEarnDeployment } from '../../core/plan.js'
import { parseEarnDeploymentProfile } from '../../core/profile.js'
import { zoneFactoryAddress, zoneMessengerAddress } from '../../chain/zone.js'
import { accessMembers } from '../earn/access-policy/membership.js'
import { accessMemberContracts, deploymentStep, executeAvailableAuthority } from '../index.js'
import type { ChainClient, FoundryStep } from '../module.js'
import { requireRouterProvenance } from '../earn/zone-router/provenance.js'
import { zoneRouterModeModule } from './index.js'
import { zoneRouterConstructorArgs, zoneRouterFactory, zoneRouterMode } from './profile.js'
import { zoneRouterSeedPlan } from './seeds.js'

vi.mock(import('../earn/zone-router/provenance.js'), () => ({ requireRouterProvenance: vi.fn() }))
/** The ZoneRouterFactory the mocked registry records on moderato; other chains keep the real entry. */
const releasedFactory = vi.hoisted(() => '0x0000000000000000000000000000000000000fac' as const)
vi.mock(import('../../core/releases.js'), async (original) => {
  const actual = await original()
  return {
    ...actual,
    releasedContract: vi.fn((chainId, key) =>
      chainId === 42431 && key === 'zoneRouterFactory'
        ? releasedFactory
        : actual.releasedContract(chainId, key),
    ),
  }
})
// The release SendSpender for a customer id ending in an address is at that address, so tests choose
// which listed spenders are releases without building the contracts.
vi.mock(import('./releases.js'), async () => {
  const { getAddress } = await import('viem')
  return {
    spenderReleases: {
      cardFactory: () => getAddress(`0x${'cafac'.padStart(40, '0')}`),
      sendSpender: ({ customerId }) => getAddress(`0x${customerId.slice(-40)}`),
    },
  }
})

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as Address
const customerId = `0x${'c'.repeat(64)}` as const
const authorityKey = `0x${'3'.repeat(64)}` as const
const authorityAccount = privateKeyToAccount(authorityKey).address
const receiptHash = `0x${'a'.repeat(64)}` as const

const earnBinding = { privateAsset: address('a'), pool: address('b'), customerId }
const spender = address('5e771e')

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
    {
      // The seed tests' deployer key, so the seed step accepts it as the profile's deployer.
      deployer: privateKeyToAccount(`0x${'4'.repeat(64)}`).address,
      factories: { earn: address('4'), erc4626Engine: address('1') },
    },
  )
}

const cardAndEarn = profileWith({
  zoneId: 7,
  ops: ['deposit', 'redeem', 'spend'],
  earn: earnBinding,
  spenders: [spender],
})
const card = profileWith({ zoneId: 7, ops: ['spend'], spenders: [spender] })

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
 * A chain where `outputs.zoneRouter` is `factory`'s router for `mode`; `overrides` replace single
 * reads by function name.
 */
function chain(
  profile: typeof card,
  overrides: Record<string, unknown> = {},
  factory: Address = outputs.zoneRouterFactory,
) {
  const mode = zoneRouterMode(profile, outputs)
  const reads: Record<string, unknown> = {
    isRouter: true,
    predict: outputs.zoneRouter,
    portal: outputs.zoneRouterPortal,
    enabledOps: mode.enabledOps,
    spenders: mode.spenders,
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
    call: vi.fn(async () => ({ data: '0x' })),
    getCode: vi.fn(async () => '0x6080' as const),
    getStorageAt: vi.fn(async () => zeroHash),
    readContract,
  } as unknown as ChainClient
}

describe('Zone router steps', () => {
  test('plans the router and only the activation its mode needs', () => {
    expect(routerSteps(cardAndEarn)).toEqual([
      'deploy-zone-router',
      'authorize-zone-router',
      'enable-zone-router-tokens',
      'register-zone-router-gateway',
      'admit-zone-router-account',
      'seed-zone-router',
    ])
    // Spend needs no pool admission or Earn tokens.
    expect(routerSteps(card)).toEqual([
      'deploy-zone-router',
      'register-zone-router-gateway',
      'admit-zone-router-account',
      'seed-zone-router',
    ])
    expect(
      routerSteps(
        profileWith({ zoneId: 7, ops: ['deposit'], earn: { privateAsset: address('a') } }),
      ),
    ).toEqual([
      'deploy-zone-router',
      'enable-zone-router-tokens',
      'register-zone-router-gateway',
      'admit-zone-router-account',
      'seed-zone-router',
    ])
    expect(routerSteps(profileWith(undefined))).toEqual([])
  })

  test('deploys the mode through the recorded factory, else the released one', () => {
    const step = deploymentStep('deploy-zone-router') as FoundryStep
    const { zoneRouterFactory: _factory, zoneRouter: _router, ...fresh } = outputs
    for (const [recorded, factory] of [
      [outputs, outputs.zoneRouterFactory],
      [fresh, releasedFactory],
    ] as const) {
      const input = decodeFunctionData({
        abi: deployZoneRouterScriptAbi,
        data: step.input(card, recorded, '/tmp/out.json'),
      })
      expect(input.args[0]).toEqual({
        expectedChainId: 42431n,
        factory,
        mode: zoneRouterMode(card, recorded),
        outputPath: '/tmp/out.json',
      })
      // The released factory is admitted as an existing source-verified contract.
      expect(step.creationEvent!(card, recorded)).toMatchObject({
        address: factory,
        output: 'zoneRouter',
        source: { contract: 'src/zone/ZoneRouterFactory.sol:ZoneRouterFactory' },
      })
    }
    expect(step.intent).toEqual(['zoneRouter'])
    expect(step.source?.replaceOnCodeChange?.(card)).toBe(true)
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
      { spenders: [address('5e772e')] },
      { allowedZoneId: 8 },
      { portal: address('88') },
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

  test('whitelists the spenders when the Portal enables EarnShare', () => {
    const protectedEarn = profileWith(
      { zoneId: 7, ops: ['deposit', 'redeem', 'spend'], earn: earnBinding, spenders: [spender] },
      { tip403PolicyId: '469' },
    )
    expect(accessMembers(protectedEarn, outputs)).toContain(spender)
    // A Spend-only mode moves EarnShare only when another router has its Zone enable it.
    const protectedCard = profileWith(
      { zoneId: 7, ops: ['spend'], spenders: [spender] },
      { tip403PolicyId: '469' },
    )
    expect(accessMembers(protectedCard, outputs)).not.toContain(spender)
  })

  test('protects configured spenders before and after EarnShare enablement', async () => {
    const portal = address('8')
    const stack = {
      contracts: { earnShare: outputs.earnShare, zoneRouter: outputs.zoneRouter },
      operations: {},
    }
    const principals = (enabled: boolean, enabledOps = 7) =>
      zoneRouterModeModule.stackAccessPrincipals!(
        {
          readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
            const reads: Record<string, unknown> = {
              allowedZoneId: 7,
              enabledOps,
              spenders: [spender],
              zones: { zoneId: 7, portal, sequencers: [address('5e9')] },
              zoneFactory: zoneFactoryAddress,
              isTokenEnabled: enabled,
              zoneId: 7,
              messenger: zoneMessengerAddress,
              encryptionKeyCount: 1n,
              sequencerCount: 1n,
              sequencerAt: address('5e9'),
            }
            return reads[functionName]
          }),
        } as never,
        stack as never,
      )
    await expect(principals(true)).resolves.toContain(spender)
    await expect(principals(false)).resolves.toContain(spender)
    await expect(principals(false, 4)).resolves.not.toContain(spender)
    await expect(principals(true, 4)).resolves.toContain(spender)
  })

  test('adopts the router another deployer created for the same mode', async () => {
    const step = deploymentStep('deploy-zone-router') as FoundryStep
    const creation = `0x${'d'.repeat(64)}` as const
    const getLogs = vi.fn(async () => [{ transactionHash: creation }])
    const client = {
      ...chain(card, {}, releasedFactory),
      getBlockNumber: vi.fn(async () => 10n),
      getLogs,
    } as unknown as ChainClient
    // Neither the router nor the released factory it came from is recorded yet; adoption records both.
    const { zoneRouter: _, zoneRouterFactory: _factory, ...unrecorded } = outputs
    expect(await step.adopt!(client, card, unrecorded)).toEqual({
      outputs: {
        ...unrecorded,
        zoneRouterFactory: releasedFactory,
        zoneRouter: outputs.zoneRouter,
      },
      transaction: creation,
    })
    expect(client.getBlockNumber).toHaveBeenCalledWith({ cacheTime: 0 })
    expect(getLogs).toHaveBeenCalledWith(
      expect.objectContaining({ address: releasedFactory, args: { router: outputs.zoneRouter } }),
    )
    // Nothing to adopt before the factory deployed the mode.
    expect(
      await step.adopt!(chain(card, { isRouter: false }, releasedFactory), card, unrecorded),
    ).toBeUndefined()
  })

  test('hands gateway admission to the Zone administrator with the provenance to check', () => {
    const step = deploymentStep('register-zone-router-gateway')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    const handoff = step.handoff(card, outputs)
    expect(handoff).toContain(
      `confirm ZoneRouterFactory ${outputs.zoneRouterFactory}.isRouter(${outputs.zoneRouter})`,
    )
    expect(handoff).toContain(
      `setGateway(${outputs.zoneRouter}, true) on ${outputs.zoneRouterPortal}`,
    )
    // The released factory source-verifies with its release, so no handoff asks a person to check it.
    expect(handoff).not.toContain('source verified')
  })

  test('self-admits a router of any mode with the Zone admin key once authority is proven', () => {
    for (const id of ['register-zone-router-gateway', 'admit-zone-router-account'] as const) {
      const step = deploymentStep(id)
      if (step.execution !== 'authority') throw new Error('expected an authority step')
      const environment = { ZONE_ADMIN_PRIVATE_KEY: authorityKey }
      for (const profile of [card, cardAndEarn]) {
        expect(step.signerAvailable!(profile, environment, true)).toBe(true)
        expect(step.signerAvailable!(profile, environment, false)).toBe(false)
        expect(step.signerAvailable!(profile, {}, true)).toBe(false)
      }
    }
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
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
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
          chain: { id: 42431 },
          getTransactionCount: async () => 0,
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

  test('refuses a restored noncanonical factory before granting a gateway role', async () => {
    const error = new Error('noncanonical factory')
    vi.mocked(requireRouterProvenance).mockRejectedValueOnce(error)
    const sendTransactionSync = vi.fn()
    const runtime = {
      authorityClient: (() => ({
        account: privateKeyToAccount(authorityKey),
        chain: { id: 42431 },
        readContract: async ({ functionName }: { functionName: string }) =>
          functionName === 'admin' ? authorityAccount : false,
        sendTransactionSync,
      })) as never,
      fundFromFaucet: vi.fn() as never,
    }
    await expect(
      executeAvailableAuthority(
        {
          action: { id: 'register-zone-router-gateway' },
          environment: { ZONE_ADMIN_PRIVATE_KEY: authorityKey },
          outputs,
          profile: cardAndEarn,
          rpcUrl: 'https://rpc.invalid',
        },
        runtime,
      ),
    ).rejects.toBe(error)
    expect(sendTransactionSync).not.toHaveBeenCalled()
  })

  test('admits a router on its conversion pool with the deployer key once authority is proven', () => {
    const step = deploymentStep('authorize-zone-router')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    const environment = { DEPLOYER_PRIVATE_KEY: `0x${'4'.repeat(64)}` }
    expect(step.signerAvailable!(cardAndEarn, environment, true)).toBe(true)
    expect(step.signerAvailable!(cardAndEarn, environment, false)).toBe(false)
    const handoff = step.handoff(cardAndEarn, outputs)
    expect(handoff).toContain(
      `Confirm ZoneRouterFactory ${zoneRouterFactory(cardAndEarn, outputs)}.isRouter(${outputs.zoneRouter}) and the mode in its RouterDeployed event, and verify the router's canonical implementation`,
    )
    expect(handoff).not.toContain('source verified')
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
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
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
          chain: { id: 42431 },
          getTransactionCount: async () => 0,
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

  test('hands account admission to the Zone administrator with the provenance to check', () => {
    const step = deploymentStep('admit-zone-router-account')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    const handoff = step.handoff(card, outputs)
    expect(handoff).toContain(
      `confirm ZoneRouterFactory ${outputs.zoneRouterFactory}.isRouter(${outputs.zoneRouter})`,
    )
    expect(handoff).not.toContain('source verified')
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
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
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
          chain: { id: 42431 },
          getTransactionCount: async () => 0,
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
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
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
          chain: { id: 42431 },
          getTransactionCount: async () => 0,
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

  test('refuses a restored noncanonical factory or router before pool admission', async () => {
    const deployerKey = `0x${'4'.repeat(64)}` as const
    const deployer = privateKeyToAccount(deployerKey).address
    const error = new Error('noncanonical router')
    vi.mocked(requireRouterProvenance).mockRejectedValueOnce(error)
    // Pool owner, then taker, recipient, and resolved recipient.
    const readContract = vi
      .fn()
      .mockResolvedValueOnce(deployer)
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(outputs.zoneRouter)
    const sendTransactionSync = vi.fn()
    await expect(
      executeAvailableAuthority(
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
            chain: { id: 42431 },
            getTransactionCount: async () => 0,
            readContract,
            sendTransactionSync,
          })) as never,
          fundFromFaucet: vi.fn() as never,
        },
      ),
    ).rejects.toBe(error)
    expect(sendTransactionSync).not.toHaveBeenCalled()
  })
})

describe('Zone router preflight', () => {
  /**
   * A chain where every address but `empty` has code and each spender reports `routerFactory`.
   */
  const preflightChain = (routerFactory: unknown, empty?: Address) =>
    ({
      getCode: vi.fn(async ({ address }: { address: Address }) =>
        address === empty ? ('0x' as const) : ('0x6080' as const),
      ),
      readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
        if (functionName === 'isRouter') return false
        if (functionName === 'ROUTER_FACTORY' && routerFactory) return routerFactory
        throw new ContractFunctionZeroDataError({ functionName })
      }),
    }) as never

  test('accepts spenders bound to the released factory, or to the recorded one', async () => {
    await expect(
      zoneRouterModeModule.preflight!(preflightChain(releasedFactory), card),
    ).resolves.toBeUndefined()
    await expect(
      zoneRouterModeModule.preflight!(preflightChain(outputs.zoneRouterFactory), card, outputs),
    ).resolves.toBeUndefined()
  })

  test('refuses spenders whose routers would come from another factory', async () => {
    const other = address('bad0')
    await expect(zoneRouterModeModule.preflight!(preflightChain(other), card)).rejects.toThrow(
      `zoneRouter.spenders[0] ${spender} takes spendFrom only from routers of ZoneRouterFactory ${other}, not the router's ${releasedFactory}`,
    )
    await expect(zoneRouterModeModule.preflight!(preflightChain(undefined), card)).rejects.toThrow(
      'reports no ROUTER_FACTORY',
    )
  })

  test('requires the released factory to hold code and answer as one', async () => {
    await expect(
      zoneRouterModeModule.preflight!(preflightChain(releasedFactory, releasedFactory), card),
    ).rejects.toThrow(`No runtime code at ZoneRouterFactory ${releasedFactory}`)
    const client = preflightChain(releasedFactory)
    await zoneRouterModeModule.preflight!(client, card)
    expect((client as ChainClient).readContract).toHaveBeenCalledWith(
      expect.objectContaining({
        address: releasedFactory,
        functionName: 'isRouter',
        args: [zeroAddress],
      }),
    )
    const unreleased = profileWith(
      { zoneId: 7, ops: ['spend'], spenders: [spender] },
      { chainId: 4217 },
    )
    await expect(
      zoneRouterModeModule.preflight!(preflightChain(releasedFactory), unreleased),
    ).rejects.toThrow('No zoneRouterFactory release on mainnet; run pnpm release mainnet')
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
    const client = { ...reads, getBlock: async () => ({ number: 7n, timestamp: 110n }) }
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

  test('reports spenders a protected EarnShare does not admit and spenders of unknown provenance', async () => {
    const protectedEarn = profileWith(
      { zoneId: 7, ops: ['deposit', 'redeem', 'spend'], earn: earnBinding, spenders: [spender] },
      { tip403PolicyId: '469' },
    )
    const reads = chain(protectedEarn, {
      isGatewayOpen: false,
      hasRole: true,
      isTokenEnabled: true,
      areDepositsActive: true,
      liquidityStatus: [false, true, true, 1n, 2n],
      oracle: address('0c'),
      maxOracleAge: 60n,
      latestPrice: [1n, 100n],
      ROUTER_FACTORY: outputs.zoneRouterFactory,
      isAuthorized: false,
    })
    const client = { ...reads, getBlock: async () => ({ number: 7n, timestamp: 110n }) }
    const report = await zoneRouterModeModule.inspect!(client, protectedEarn, outputs)
    expect(report?.zoneRouterSpenders).toEqual({
      label: 'Zone router spenders',
      status: 'blocked',
      blockers: [
        `Spender ${spender} is neither a CardSpender nor a SendSpender`,
        `Spender ${spender} is not a member of EarnShare's TIP-403 policy 469, so EarnShare spends through it bounce`,
      ],
    })
  })

  test('fails on a router the factory did not deploy for the profile mode', async () => {
    await expect(
      zoneRouterModeModule.inspect!(chain(card, { predict: address('99') }), card, outputs),
    ).rejects.toThrow('router for the profile mode')
  })
})

describe('Zone router seeds', () => {
  const restartTopic = toEventSelector('UnbackedPoolRestarted(uint256,uint256)').slice(2)
  const implementation = address('1e')
  const deployerKey = `0x${'4'.repeat(64)}` as const
  const deployer = privateKeyToAccount(deployerKey).address
  const convertingSpender = address('5e772e')
  const straySpender = address('5ba7')
  const cardProgram = address('ca4d')
  const spendOnly = profileWith({ zoneId: 7, ops: ['spend'], spenders: [spender] })

  /**
   * The release SendSpender settings the mocked release prediction puts at `holder`: the customer id
   * carries its address.
   */
  const releaseSettings = (holder: Address, convertVault: Address) => ({
    ROUTER_FACTORY: outputs.zoneRouterFactory,
    convertVault,
    pool: address('9001'),
    customerId: `0x${holder.slice(2).toLowerCase().padStart(64, '0')}`,
  })

  /** Each listed spender's getters; a missing getter reverts as an absent function. */
  const spenders: Record<Address, Record<string, unknown>> = {
    [spender]: releaseSettings(spender, zeroAddress),
    [convertingSpender]: {
      ...releaseSettings(convertingSpender, outputs.earnVault),
      convertAsset: outputs.asset,
      parToken: address('ba'),
    },
    // Same getters as a converting SendSpender, but not the release for them.
    [straySpender]: {
      ...releaseSettings(straySpender, address('c0')),
      customerId,
      convertAsset: address('dead'),
      parToken: address('ba'),
    },
    [cardProgram]: { ROUTER_FACTORY: outputs.zoneRouterFactory, PROVIDER: address('9a0') },
  }

  /**
   * The given profile's chain plus token state: `balances` and `allowances` keyed by `token:holder`
   * (zero when absent), the Portal enabling `enabled`, a vault that restarts when `restarts`, and a
   * TIP-403 policy reverting every simulated call to a token in `refuse` (the router itself reverting
   * `warm` with OpDisabled when `perCallback`).
   */
  function seedChain(
    options: {
      allowances?: Record<string, bigint>
      balances?: Record<string, bigint>
      enabled?: Address[]
      perCallback?: boolean
      profile?: typeof card
      refuse?: Address[]
      restarts?: boolean
      strayCardProgram?: boolean
    } = {},
  ) {
    const profile = options.profile ?? cardAndEarn
    const base = chain(profile, { liquidityStatus: [false, true, true, 1n, 2n] }) as unknown as {
      readContract: (parameters: Record<string, unknown>) => Promise<unknown>
    }
    const enabled = options.enabled ?? [earnBinding.privateAsset, outputs.earnShare]
    // Set as sent batches land: their warm calls set every Portal allowance, and their transfers move
    // 1 base unit from the deployer to each recipient.
    const state = { balances: { ...options.balances }, warmed: false }
    const readContract = vi.fn(async (parameters: Record<string, unknown>) => {
      const target = parameters.address as Address
      const args = (parameters.args ?? []) as Address[]
      const functionName = parameters.functionName as string
      switch (functionName) {
        case 'balanceOf':
          return state.balances[`${target}:${args[0]}`] ?? 0n
        case 'allowance':
          return state.warmed ? 1n : (options.allowances?.[`${target}:${args[0]}`] ?? 0n)
        case 'isTokenEnabled':
          return enabled.includes(args[0]!)
        case 'isDeployed':
          return args[0] === cardProgram && !options.strayCardProgram
      }
      const contract = spenders[target]
      if (contract) {
        const value = contract[functionName]
        if (value === undefined) throw new ContractFunctionZeroDataError({ functionName })
        return value
      }
      return base.readContract(parameters)
    })
    return {
      call: vi.fn(async ({ to }: { to: Address }) => {
        if (options.perCallback && to === outputs.zoneRouter)
          throw new ExecutionRevertedError({ message: 'execution reverted: OpDisabled()' })
        if (options.refuse?.includes(to))
          throw new ExecutionRevertedError({ message: 'execution reverted: PolicyForbids' })
        return { data: '0x' }
      }),
      getCode: vi.fn(async ({ address: target }: { address: Address }) =>
        target === implementation && options.restarts ? `0x60${restartTopic}` : '0x6080',
      ),
      getStorageAt: vi.fn(async ({ address: target }: { address: Address }) =>
        target === outputs.earnVault
          ? (`0x${implementation.slice(2).toLowerCase().padStart(64, '0')}` as const)
          : zeroHash,
      ),
      readContract,
      state,
    }
  }

  /** Applies a landed batch to `reads`: every Portal allowance set and each transfer's unit moved. */
  const warmAll = (
    reads: ReturnType<typeof seedChain>,
    calls: { to: Address; data: Hex }[] = [],
  ) => {
    reads.state.warmed = true
    for (const call of calls) {
      if (call.to === outputs.zoneRouter) continue
      const [recipient, amount] = decodeFunctionData({ abi: erc20Abi, data: call.data }).args as [
        Address,
        bigint,
      ]
      const from = `${call.to}:${deployer}` as const
      reads.state.balances[from] = (reads.state.balances[from] ?? 0n) - amount
      const to = `${call.to}:${recipient}` as const
      reads.state.balances[to] = (reads.state.balances[to] ?? 0n) + amount
    }
  }

  /** Runs the seed step as the deployer against `reads`, recording each batch it sends. */
  const run = (
    reads: ReturnType<typeof seedChain>,
    profile: typeof card = cardAndEarn,
    sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash }),
  ) =>
    executeAvailableAuthority(
      {
        action: { id: 'seed-zone-router' },
        environment: { DEPLOYER_PRIVATE_KEY: deployerKey },
        outputs,
        profile,
        rpcUrl: 'https://rpc.invalid',
      },
      {
        authorityClient: ((_options: unknown, account: unknown) => ({
          ...reads,
          account,
          chain: { id: 42431 },
          getTransactionCount: async () => 0,
          // A landed batch sets the Portal allowances its warm calls name.
          sendTransactionSync: async (...parameters: unknown[]) => {
            const receipt = await sendTransactionSync(...parameters)
            warmAll(reads, (parameters[0] as { calls: { to: Address; data: Hex }[] }).calls)
            return receipt
          },
        })) as never,
        fundFromFaucet: vi.fn() as never,
      },
    )

  /** Each call of a sent batch, as `[token, recipient, amount]` or `['warm', token]`. */
  const sentCalls = (sendTransactionSync: ReturnType<typeof vi.fn>) =>
    (sendTransactionSync.mock.calls[0]![0].calls as { to: Address; data: Hex }[]).map((call) =>
      call.to === outputs.zoneRouter
        ? ['warm', ...decodeFunctionData({ abi: zoneRouterAbi, data: call.data }).args!]
        : [call.to, ...decodeFunctionData({ abi: erc20Abi, data: call.data }).args!],
    )

  const seed = (holder: Address, token: Address) => expect.objectContaining({ holder, token })
  const funded = (tokens: Address[]) =>
    Object.fromEntries(tokens.map((token) => [`${token}:${deployer}`, 5n]))

  test('seeds EarnShare only where the vault restarts unbacked pools', async () => {
    const restarted = await zoneRouterSeedPlan(
      seedChain({ restarts: true }) as never,
      cardAndEarn,
      outputs,
    )
    expect(restarted.seeds).toEqual([
      seed(outputs.zoneRouter, outputs.asset),
      seed(outputs.zoneRouter, earnBinding.privateAsset),
      seed(outputs.zoneRouter, outputs.earnShare),
      seed(spender, earnBinding.privateAsset),
      seed(spender, outputs.earnShare),
      seed(spender, outputs.asset),
    ])
    expect(restarted.warm.map((entry) => entry.token)).toEqual([
      outputs.earnShare,
      earnBinding.privateAsset,
    ])
    expect(restarted.notes).toEqual([])
    // A vault without the restart could never return its supply to zero past a held unit.
    const earlier = await zoneRouterSeedPlan(seedChain() as never, cardAndEarn, outputs)
    expect(earlier.seeds.some((entry) => entry.token === outputs.earnShare)).toBe(false)
    expect(earlier.warm.map((entry) => entry.token)).toContain(outputs.earnShare)
    expect(earlier.notes).toEqual([
      `EarnShare units withheld: EarnVault ${outputs.earnVault} does not restart unbacked pools, so nothing bound to it may hold EarnShare (its Portal allowance is still warmed)`,
    ])
  })

  test('asks the Portal about EarnShare for a Spend router the profile does not tie to Earn', async () => {
    // No Earn ops and no same-Zone single-Zone router: only the Portal says EarnShare is withdrawn.
    const plan = await zoneRouterSeedPlan(
      seedChain({ profile: spendOnly, enabled: [outputs.earnShare], restarts: true }) as never,
      spendOnly,
      outputs,
    )
    expect(plan.seeds).toEqual([
      seed(outputs.zoneRouter, outputs.earnShare),
      seed(spender, outputs.earnShare),
      seed(spender, outputs.asset),
    ])
    expect(plan.warm.map((entry) => entry.token)).toEqual([outputs.earnShare])

    // Bound to an earlier vault, the step still warms EarnShare but sends no unit of it.
    const reads = seedChain({
      profile: spendOnly,
      enabled: [outputs.earnShare],
      balances: funded([outputs.asset, outputs.earnShare]),
    })
    const step = deploymentStep('seed-zone-router')
    expect(await step.satisfied(reads as never, spendOnly, outputs)).toBe(false)
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
    await expect(run(reads, spendOnly, sendTransactionSync)).resolves.toEqual({
      transactions: [receiptHash],
    })
    expect(sentCalls(sendTransactionSync)).toEqual([
      [outputs.asset, spender, 1n],
      ['warm', outputs.earnShare],
    ])
  })

  test('seeds a converting SendSpender only with stack tokens and skips card programs', async () => {
    const converting = profileWith({
      zoneId: 7,
      ops: ['deposit', 'redeem', 'spend'],
      earn: earnBinding,
      spenders: [convertingSpender, cardProgram],
    })
    const plan = await zoneRouterSeedPlan(
      seedChain({
        profile: converting,
        enabled: [earnBinding.privateAsset, outputs.earnShare],
      }) as never,
      converting,
      outputs,
    )
    expect(plan.seeds).toEqual([
      seed(outputs.zoneRouter, outputs.asset),
      seed(outputs.zoneRouter, earnBinding.privateAsset),
      seed(convertingSpender, earnBinding.privateAsset),
      seed(convertingSpender, outputs.asset),
    ])
    expect(plan.unverified).toEqual([])
    // A card program the release CardFactory never deployed is still reported.
    const stray = await zoneRouterSeedPlan(
      seedChain({
        profile: converting,
        enabled: [earnBinding.privateAsset],
        strayCardProgram: true,
      }) as never,
      converting,
      outputs,
    )
    expect(stray.unverified).toEqual([
      `Spender ${cardProgram} is not a CardSpender the release CardFactory ${getAddress(`0x${'cafac'.padStart(40, '0')}`)} deployed`,
    ])
    expect(plan.notes).toContain(
      `SendSpender ${convertingSpender} parToken ${address('ba')} is not one of the profile's tokens, so it is not seeded: send it 1 base unit by hand if wanted`,
    )
  })

  test('sends nothing to a spender that is not the release SendSpender and stays incomplete', async () => {
    const stray = profileWith({ zoneId: 7, ops: ['spend'], spenders: [spender, straySpender] })
    const options = { profile: stray, enabled: [outputs.asset] }
    const plan = await zoneRouterSeedPlan(seedChain(options) as never, stray, outputs)
    expect(plan.seeds).toEqual([
      seed(outputs.zoneRouter, outputs.asset),
      seed(spender, outputs.asset),
    ])
    expect(plan.unverified).toEqual([
      `Spender ${straySpender} is not the release SendSpender for its settings, which is at ${getAddress(`0x${customerId.slice(-40)}`)}`,
    ])

    const step = deploymentStep('seed-zone-router')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
    const reads = seedChain({ ...options, balances: funded([outputs.asset, address('dead')]) })
    await expect(run(reads, stray, sendTransactionSync)).resolves.toEqual({
      transactions: [receiptHash],
    })
    // The verified holders are still seeded; the stray spender and the token it names get nothing.
    expect(sentCalls(sendTransactionSync)).toEqual([
      [outputs.asset, outputs.zoneRouter, 1n],
      [outputs.asset, spender, 1n],
      ['warm', outputs.asset],
    ])
    const seeded = seedChain({
      ...options,
      balances: {
        [`${outputs.asset}:${outputs.zoneRouter}`]: 1n,
        [`${outputs.asset}:${spender}`]: 1n,
      },
      allowances: { [`${outputs.asset}:${outputs.zoneRouter}`]: 1n },
    })
    // The stray spender is blocked by Zone router spenders, not by this step.
    expect(await step.satisfied(seeded as never, stray, outputs)).toBe(true)
  })

  test('notes each unseeded holder and unwarmed token without blocking routes', async () => {
    const client = {
      ...seedChain({
        balances: { [`${outputs.asset}:${outputs.zoneRouter}`]: 1n },
        allowances: { [`${outputs.earnShare}:${outputs.zoneRouter}`]: 2n ** 256n - 1n },
      }),
      getBlock: async () => ({ number: 7n, timestamp: 110n }),
    }
    const report = await zoneRouterModeModule.inspect!(client as never, cardAndEarn, outputs)
    expect(report?.zoneRouterSeeds).toEqual({
      label: 'Zone router seeds',
      status: 'ready',
      blockers: [],
      details: {
        missing: [
          `Zone router ${outputs.zoneRouter} holds no private asset ${earnBinding.privateAsset}, so each callback recreates its balance slot: send it 1 base unit`,
          `SendSpender ${spender} ${spender} holds no private asset ${earnBinding.privateAsset}, so each callback recreates its balance slot: send it 1 base unit`,
          `SendSpender ${spender} ${spender} holds no vault asset ${outputs.asset}, so each callback recreates its balance slot: send it 1 base unit`,
          `Zone router ${outputs.zoneRouter} has no Portal allowance for private asset ${earnBinding.privateAsset}, so its next return to the Zone sets one: call warm(${earnBinding.privateAsset})`,
        ].join('; '),
        withheld: `EarnShare units withheld: EarnVault ${outputs.earnVault} does not restart unbacked pools, so nothing bound to it may hold EarnShare (its Portal allowance is still warmed)`,
      },
    })
  })

  test('sends 1 base unit to each unseeded holder and warms each token once', async () => {
    const step = deploymentStep('seed-zone-router')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    const reads = seedChain({
      restarts: true,
      balances: {
        ...funded([outputs.asset, earnBinding.privateAsset, outputs.earnShare]),
        [`${outputs.asset}:${outputs.zoneRouter}`]: 1n,
      },
    })
    expect(await step.satisfied(reads as never, cardAndEarn, outputs)).toBe(false)
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
    await expect(run(reads, cardAndEarn, sendTransactionSync)).resolves.toEqual({
      transactions: [receiptHash],
    })
    expect(sentCalls(sendTransactionSync)).toEqual([
      [earnBinding.privateAsset, outputs.zoneRouter, 1n],
      [outputs.earnShare, outputs.zoneRouter, 1n],
      [earnBinding.privateAsset, spender, 1n],
      [outputs.earnShare, spender, 1n],
      [outputs.asset, spender, 1n],
      ['warm', outputs.earnShare],
      ['warm', earnBinding.privateAsset],
    ])
  })

  test('sends what a transfer policy allows and hands off the refused seeds', async () => {
    const reads = seedChain({
      restarts: true,
      refuse: [outputs.earnShare],
      balances: funded([outputs.asset, earnBinding.privateAsset, outputs.earnShare]),
    })
    const sendTransactionSync = vi.fn(async () => {
      warmAll(reads)
      return { status: 'success', transactionHash: receiptHash }
    })
    await expect(run(reads, cardAndEarn, sendTransactionSync)).resolves.toEqual({
      transactions: [receiptHash],
    })
    expect(sendTransactionSync).toHaveBeenCalledTimes(1)
    expect(sentCalls(sendTransactionSync)).toEqual([
      [outputs.asset, outputs.zoneRouter, 1n],
      [earnBinding.privateAsset, outputs.zoneRouter, 1n],
      [earnBinding.privateAsset, spender, 1n],
      [outputs.asset, spender, 1n],
      ['warm', outputs.earnShare],
      ['warm', earnBinding.privateAsset],
    ])

    // Every transfer refused and warm disabled on a per-callback router: nothing is sendable, so the
    // step completes without sending anything.
    const refusedAll = seedChain({
      restarts: true,
      perCallback: true,
      refuse: [outputs.asset, earnBinding.privateAsset, outputs.earnShare],
      balances: funded([outputs.asset, earnBinding.privateAsset, outputs.earnShare]),
    })
    const none = vi.fn()
    await expect(run(refusedAll, cardAndEarn, none)).resolves.toEqual({ transactions: [] })
    expect(none).not.toHaveBeenCalled()

    // Any other warm revert stays required: the step hands off instead of reporting it warmed.
    const failing = seedChain({
      restarts: true,
      refuse: [outputs.asset, earnBinding.privateAsset, outputs.earnShare, outputs.zoneRouter],
      balances: funded([outputs.asset, earnBinding.privateAsset, outputs.earnShare]),
    })
    const plan = await zoneRouterSeedPlan(failing as never, cardAndEarn, outputs)
    expect(plan.warm.map((entry) => entry.token)).toEqual([
      outputs.earnShare,
      earnBinding.privateAsset,
    ])
    expect(plan.notes).toEqual([
      expect.stringContaining(`reverts warm(${outputs.earnShare})`),
      expect.stringContaining(`reverts warm(${earnBinding.privateAsset})`),
    ])
    await expect(run(failing, cardAndEarn, none)).resolves.toBeUndefined()
    expect(none).not.toHaveBeenCalled()

    // An unreachable RPC is not a refusal.
    const unreachable = seedChain({
      restarts: true,
      balances: funded([outputs.asset, earnBinding.privateAsset, outputs.earnShare]),
    })
    const error = new HttpRequestError({ url: 'https://rpc.invalid' })
    unreachable.call.mockRejectedValue(error)
    await expect(run(unreachable, cardAndEarn, vi.fn())).rejects.toBe(error)

    // Nor is a node's request limit, even inside a call error.
    const limited = seedChain({
      restarts: true,
      balances: funded([outputs.asset, earnBinding.privateAsset, outputs.earnShare]),
    })
    const limit = new CallExecutionError(
      new LimitExceededRpcError(new Error('request limit exceeded')),
      {},
    )
    limited.call.mockRejectedValue(limit)
    await expect(run(limited, cardAndEarn, vi.fn())).rejects.toBe(limit)
  })

  test('funds as many seeds of a token as the deployer holds units of', async () => {
    const reads = seedChain({
      restarts: true,
      balances: {
        ...funded([outputs.asset, outputs.earnShare]),
        [`${earnBinding.privateAsset}:${deployer}`]: 1n,
      },
    })
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
    await expect(run(reads, cardAndEarn, sendTransactionSync)).resolves.toEqual({
      transactions: [receiptHash],
    })
    // One private-asset unit funds the router's seed; the spender's is left for verify to note.
    expect(
      sentCalls(sendTransactionSync).filter((call) => call[0] === earnBinding.privateAsset),
    ).toEqual([[earnBinding.privateAsset, outputs.zoneRouter, 1n]])
  })

  test('warms without seed tokens and sends nothing once seeded', async () => {
    // Warming spends nothing of the deployer's, so the step completes without seed units.
    const unfunded = seedChain()
    const warmOnly = vi.fn(async () => {
      warmAll(unfunded)
      return { status: 'success', transactionHash: receiptHash }
    })
    await expect(run(unfunded, cardAndEarn, warmOnly)).resolves.toEqual({
      transactions: [receiptHash],
    })
    expect(sentCalls(warmOnly)).toEqual([
      ['warm', outputs.earnShare],
      ['warm', earnBinding.privateAsset],
    ])
    const sendTransactionSync = vi.fn()

    const holders = [outputs.zoneRouter, spender]
    const tokens = [outputs.asset, earnBinding.privateAsset]
    const seeded = seedChain({
      balances: Object.fromEntries(
        holders.flatMap((holder) => tokens.map((token) => [`${token}:${holder}`, 1n])),
      ),
      allowances: Object.fromEntries(
        [outputs.earnShare, earnBinding.privateAsset].map((token) => [
          `${token}:${outputs.zoneRouter}`,
          1n,
        ]),
      ),
    })
    const step = deploymentStep('seed-zone-router')
    expect(await step.satisfied(seeded as never, cardAndEarn, outputs)).toBe(true)
    await expect(run(seeded, cardAndEarn, sendTransactionSync)).resolves.toEqual({
      transactions: [],
    })
    expect(sendTransactionSync).not.toHaveBeenCalled()
  })

  test('stays satisfied once warmed whatever the deployer holds, and still seeds when run', async () => {
    const step = deploymentStep('seed-zone-router')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    expect(step.attemptWhenSatisfied).toBe(true)
    // Every allowance set by earlier callbacks, no seed sent, and a deployer able to fund them all.
    const reads = seedChain({
      restarts: true,
      balances: funded([outputs.asset, earnBinding.privateAsset, outputs.earnShare]),
      allowances: Object.fromEntries(
        [outputs.earnShare, earnBinding.privateAsset].map((token) => [
          `${token}:${outputs.zoneRouter}`,
          1n,
        ]),
      ),
    })
    expect(await step.satisfied(reads as never, cardAndEarn, outputs)).toBe(true)
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
    await expect(run(reads, cardAndEarn, sendTransactionSync)).resolves.toEqual({
      transactions: [receiptHash],
    })
    expect(sentCalls(sendTransactionSync)).toEqual([
      [outputs.asset, outputs.zoneRouter, 1n],
      [earnBinding.privateAsset, outputs.zoneRouter, 1n],
      [outputs.earnShare, outputs.zoneRouter, 1n],
      [earnBinding.privateAsset, spender, 1n],
      [outputs.earnShare, spender, 1n],
      [outputs.asset, spender, 1n],
    ])
  })

  test('reports unreadable seed state without blocking the router', async () => {
    const reads = seedChain()
    const client = {
      ...reads,
      readContract: vi.fn(async (parameters: Record<string, unknown>) => {
        if (parameters.functionName === 'balanceOf')
          throw new HttpRequestError({ status: 500, url: 'https://rpc.test/key-1234' })
        return reads.readContract(parameters)
      }),
      getBlock: async () => ({ number: 7n, timestamp: 110n }),
    }
    const report = await zoneRouterModeModule.inspect!(client as never, cardAndEarn, outputs)
    expect(report?.zoneRouterSeeds).toEqual({
      label: 'Zone router seeds',
      status: 'ready',
      blockers: [],
      details: { unread: 'HTTP request failed.' },
    })
    // A request URL, which may carry credentials, never reaches the report.
    expect(JSON.stringify(report)).not.toContain('key-1234')
  })
})
