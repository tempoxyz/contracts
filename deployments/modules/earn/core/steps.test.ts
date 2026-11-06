import { describe, expect, test, vi } from 'vitest'
import { zeroAddress, type Address } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import { parseEarnDeploymentProfile } from '../../../core/profile.js'
import { bindCore, deployCore } from './steps.js'

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}` as Address
const key = `0x${'1'.repeat(64)}` as const
const account = privateKeyToAccount(key)
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'bind-test',
    chainId: 4217,
    owner: account.address,
    engine: { kind: 'veda', address: address('1') },
  },
  { deployer: account.address, factories: { earn: address('2'), erc4626Engine: address('3') } },
)
const outputs = {
  engine: address('1'),
  asset: address('4'),
  earnVault: address('5'),
  earnShare: address('6'),
  earnFees: address('7'),
}

describe('deployCore', () => {
  test('rejects an internally consistent stack outside the profile predictions before binding', async () => {
    const fixture = chain()
    fixture.values[profile.factories.earn]!.predictEarnShare = address('9')
    await expect(deployCore.satisfied(fixture.client as never, profile, outputs)).rejects.toThrow(
      'factory predictions',
    )
    await expect(bindCore.satisfied(fixture.client as never, profile, outputs)).rejects.toThrow(
      'factory predictions',
    )
    await expect(
      bindCore.execute(
        {
          profile,
          outputs,
          environment: { DEPLOYER_PRIVATE_KEY: key },
          rpcUrl: 'http://chain.test',
        },
        fixture.dependencies,
      ),
    ).rejects.toThrow('factory predictions')
    expect(fixture.client.sendTransactionSync).not.toHaveBeenCalled()
  })

  test.each(['asset', 'earnFees'] as const)(
    'requires reciprocal %s before offering binding',
    async (field) => {
      const fixture = chain()
      fixture.values[outputs.earnVault]![field] = address('8')
      await expect(bindCore.satisfied(fixture.client as never, profile, outputs)).rejects.toThrow(
        'reciprocal binding',
      )
      expect(fixture.client.sendTransactionSync).not.toHaveBeenCalled()
    },
  )

  test('recovers factory creation evidence with a fresh head after an empty first scan', async () => {
    const fixture = chain()
    const transaction = `0x${'ab'.repeat(32)}` as const
    fixture.client.getLogs
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce([{ transactionHash: transaction }])
    await expect(deployCore.adopt!(fixture.client as never, profile, {})).resolves.toEqual({
      outputs,
      transaction,
    })
    expect(fixture.client.getBlockNumber).toHaveBeenCalledTimes(2)
    expect(fixture.client.getBlockNumber).toHaveBeenCalledWith({ cacheTime: 0 })
  })

  test('leaves missing creation evidence explicit and retryable', async () => {
    const fixture = chain()
    await expect(deployCore.adopt!(fixture.client as never, profile, {})).rejects.toThrow(
      'Retry with a synchronized RPC',
    )
    expect(fixture.client.getBlockNumber).toHaveBeenCalledTimes(2)
  })
})

describe('bindCore', () => {
  test('refuses an already foreign-bound engine instead of emitting or sending an impossible call', async () => {
    const fixture = chain()
    fixture.values[outputs.engine]!.earnVault = address('8')
    fixture.values[address('8')] = { operator: profile.owner }
    await expect(bindCore.satisfied(fixture.client as never, profile, outputs)).rejects.toThrow(
      'already bound',
    )
    await expect(
      bindCore.execute(
        {
          profile,
          outputs,
          environment: { DEPLOYER_PRIVATE_KEY: key },
          rpcUrl: 'http://chain.test',
        },
        fixture.dependencies,
      ),
    ).rejects.toThrow('already bound')
    expect(fixture.client.sendTransactionSync).not.toHaveBeenCalled()
    expect(fixture.dependencies.fundFromFaucet).not.toHaveBeenCalled()
  })

  test('uses active ownership after migration and later operator transfers, not the retired engine owner', async () => {
    const fixture = chain()
    const active = address('8')
    const operator = address('9')
    fixture.values[outputs.engine]!.earnVault = outputs.earnVault
    fixture.values[outputs.engine]!.owner = address('b')
    Object.assign(fixture.values[outputs.earnVault]!, {
      engine: active,
      engineMigrationMode: 1,
      operator,
    })
    fixture.values[active] = {
      asset: outputs.asset,
      earnVault: outputs.earnVault,
      owner: operator,
      supportsInterface: true,
      vault: address('c'),
    }
    const migrated = {
      ...profile,
      core: { ...profile.core, migrationMode: 'OperatorEnabled' as const },
    }
    expect(await bindCore.satisfied(fixture.client as never, migrated, outputs)).toBe(true)
    expect(
      await bindCore.execute(
        {
          profile: migrated,
          outputs,
          environment: { DEPLOYER_PRIVATE_KEY: key },
          rpcUrl: 'http://chain.test',
        },
        fixture.dependencies,
      ),
    ).toEqual({ transactions: [] })
    expect(fixture.client.sendTransactionSync).not.toHaveBeenCalled()
  })

  test('keeps an unbound external owner as an intentional handoff', async () => {
    const fixture = chain()
    fixture.values[outputs.engine]!.owner = address('8')
    expect(await bindCore.satisfied(fixture.client as never, profile, outputs)).toBe(false)
    expect(
      await bindCore.execute(
        {
          profile,
          outputs,
          environment: { DEPLOYER_PRIVATE_KEY: key },
          rpcUrl: 'http://chain.test',
        },
        fixture.dependencies,
      ),
    ).toBeUndefined()
    expect(bindCore.handoff(profile, outputs)).toContain(outputs.earnVault)
    expect(fixture.client.sendTransactionSync).not.toHaveBeenCalled()
  })
})

function chain() {
  const values: Record<string, Record<string, unknown>> = {
    [profile.factories.earn]: {
      predictEarnShare: outputs.earnShare,
      predictEarnFees: outputs.earnFees,
    },
    [outputs.engine]: { asset: outputs.asset, earnVault: zeroAddress, owner: profile.owner },
    [outputs.earnVault]: { ...outputs, operator: profile.owner },
    [outputs.earnFees]: { earnVault: outputs.earnVault },
  }
  const client = {
    getCode: vi.fn(async () => '0x60'),
    getBlockNumber: vi.fn(async () => 2n),
    getLogs: vi.fn(async (): Promise<{ transactionHash: `0x${string}` }[]> => []),
    readContract: vi.fn(
      async ({ address, functionName }: { address: string; functionName: string }) => {
        const value = values[address]?.[functionName]
        if (!value) throw new Error(`Unexpected ${address}.${functionName}`)
        return value
      },
    ),
    sendTransactionSync: vi.fn(),
  }
  return {
    values,
    client,
    dependencies: { authorityClient: () => client as never, fundFromFaucet: vi.fn() },
  }
}
