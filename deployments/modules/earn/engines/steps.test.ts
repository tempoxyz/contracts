import { describe, expect, test, vi } from 'vitest'
import { zeroAddress, type Address } from 'viem'

import { parseEarnDeploymentProfile } from '../../../core/profile.js'
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
