import { keccak256 } from 'viem'
import { describe, expect, test, vi } from 'vitest'

import { verifyDeploymentProvenance } from './provenance.js'
import type { EarnDeploymentRecord } from './record.js'

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}` as const
const transaction = `0x${'1'.repeat(64)}` as const
const runtime = '0x6001600055' as const
const codeHash = keccak256(runtime)

const record: EarnDeploymentRecord = {
  version: 4,
  deploymentId: 'provenance-test',
  deployer: address('a'),
  owner: address('a'),
  factories: { earn: address('b'), erc4626Engine: address('c') },
  deploymentIntentHash: 'intent',
  componentDeploymentIntentHashes: {
    core: 'core',
    engine: 'engine',
    zone: null,
    targetYield: null,
    boostRewards: null,
    zoneRouterFactory: null,
    zoneRouter: null,
  },
  target: { chainId: 4217, genesisHash: `0x${'2'.repeat(64)}` },
  assetDecimals: 6,
  deploymentBlock: '10',
  generatedAt: '2026-01-01T00:00:00.000Z',
  source: {
    factoryDeploymentId: `0x${'6'.repeat(64)}`,
    commit: `0x${'3'.repeat(40)}`,
    treeDirty: false,
    foundryVersion: 'forge 1.6.0 tempo',
    contractVerification: 'verified',
    verifierUrl: 'https://contracts.tempo.xyz',
    contracts: {
      engine: {
        kind: 'source',
        name: 'ERC4626Engine',
        match: 'exact_match',
        sourceInputsHash: `0x${'7'.repeat(64)}`,
      },
      earnShare: { kind: 'protocol-native', factory: address('9') },
    },
  },
  addresses: {
    asset: address('1'),
    engine: address('2'),
    earnFees: address('3'),
    earnShare: address('4'),
    earnVault: address('5'),
  },
  runtimeCodeHashes: {
    asset: codeHash,
    engine: codeHash,
    earnFees: codeHash,
    earnShare: codeHash,
    earnVault: codeHash,
  },
  actions: {
    'deploy-core': {
      completedAt: '2026-01-01T00:00:00.000Z',
      verification: 'broadcast',
      transactions: [transaction],
    },
    'bind-core': {
      completedAt: '2026-01-01T00:00:00.000Z',
      verification: 'chain',
      transactions: [],
    },
  },
}

describe('deployment provenance', () => {
  test('a core creation receipt needs no archive reads even with later access configuration', async () => {
    const accessTransaction = `0x${'a'.repeat(64)}` as const
    const client = {
      getCode: async ({ blockNumber }: { blockNumber?: bigint }) => {
        if (blockNumber !== undefined) throw new Error('archive state unavailable')
        return runtime
      },
      getTransactionReceipt: async ({ hash }: { hash: string }) => ({
        blockNumber: hash === transaction ? 10n : 11n,
        status: 'success',
        transactionHash: hash,
      }),
    }
    await expect(
      verifyDeploymentProvenance(client as never, {
        ...record,
        actions: {
          ...record.actions,
          'validate-access': {
            ...record.actions['deploy-core']!,
            transactions: [accessTransaction],
          },
        },
      }),
    ).resolves.toBeUndefined()
  })

  test('accepts matching provenance but rejects runtime drift and reverted receipts', async () => {
    const receipt = (status: string) =>
      vi.fn().mockResolvedValue({ blockNumber: 10n, status, transactionHash: transaction })
    await expect(
      verifyDeploymentProvenance(
        {
          getCode: vi.fn().mockResolvedValue(runtime),
          getTransactionReceipt: receipt('success'),
        } as never,
        record,
      ),
    ).resolves.toBeUndefined()
    await expect(
      verifyDeploymentProvenance(
        {
          getCode: vi.fn().mockResolvedValue('0x6002'),
          getTransactionReceipt: vi.fn(),
        } as never,
        record,
      ),
    ).rejects.toThrow('Runtime bytecode hash changed')

    await expect(
      verifyDeploymentProvenance(
        {
          getCode: vi.fn().mockResolvedValue(runtime),
          getTransactionReceipt: receipt('reverted'),
        } as never,
        record,
      ),
    ).rejects.toThrow('reverted')
  })
})

describe('receipt-free historical provenance', () => {
  const adopted = { ...record, actions: {} }
  test('requires archive proof, rejecting a late scan bound or nonexistent creation', async () => {
    const client = {
      getCode: async () => runtime,
      getTransactionReceipt: async () => {
        throw new Error('unexpected')
      },
    }
    await expect(verifyDeploymentProvenance(client as never, adopted)).rejects.toThrow(
      'archive proof',
    )
    const archive = {
      ...client,
      getCode: async ({ blockNumber }: { blockNumber?: bigint }) =>
        blockNumber === 9n ? '0x' : runtime,
    }
    await expect(verifyDeploymentProvenance(archive as never, adopted)).resolves.toBeUndefined()
    await expect(
      verifyDeploymentProvenance(archive as never, { ...adopted, deploymentBlock: '11' }),
    ).rejects.toThrow('archive proof')
  })
})

describe('adopted core with other receipts', () => {
  test.each(['bind-core', 'validate-access'] as const)(
    'a successful later %s receipt cannot move the claim scan past vault creation',
    async (step) => {
      const actions: EarnDeploymentRecord['actions'] = {
        'deploy-core': {
          ...record.actions['deploy-core']!,
          verification: 'chain',
          transactions: [],
        },
        [step]: { ...record.actions['deploy-core']!, transactions: [transaction] },
      }
      const client = (receiptBlock: bigint) => ({
        getCode: async ({ blockNumber }: { blockNumber?: bigint }) =>
          blockNumber !== undefined && blockNumber < 10n ? '0x' : runtime,
        getTransactionReceipt: async () => ({
          blockNumber: receiptBlock,
          status: 'success',
          transactionHash: transaction,
        }),
      })
      const adopted = { ...record, actions, deploymentBlock: '11' }
      await expect(verifyDeploymentProvenance(client(11n) as never, adopted)).rejects.toThrow(
        'claim scan starts before EarnVault creation',
      )
      // A receipt before core creation is a conservative, independently proven scan boundary.
      await expect(
        verifyDeploymentProvenance(client(5n) as never, { ...adopted, deploymentBlock: '5' }),
      ).resolves.toBeUndefined()
      await expect(
        verifyDeploymentProvenance(client(10n) as never, { ...adopted, deploymentBlock: '10' }),
      ).resolves.toBeUndefined()
    },
  )

  test.each(['bind-core', 'validate-access'] as const)(
    'requires archive evidence when only a %s receipt remains',
    async (step) => {
      const adopted = {
        ...record,
        actions: { [step]: { ...record.actions['deploy-core']!, transactions: [transaction] } },
      }
      const client = {
        getCode: async ({ blockNumber }: { blockNumber?: bigint }) => {
          if (blockNumber !== undefined) throw new Error('archive state unavailable')
          return runtime
        },
        getTransactionReceipt: async () => ({
          blockNumber: 10n,
          status: 'success',
          transactionHash: transaction,
        }),
      }
      await expect(verifyDeploymentProvenance(client as never, adopted)).rejects.toThrow(
        'archive state unavailable',
      )
    },
  )
})
