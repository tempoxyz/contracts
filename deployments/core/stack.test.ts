import { getAddress } from 'viem'
import { describe, expect, test } from 'vitest'
import { parsePublicStackCatalog } from './stack.js'

const address = (value: number) =>
  getAddress(`0x${value.toString(16).padStart(40, '0')}` as `0x${string}`)

const zone = {
  name: 'test-zone',
  id: 1,
  chainId: 2,
  rpcUrl: 'https://zone.example',
  portal: address(13),
  messenger: address(14),
  sequencers: [address(3)],
}

const stack = {
  id: 'current',
  description: 'Test stack',
  engineKind: 'erc4626',
  contracts: {
    asset: address(7),
    earnShare: address(8),
    earnVault: address(9),
    earnFees: address(23),
    earnRouter: address(12),
    engine: address(10),
    venue: address(11),
  },
  expectedMetadata: {
    asset: { name: 'Asset', symbol: 'ASSET', decimals: 6 },
    earnShare: { name: 'Earn', symbol: 'EARN', decimals: 6 },
    venue: { name: 'Vault', symbol: 'VAULT', decimals: 6 },
  },
  modes: {
    public: { availability: 'available' },
    private: { availability: 'available', privateAsset: address(7) },
  },
  capabilities: {
    deposit: true,
    inKindDeposit: true,
    redeem: true,
    boundedRedeem: true,
    exactWithdraw: true,
    asyncRedeem: false,
    privateRouting: true,
    routerSwaps: true,
  },
  access: { kind: 'open' },
}

const catalog = {
  network: {
    name: 'test',
    chainId: 1,
    rpcUrl: 'https://rpc.example',
    explorerUrl: 'https://explorer.example',
    pathUsd: address(7),
    zone,
  },
  defaultStackId: stack.id,
  stacks: [stack],
}

describe('public stack catalog', () => {
  test('refuses operational data in the browser-served catalog', () => {
    expect(parsePublicStackCatalog(catalog)).toBeTruthy()
    for (const [key, value] of Object.entries({
      operations: { owner: address(1) },
      metadata: { sourceCommit: 'abc' },
    })) {
      expect(() =>
        parsePublicStackCatalog({ ...catalog, stacks: [{ ...stack, [key]: value }] }),
      ).toThrow(`catalog.stacks[0].${key} is not public`)
    }
    expect(() =>
      parsePublicStackCatalog({
        ...catalog,
        network: { ...catalog.network, tip20Factory: address(30) },
      }),
    ).toThrow('catalog.network.tip20Factory is not supported')
  })

  test('rejects credentials in catalog URLs', () => {
    expect(() =>
      parsePublicStackCatalog({
        ...catalog,
        network: { ...catalog.network, rpcUrl: 'https://user:password@rpc.example' },
      }),
    ).toThrow('catalog.network.rpcUrl must not contain credentials')
    expect(() =>
      parsePublicStackCatalog({
        ...catalog,
        network: { ...catalog.network, zone: { ...zone, rpcUrl: 'https://user@zone.example' } },
      }),
    ).toThrow('catalog.network.zone.rpcUrl must not contain credentials')
  })
})
