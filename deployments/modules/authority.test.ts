import {
  ContractFunctionZeroDataError,
  decodeFunctionData,
  getAddress,
  HttpRequestError,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { describe, expect, test, vi } from 'vitest'

import { executeAvailableAuthority } from '../../deployments/modules/index.js'
import { canAuthorizeRouter } from './earn/zone-router/steps.js'
import { requireRouterProvenance } from './earn/zone-router/provenance.js'
import {
  earnEngineBindingAbi,
  propAMMPoolAbi,
  propAMMRebalanceControllerAbi,
  safeAbi,
  zonePortalAbi,
} from '../abis/index.js'
import { planEarnDeployment } from '../core/plan.js'
import { parseEarnDeploymentProfile } from '../core/profile.js'

// Provenance rejection is covered independently; these tests exercise authority and receipt dispatch.
vi.mock('./earn/zone-router/provenance.js', () => ({ requireRouterProvenance: vi.fn() }))

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as `0x${string}`
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'authority-test',
    chainId: 42431,
    owner: address('4'),
    engine: { kind: 'veda', address: address('1') },
    zone: {
      id: 1,
      enableEarnShare: true,
      router: {
        privateAsset: address('6'),
        pool: address('7'),
        customerId: `0x${'c'.repeat(64)}`,
      },
    },
    tip403PolicyId: '469',
  },
  { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
)
const outputs = {
  asset: address('a'),
  earnVault: address('e'),
  earnShare: address('b'),
  zonePortal: address('8'),
}
const engineOwnerKey = `0x${'1'.repeat(64)}` as const
const engineOwner = privateKeyToAccount(engineOwnerKey).address
const engineFinalOwner = address('f')
const engineProfile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'engine-authority-test',
    chainId: 4217,
    owner: engineFinalOwner,
    engine: { kind: 'veda', address: address('1') },
  },
  { deployer: engineOwner, factories: { earn: address('3'), erc4626Engine: address('5') } },
)
const engineOutputs = {
  engine: address('1'),
  asset: address('a'),
  earnVault: address('e'),
  earnShare: address('b'),
  earnFees: address('c'),
}
const authorityKey = `0x${'3'.repeat(64)}` as const
const authorityAccount = privateKeyToAccount(authorityKey).address
const receiptHash = `0x${'a'.repeat(64)}` as const

function mockDependencies(values: unknown[]) {
  const readContract = vi.fn()
  for (const value of values) readContract.mockResolvedValueOnce(value)
  const sendTransactionSync = vi
    .fn()
    .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
  const fundFromFaucet = vi.fn()
  return {
    dependencies: {
      authorityClient: ((_options: unknown, account: unknown) => ({
        account,
        chain: { id: 42431 },
        getTransactionCount: async () => 0,
        getCode: async () => '0x6000',
        readContract,
        sendTransactionSync,
      })) as never,
      fundFromFaucet: fundFromFaucet as never,
    },
    fundFromFaucet,
    readContract,
    sendTransactionSync,
  }
}

/** Executes one planned authority action of `target` with mocked dependencies. */
function execute(
  target: typeof profile,
  id: string,
  environment: NodeJS.ProcessEnv,
  stepOutputs: Record<string, `0x${string}`>,
  dependencies: Parameters<typeof executeAvailableAuthority>[1],
) {
  return executeAvailableAuthority(
    {
      action: planEarnDeployment(target).find((item) => item.id === id)!,
      environment,
      outputs: stepOutputs,
      profile: target,
      rpcUrl: 'https://rpc.invalid',
    },
    dependencies,
  )
}

/** Whether the deployer key proves it can admit the router on its pool. */
function canAuthorize(dependencies: Parameters<typeof canAuthorizeRouter>[1]) {
  return canAuthorizeRouter(
    { environment: { DEPLOYER_PRIVATE_KEY: authorityKey }, profile, rpcUrl: 'https://rpc.invalid' },
    dependencies,
  )
}

