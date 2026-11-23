import { describe, expect, test, vi } from 'vitest'
import { decodeFunctionData, erc20Abi, zeroAddress, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import { parseEarnDeploymentProfile } from '../../../core/profile.js'
import { deploymentStep, executeAvailableAuthority } from '../../index.js'
import { deployEngine, resolvedEngineStateSatisfied } from './steps.js'

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}` as Address
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'engine-test',
    chainId: 4217,
    owner: address('4'),
    engine: { kind: 'erc4626', venue: address('6') },
  },
  { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
)
const outputs = { engine: address('1'), asset: address('7') }

describe('deployEngine', () => {
  test('rejects a substituted resume engine before its self-reported state can be adopted', async () => {
    const client = {
      getCode: vi.fn(async () => '0x60'),
      readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
        if (functionName === 'predictEngine') return address('9')
        throw new Error('Must check prediction first')
      }),
    }
    await expect(deployEngine.satisfied(client as never, profile, outputs)).rejects.toThrow(
      'factory prediction',
    )
    expect(client.readContract).toHaveBeenCalledTimes(1)
  })

  test('uses the engine factory creation event instead of a later successful reuse receipt', async () => {
    const transaction = `0x${'ab'.repeat(32)}` as const
    const client = {
      getCode: vi.fn(async () => '0x60'),
      readContract: vi.fn(
        async ({ functionName }: { functionName: string }) =>
          ({
            predictEngine: outputs.engine,
            asset: outputs.asset,
            owner: profile.deployer,
            earnVault: zeroAddress,
          })[functionName],
      ),
      getBlockNumber: vi.fn(async () => 2n),
      getLogs: vi.fn(async () => [{ transactionHash: transaction }]),
    }
    await expect(deployEngine.adopt!(client as never, profile, {})).resolves.toEqual({
      outputs,
      transaction,
    })
    expect(client.getBlockNumber).toHaveBeenCalledWith({ cacheTime: 0 })
    expect(client.getLogs).toHaveBeenCalledWith(
      expect.objectContaining({
        address: profile.factories.erc4626Engine,
        args: { engine: outputs.engine },
      }),
    )
  })

  test('refuses a pre-bound engine when this profile has no predicted core', async () => {
    const client = {
      getCode: vi.fn(async ({ address: target }: { address: Address }) =>
        target === address('b') ? '0x' : '0x60',
      ),
      readContract: vi.fn(
        async ({ functionName }: { functionName: string }) =>
          ({
            predictEngine: outputs.engine,
            asset: outputs.asset,
            owner: profile.owner,
            earnVault: address('8'),
            operator: profile.owner,
            predictEarnShare: address('b'),
            predictEarnFees: address('c'),
          })[functionName],
      ),
    }
    await expect(deployEngine.satisfied(client as never, profile, outputs)).rejects.toThrow(
      'not this profile’s predicted stack'.replace('’', "'"),
    )
  })
})

describe('resolvedEngineStateSatisfied', () => {
  test('requires an explicit expected vault for an already bound engine', () => {
    const state = { asset: outputs.asset, owner: profile.owner, earnVault: address('8') }
    expect(resolvedEngineStateSatisfied(profile, outputs, state)).toBe(false)
    expect(
      resolvedEngineStateSatisfied(profile, { ...outputs, earnVault: state.earnVault }, state),
    ).toBe(true)
    expect(
      resolvedEngineStateSatisfied(profile, outputs, {
        ...state,
        owner: profile.deployer,
        earnVault: zeroAddress,
      }),
    ).toBe(true)
  })
})

describe('seedEngine', () => {
  const deployerKey = `0x${'4'.repeat(64)}` as const
  const deployer = privateKeyToAccount(deployerKey).address
  const receiptHash = `0x${'cd'.repeat(32)}` as const
  const vault = address('8')
  const seeded = { ...outputs, earnVault: vault }
  const propammProfile = parseEarnDeploymentProfile(
    {
      version: 1,
      id: 'engine-seed-test',
      chainId: 4217,
      owner: address('4'),
      engine: { kind: 'propamm', address: address('1') },
    },
    { deployer, factories: { earn: address('3'), erc4626Engine: address('5') } },
  )
  const run = (
    balances: Record<string, bigint>,
    options: { boundTo?: Address; refuses?: boolean } = {},
  ) => {
    const sendTransactionSync = vi
      .fn()
      .mockResolvedValue({ status: 'success', transactionHash: receiptHash })
    const result = executeAvailableAuthority(
      {
        action: { id: 'seed-engine' },
        environment: { DEPLOYER_PRIVATE_KEY: deployerKey },
        outputs: seeded,
        profile: propammProfile,
        rpcUrl: 'https://rpc.invalid',
      },
      {
        authorityClient: ((_options: unknown, account: unknown) => ({
          account,
          chain: { id: 4217 },
          getTransactionCount: async () => 0,
          call: async () => {
            if (options.refuses) throw new Error('execution reverted')
            return { data: '0x' }
          },
          readContract: async ({
            functionName,
            args,
          }: {
            functionName: string
            args?: readonly Address[]
          }) => {
            if (functionName === 'earnVault') return options.boundTo ?? vault
            if (functionName === 'owner') return address('4')
            if (functionName === 'asset') return outputs.asset
            if (functionName === 'balanceOf') return balances[args![0]!] ?? 0n
            throw new Error(`unexpected read ${functionName}`)
          },
          sendTransactionSync,
        })) as never,
        fundFromFaucet: vi.fn() as never,
      },
    )
    return { result, sendTransactionSync }
  }

  test('runs for engines that hold no asset between calls, never blocking', async () => {
    const step = deploymentStep('seed-engine')
    if (step.execution !== 'authority') throw new Error('expected an authority step')
    expect(step.attemptWhenSatisfied).toBe(true)
    expect(step.enabled(propammProfile)).toBe(true)
    expect(step.enabled(profile)).toBe(true)
    expect(
      step.enabled(
        parseEarnDeploymentProfile(
          {
            version: 1,
            id: 'engine-seed-test',
            chainId: 4217,
            owner: address('4'),
            engine: { kind: 'veda', address: address('1') },
          },
          { deployer, factories: { earn: address('3'), erc4626Engine: address('5') } },
        ),
      ),
    ).toBe(true)
    expect(await step.satisfied({} as never, propammProfile, seeded)).toBe(true)
  })

  test('sends one base unit of the asset to an empty bound engine', async () => {
    const { result, sendTransactionSync } = run({ [deployer]: 5n })
    await expect(result).resolves.toEqual({ transactions: [receiptHash] })
    const calls = sendTransactionSync.mock.calls[0]![0].calls as { to: Address; data: Hex }[]
    expect(
      calls.map((call) => [
        call.to,
        ...decodeFunctionData({ abi: erc20Abi, data: call.data }).args!,
      ]),
    ).toEqual([[outputs.asset, outputs.engine, 1n]])
  })

  test('sends nothing when seeded, unfunded, refused, or bound elsewhere', async () => {
    for (const [balances, options] of [
      [{ [deployer]: 5n, [outputs.engine]: 1n }, {}],
      [{}, {}],
      [{ [deployer]: 5n }, { refuses: true }],
      [{ [deployer]: 5n }, { boundTo: address('9') }],
    ] as const) {
      const { result, sendTransactionSync } = run(balances, options)
      await expect(result).resolves.toEqual({ transactions: [] })
      expect(sendTransactionSync).not.toHaveBeenCalled()
    }
  })
})
