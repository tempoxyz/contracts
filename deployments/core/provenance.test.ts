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