describe('deployment authority adapters', () => {
  test('binds as setup owner, transfers to the final owner, and records the receipt', async () => {
    const readContract = coreReadContract()
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: `0x${'a'.repeat(64)}` })
    const fund = vi.fn()
    const result = await execute(
      engineProfile,
      'bind-core',
      { DEPLOYER_PRIVATE_KEY: engineOwnerKey },
      engineOutputs,
      {
        authorityClient: ((_options: unknown, account: unknown) => ({
          account,
          chain: { id: 42431 },
          getTransactionCount: async () => 0,
          getCode: async () => '0x6000',
          readContract,
          sendTransactionSync,
        })) as never,
        fundFromFaucet: fund as never,
      },
    )
    expect(result).toEqual({ transactions: [`0x${'a'.repeat(64)}`] })
    expect(sendTransactionSync).toHaveBeenCalledOnce()
    const sent = sendTransactionSync.mock.calls[0]![0] as { calls: Array<{ data: `0x${string}` }> }
    expect(decodeFunctionData({ abi: earnEngineBindingAbi, data: sent.calls[0]!.data })).toEqual({
      functionName: 'initializeEarnVault',
      args: [engineOutputs.earnVault, engineFinalOwner],
    })
    expect(fund).toHaveBeenCalledWith(expect.anything(), engineProfile, engineOwner)
  })

  test('leaves binding to a handoff when the deployer is not the engine owner', async () => {
    const runtime = mockDependencies([])
    runtime.readContract.mockImplementation(coreReadContract())
    await expect(
      execute(
        engineProfile,
        'bind-core',
        { DEPLOYER_PRIVATE_KEY: `0x${'2'.repeat(64)}` },
        engineOutputs,
        runtime.dependencies,
      ),
    ).resolves.toBeUndefined()
  })

  test('acts through a threshold-1 Safe that the Zone administrator key solely owns', async () => {
    const safe = address('5afe')
    const router = address('9')
    const runtime = mockDependencies([safe, [authorityAccount], 1n, false, false])
    const result = await execute(
      profile,
      'register-zone-gateway',
      { ZONE_ADMIN_PRIVATE_KEY: authorityKey },
      { ...outputs, earnRouter: router },
      runtime.dependencies,
    )
    expect(result).toEqual({ transactions: [receiptHash] })
    const [call] = runtime.sendTransactionSync.mock.calls[0]![0].calls as Array<{
      to: string
      data: `0x${string}`
    }>
    expect(call!.to).toBe(safe)
    const execution = decodeFunctionData({ abi: safeAbi, data: call!.data })
    expect(execution.functionName).toBe('execTransaction')
    expect(execution.args.slice(0, 2)).toEqual([outputs.zonePortal, 0n])
    expect(
      decodeFunctionData({ abi: zonePortalAbi, data: execution.args[2] as `0x${string}` }),
    ).toMatchObject({ functionName: 'setGateway', args: [router, true] })
  })

  test.each([
    { name: 'another owner', owners: [address('7')], threshold: 1n },
    { name: 'a co-owner', owners: [authorityAccount, address('7')], threshold: 1n },
    { name: 'a higher threshold', owners: [authorityAccount], threshold: 2n },
  ])('refuses a Portal admin Safe with $name', async ({ owners, threshold }) => {
    const runtime = mockDependencies([address('5afe'), owners, threshold])
    await expect(
      execute(
        profile,
        'register-zone-gateway',
        { ZONE_ADMIN_PRIVATE_KEY: authorityKey },
        { ...outputs, earnRouter: address('9') },
        runtime.dependencies,
      ),
    ).rejects.toThrow('does not control Portal')
    expect(runtime.sendTransactionSync).not.toHaveBeenCalled()
  })

  test.each([
    { name: 'an open gateway', gatewayOpen: true, registered: false, sends: false },
    { name: 'a registered router', gatewayOpen: false, registered: true, sends: false },
    { name: 'an unregistered router', gatewayOpen: false, registered: false, sends: true },
  ])('registers the router as a callback gateway only for $name', async (scenario) => {
    const router = address('9')
    const runtime = mockDependencies([])
    runtime.readContract.mockImplementation(async ({ functionName, args }) => {
      if (functionName === 'admin') return authorityAccount
      if (functionName === 'isGatewayOpen') return scenario.gatewayOpen
      if (functionName === 'isAccessEnforced') return false
      if (functionName === 'hasRole') return args[1] === 3 && scenario.registered
      throw new Error(`Unexpected Portal read ${functionName}`)
    })
    const result = await execute(
      profile,
      'register-zone-gateway',
      { ZONE_ADMIN_PRIVATE_KEY: authorityKey },
      { ...outputs, earnRouter: router },
      runtime.dependencies,
    )
    // An open gateway needs no role read, so Portals without `hasRole` still reconcile.
    expect(runtime.readContract).toHaveBeenCalledTimes(
      scenario.gatewayOpen ? 4 : scenario.registered ? 5 : 4,
    )
    if (!scenario.gatewayOpen) {
      expect(runtime.readContract.mock.calls[2]![0]).toMatchObject({
        functionName: 'hasRole',
        args: [router, 3],
      })
    }
    if (!scenario.sends) {
      expect(result).toEqual({ transactions: [] })
      expect(runtime.sendTransactionSync).not.toHaveBeenCalled()
      return
    }
    expect(result).toEqual({ transactions: [receiptHash] })
    const [call] = runtime.sendTransactionSync.mock.calls[0]![0].calls as Array<{
      data: `0x${string}`
    }>
    expect(decodeFunctionData({ abi: zonePortalAbi, data: call!.data })).toMatchObject({
      functionName: 'setGateway',
      args: [router, true],
    })
  })

  test('proves router authorization only for the live pool owner', async () => {
    const owner = mockDependencies([authorityAccount])
    await expect(canAuthorize(owner.dependencies)).resolves.toBe(true)
    expect(owner.readContract).toHaveBeenCalledWith(
      expect.objectContaining({ address: address('7'), functionName: 'owner' }),
    )
    const other = mockDependencies([address('9')])
    // The pool owner has no code, so its controller reads return no data.
    other.readContract.mockRejectedValue(
      new ContractFunctionZeroDataError({ functionName: 'pool' }),
    )
    await expect(canAuthorize(other.dependencies)).resolves.toBe(false)
  })

  test('admits the router as pool taker and recipient in one atomic receipt', async () => {
    const router = address('d')
    const runtime = mockDependencies([authorityAccount, false, false, router])
    const result = await execute(
      profile,
      'authorize-router',
      { DEPLOYER_PRIVATE_KEY: authorityKey },
      { ...outputs, earnRouter: router },
      runtime.dependencies,
    )
    expect(result).toEqual({ transactions: [receiptHash] })
    expect(runtime.sendTransactionSync).toHaveBeenCalledOnce()
    const sent = runtime.sendTransactionSync.mock.calls[0]![0] as {
      calls: Array<{ to: string; data: `0x${string}` }>
      forceAtomic: boolean
    }
    expect(sent.forceAtomic).toBe(true)
    expect(sent.calls.map((call) => call.to)).toEqual([address('7'), address('7')])
    expect(
      sent.calls.map((call) => decodeFunctionData({ abi: propAMMPoolAbi, data: call.data })),
    ).toEqual([
      { functionName: 'setTakerAllowed', args: [router, true] },
      { functionName: 'setRecipientAllowed', args: [router, true] },
    ])
    expect(runtime.fundFromFaucet).toHaveBeenCalledWith(
      expect.anything(),
      profile,
      authorityAccount,
    )
  })

  test('admits the router through a rebalance controller the deployer owns', async () => {
    const router = address('d')
    const controller = address('c')
    const runtime = mockDependencies([
      controller,
      address('7'),
      authorityAccount,
      false,
      false,
      router,
    ])
    const result = await execute(
      profile,
      'authorize-router',
      { DEPLOYER_PRIVATE_KEY: authorityKey },
      { ...outputs, earnRouter: router },
      runtime.dependencies,
    )
    expect(result).toEqual({ transactions: [receiptHash] })
    const sent = runtime.sendTransactionSync.mock.calls[0]![0] as {
      calls: Array<{ to: string; data: `0x${string}` }>
      forceAtomic: boolean
    }
    expect(sent.forceAtomic).toBe(true)
    expect(sent.calls.map((call) => call.to)).toEqual([controller, controller])
    const forwarded = sent.calls.map((call) => {
      const { args } = decodeFunctionData({ abi: propAMMRebalanceControllerAbi, data: call.data })
      return decodeFunctionData({ abi: propAMMPoolAbi, data: args[0]! })
    })
    expect(forwarded).toEqual([
      { functionName: 'setTakerAllowed', args: [router, true] },
      { functionName: 'setRecipientAllowed', args: [router, true] },
    ])
  })

  test('leaves a controller-owned pool to a handoff unless the deployer owns that controller', async () => {
    const controller = address('c')
    const foreignOwner = mockDependencies([controller, address('7'), address('9')])
    await expect(canAuthorize(foreignOwner.dependencies)).resolves.toBe(false)

    const otherPool = mockDependencies([controller, address('e'), authorityAccount])
    await expect(canAuthorize(otherPool.dependencies)).resolves.toBe(false)

    const notController = mockDependencies([controller])
    notController.readContract.mockRejectedValue(
      new ContractFunctionZeroDataError({ functionName: 'pool' }),
    )
    await expect(canAuthorize(notController.dependencies)).resolves.toBe(false)
  })

  test('surfaces an RPC failure instead of treating it as missing controller authority', async () => {
    const unreachable = mockDependencies([address('c')])
    unreachable.readContract.mockRejectedValue(new HttpRequestError({ url: 'https://rpc.invalid' }))
    await expect(canAuthorize(unreachable.dependencies)).rejects.toThrow(HttpRequestError)
  })

  test('checks the recovered router implementation before pool admission', async () => {
    const router = address('d')
    const error = new Error('noncanonical router')
    vi.mocked(requireRouterProvenance).mockRejectedValueOnce(error)
    const runtime = mockDependencies([authorityAccount, false, false, router])
    await expect(
      execute(
        profile,
        'authorize-router',
        { DEPLOYER_PRIVATE_KEY: authorityKey },
        { ...outputs, earnRouter: router },
        runtime.dependencies,
      ),
    ).rejects.toBe(error)
    expect(vi.mocked(requireRouterProvenance).mock.lastCall?.[1]).toMatchObject({
      address: router,
      contract: 'src/router/SingleZoneEarnRouter.sol:SingleZoneEarnRouter',
    })
    expect(runtime.sendTransactionSync).not.toHaveBeenCalled()
  })

  test('refuses to admit a router whose pool recipient is redirected', async () => {
    const runtime = mockDependencies([authorityAccount, false, false, address('9')])
    await expect(
      execute(
        profile,
        'authorize-router',
        { DEPLOYER_PRIVATE_KEY: authorityKey },
        { ...outputs, earnRouter: address('d') },
        runtime.dependencies,
      ),
    ).rejects.toThrow('remove the recipient redirect')
    expect(runtime.sendTransactionSync).not.toHaveBeenCalled()
  })
})

function coreReadContract() {
  return vi.fn(
    async ({ address: target, functionName }: { address: string; functionName: string }) => {
      if (functionName === 'predictEarnShare' || functionName === 'earnShare')
        return engineOutputs.earnShare
      if (functionName === 'predictEarnFees' || functionName === 'earnFees')
        return engineOutputs.earnFees
      if (functionName === 'engine') return engineOutputs.engine
      if (functionName === 'asset') return engineOutputs.asset
      if (functionName === 'owner') return engineOwner
      if (functionName === 'earnVault')
        return target === engineOutputs.earnFees ? engineOutputs.earnVault : address('0')
      throw new Error(`Unexpected core read ${functionName}`)
    },
  )
}
