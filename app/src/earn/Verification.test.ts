import { getAddress, type Address } from 'viem'
import { Addresses as TempoAddresses } from 'viem/tempo'
import { describe, expect, test, vi } from 'vitest'

import type { CatalogStack } from '../../deployments/catalog.js'
import { privateRouteAsset } from '../../deployments/tokens.js'
import { hosted } from '../test/HostedCatalog.js'
import { verifyDeployment } from './Verification.js'

const environment = hosted.environments.find(
  (candidate) => candidate.id === hosted.defaultEnvironmentId,
)!
const chainId = environment.network.chainId
const current = environment.stacks.find((stack) => stack.id === environment.defaultStackId)!
const other = getAddress('0x0000000000000000000000000000000000000009')

describe('deployment verification', () => {
  test('verifies the registered stack', async () => {
    await expect(verifyDeployment(client(current), chainId, current)).resolves.toEqual({
      status: 'verified',
    })
  })

  test('reports a binding the catalog does not record as a mismatch', async () => {
    const values = contractValues(current)
    values.set(key(current.contracts.earnVault, 'engine'), other)
    await expect(
      verifyDeployment(client(current, { values }), chainId, current),
    ).resolves.toMatchObject({
      status: 'mismatch',
      issues: [expect.stringContaining('Deployment bindings do not verify')],
    })
  })

  test('requires Earn contracts to be authorized by a protected EarnShare policy', async () => {
    const protectedStack: CatalogStack = {
      ...current,
      access: { kind: 'tip403-whitelist', transferPolicyId: '469' },
    }
    const values = contractValues(protectedStack)
    values.set(key(TempoAddresses.tip403Registry, 'isAuthorized'), false)
    await expect(
      verifyDeployment(client(protectedStack, { values }), chainId, protectedStack),
    ).resolves.toMatchObject({
      status: 'mismatch',
      issues: ['EarnShare whitelist policy configuration is invalid.'],
    })
  })

  test('fails closed on chain and transport errors', async () => {
    await expect(
      verifyDeployment(client(current, { chainId: 1 }), chainId, current),
    ).resolves.toMatchObject({ status: 'unavailable' })

    const values = contractValues(current)
    values.delete(key(current.contracts.earnVault, 'asset'))
    await expect(
      verifyDeployment(client(current, { values }), chainId, current),
    ).resolves.toMatchObject({ status: 'unavailable' })
  })
})

function client(deployment: CatalogStack, options: client.Options = {}) {
  const values = options.values ?? contractValues(deployment)
  return {
    getChainId: vi.fn(async () => options.chainId ?? chainId),
    readContract: vi.fn(
      async ({ address, functionName }: { address: Address; functionName: string }) => {
        const value = values.get(key(address, functionName))
        if (value === undefined) throw new Error(`Missing mock read ${address}:${functionName}`)
        return value
      },
    ),
  } as unknown as Parameters<typeof verifyDeployment>[0]
}

declare namespace client {
  type Options = {
    chainId?: number | undefined
    values?: Map<string, unknown> | undefined
  }
}

function contractValues(deployment: CatalogStack) {
  const { contracts } = deployment
  const values = new Map<string, unknown>()
  set(values, contracts.earnVault, {
    asset: contracts.asset,
    earnShare: contracts.earnShare,
    earnFees: contracts.earnFees,
    engine: contracts.engine,
    isAccountingAligned: true,
  })
  set(values, contracts.earnFees, {
    earnVault: contracts.earnVault,
    earnShare: contracts.earnShare,
  })
  set(values, contracts.engine, {
    asset: contracts.asset,
    earnVault: contracts.earnVault,
    vault: contracts.venue,
  })
  set(values, contracts.asset, { decimals: deployment.expectedMetadata.asset.decimals })
  const privateAsset = privateRouteAsset(deployment)
  if (privateAsset) {
    set(values, privateAsset, { decimals: deployment.privateAssetMetadata?.decimals })
  }
  set(values, contracts.earnShare, {
    decimals: deployment.expectedMetadata.earnShare.decimals,
    transferPolicyId:
      deployment.access.kind === 'open' ? 1n : BigInt(deployment.access.transferPolicyId),
  })
  set(values, TempoAddresses.tip403Registry, {
    policyData: [0, getAddress('0x0000000000000000000000000000000000000001')],
    isAuthorized: true,
  })
  return values
}

function set(values: Map<string, unknown>, address: Address, record: Record<string, unknown>) {
  for (const [functionName, value] of Object.entries(record)) {
    values.set(key(address, functionName), value)
  }
}

function key(address: Address, functionName: string) {
  return `${address}:${functionName}`
}
