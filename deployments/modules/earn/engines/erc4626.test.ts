import { getAddress, zeroAddress, type Address, type Hex, type PublicClient } from 'viem'
import { describe, expect, test, vi } from 'vitest'

import { parseEarnDeploymentProfile } from '../../../core/profile.js'
import { preflightEarnDeployment } from '../../../core/reconcile.js'
import { inspectEngineBindings } from './index.js'

const rpc = vi.hoisted(() => ({ client: undefined as PublicClient | undefined }))
vi.mock(import('../../../chain/runtime.js'), async (original) => ({
  ...(await original()),
  rpcClient: () => rpc.client as never,
}))

const address = (value: number) => getAddress(`0x${value.toString(16).padStart(40, '0')}`)
const engine = address(1)
const venue = address(2)
const asset = address(3)
const owner = address(4)
const expectedRuntime = {
  bytecode: '0x610000' as const,
  references: [{ start: 1, length: 1 }],
  referenceGroups: [[{ start: 1, length: 1 }]],
}
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'erc4626-bindings',
    chainId: 4217,
    owner,
    engine: { kind: 'erc4626', address: engine },
  },
  { deployer: owner, factories: { earn: address(5) } },
)

describe('ERC-4626 engine admission', () => {
  test.each([
    { name: 'vault is zero', overrides: { vault: zeroAddress }, error: 'vault is zero' },
    { name: 'base asset is zero', overrides: { baseAsset: zeroAddress }, error: 'asset is zero' },
    { name: 'asset getter disagrees', overrides: { asset: address(9) }, error: 'asset binding' },
    { name: 'venue asset disagrees', overrides: { venueAsset: address(9) }, error: 'venue asset' },
    { name: 'private scale is zero', overrides: { shareScale: 0n }, error: 'share scale' },
    { name: 'private scale is wrong', overrides: { shareScale: 10n ** 18n }, error: 'share scale' },
    { name: 'venue decimals overflow', overrides: { decimals: 78 }, error: 'share decimals' },
  ])('refuses $name even when executable runtime matches', async ({ overrides, error }) => {
    rpc.client = client(overrides) as never
    await expect(preflight()).rejects.toThrow(error)
  })

  test.each([venue, asset])('refuses an external binding without code: %s', async (missing) => {
    rpc.client = client({}, missing) as never
    await expect(preflight()).rejects.toThrow('no runtime code')
  })

  test.each([0, 6, 18, 77])(
    'accepts constructor-consistent scale for %s venue decimals',
    async (decimals) => {
      rpc.client = client({ decimals, shareScale: 10n ** BigInt(decimals) }) as never
      await expect(preflight()).resolves.toBeUndefined()
    },
  )

  test('rejects executable changes before trusting engine getter answers', async () => {
    const reads = client()
    reads.getCode.mockResolvedValue('0x60ff00')
    rpc.client = reads as never
    await expect(preflight()).rejects.toThrow('runtime does not match this checkout')
    expect(reads.readContract).not.toHaveBeenCalled()
  })

  test('rechecks retained bindings without requiring a current-checkout runtime', async () => {
    rpc.client = client() as never
    await expect(preflightEarnDeployment(profile, 'https://chain.invalid')).resolves.toBeUndefined()
    await expect(
      inspectEngineBindings(client({ shareScale: 1n }) as never, 'erc4626', engine),
    ).rejects.toThrow('share scale')
  })
})

function preflight() {
  return preflightEarnDeployment(
    profile,
    'https://chain.invalid',
    undefined,
    undefined,
    'ready',
    {},
    expectedRuntime,
  )
}

function client(overrides: Record<string, unknown> = {}, missing?: Address) {
  const values: Record<string, unknown> = {
    vault: venue,
    baseAsset: asset,
    asset,
    venueAsset: asset,
    shareScale: 10n ** 6n,
    decimals: 6,
    owner,
    earnVault: zeroAddress,
    ...overrides,
  }
  return {
    getChainId: vi.fn(async () => profile.chainId),
    getCode: vi.fn(async ({ address: target }: { address: Address }): Promise<Hex> =>
      target === missing ? '0x' : '0x61ff00',
    ),
    readContract: vi.fn(
      async ({ address: target, functionName }: { address: Address; functionName: string }) => {
        const name = target === venue && functionName === 'asset' ? 'venueAsset' : functionName
        if (!(name in values)) throw new Error(`Unexpected read ${functionName}`)
        return values[name]
      },
    ),
  }
}
