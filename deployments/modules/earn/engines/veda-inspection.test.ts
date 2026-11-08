import { toHex, zeroAddress, type Hex, type PublicClient } from 'viem'
import { describe, expect, test, vi } from 'vitest'
import { InspectionMismatchError } from '../../../chain/inspect.js'
import { parseEarnDeploymentProfile } from '../../../core/profile.js'
import { preflightEarnDeployment } from '../../../core/reconcile.js'
import {
  inspectVedaEngine,
  inspectVedaPeriphery,
  readVedaStackPeriphery,
} from './veda-inspection.js'

const rpc = vi.hoisted(() => ({ client: undefined as PublicClient | undefined }))
vi.mock(import('../../../chain/runtime.js'), async (original) => ({
  ...(await original()),
  rpcClient: () => rpc.client as never,
}))

const address = (n: number) => `0x${n.toString(16).padStart(40, '0')}` as const
const [engine, vault, asset, teller, queue, accountant, registry, authority] = [
  1, 2, 3, 4, 5, 6, 7, 8,
].map(address)
// Engine and registry share read names; each answers with the same consistent tuple.
const defaults: Record<string, unknown> = {
  peripheryRegistry: registry,
  vault,
  asset,
  baseAsset: asset,
  base: asset,
  teller,
  queue,
  accountant,
  engine,
  peripheryVersion: 1n,
  version: 1n,
  authority,
  canCall: true,
  trackWithdrawsOnChain: true,
  isFeeValuationFresh: true,
  rate: 1_000_000n,
  shareScale: 1_000_000n,
  decimals: 6,
  owner: authority,
  earnVault: zeroAddress,
  assetData: [true, true, 0],
}

function client(overrides: Record<string, unknown> = {}) {
  return {
    readContract: vi.fn(
      async ({ address: target, functionName }: { address: string; functionName: string }) => {
        const key = `${target}:${functionName}`
        if (key in overrides) return overrides[key]
        if (functionName in overrides) return overrides[functionName]
        if (functionName in defaults) return defaults[functionName]
        throw new Error(`Unexpected read ${functionName}`)
      },
    ),
  } as unknown as Parameters<typeof inspectVedaEngine>[0]
}

test('accepts an engine whose registry, Accountant, and capabilities agree', async () => {
  await expect(inspectVedaEngine(client(), engine)).resolves.toBeUndefined()
  await expect(inspectVedaPeriphery(client(), engine)).resolves.toEqual({
    registry,
    vault,
    asset,
    teller,
    queue,
    accountant,
    authority,
  })
})

test('rejects periphery that does not point back at the engine', async () => {
  const unbound = inspectVedaEngine(client({ [`${registry}:engine`]: address(9) }), engine)
  await expect(unbound).rejects.toThrow('Veda registry engine')
  await expect(unbound).rejects.toBeInstanceOf(InspectionMismatchError)
  await expect(inspectVedaEngine(client({ [`${registry}:version`]: 2n }), engine)).rejects.toThrow(
    'periphery version',
  )
  await expect(
    inspectVedaEngine(client({ [`${accountant}:vault`]: address(9) }), engine),
  ).rejects.toThrow('Veda Accountant BoringVault')
})

test('rejects a missing engine capability or an untracked Queue', async () => {
  await expect(inspectVedaEngine(client({ canCall: false }), engine)).rejects.toThrow(
    'VedaEngine lacks the Teller bulkDeposit capability',
  )
  await expect(inspectVedaEngine(client({ trackWithdrawsOnChain: false }), engine)).rejects.toThrow(
    'does not track withdrawals onchain',
  )
  // The periphery wiring alone does not depend on the Queue.
  await expect(
    inspectVedaPeriphery(client({ trackWithdrawsOnChain: false }), engine),
  ).resolves.toMatchObject({ queue })
})

test('checks freshness and open deposits only when ready', async () => {
  const stale = client({ isFeeValuationFresh: false })
  await expect(inspectVedaEngine(stale, engine, 'bindings')).resolves.toBeUndefined()
  await expect(inspectVedaEngine(stale, engine)).rejects.toThrow('older than the engine maxRateAge')
})

test('projects the cached periphery during rotation but keeps strict readiness closed', async () => {
  const rotating = client({
    [`${registry}:version`]: 2n,
    [`${registry}:teller`]: address(9),
    canCall: false,
  })
  await expect(readVedaStackPeriphery(rotating, engine)).resolves.toMatchObject({
    teller,
    accountant,
    peripheryRegistry: registry,
  })
  await expect(inspectVedaEngine(rotating, engine)).rejects.toThrow('registry Teller')
  await expect(
    readVedaStackPeriphery(client({ [`${registry}:engine`]: address(9) }), engine),
  ).rejects.toThrow('registry engine')
  await expect(
    readVedaStackPeriphery(client({ [`${accountant}:base`]: address(9) }), engine),
  ).rejects.toThrow('Accountant base asset')
})

const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'veda-bindings',
    chainId: 4217,
    owner: authority,
    engine: { kind: 'veda', address: engine },
  },
  { deployer: authority, factories: { earn: address(9) } },
)
// Two copies model one private immutable: normalization cannot authenticate a consistent value.
const references = [
  { start: 1, length: 32 },
  { start: 34, length: 32 },
]
const expectedRuntime = {
  bytecode: runtime(0n),
  references,
  referenceGroups: [references],
}

describe.each(['ready', 'bindings'] as const)('Veda admission in %s mode', (mode) => {
  test.each([0n, 1n, 10n ** 18n])(
    'rejects a consistently masked scale of %s for a six-decimal vault',
    async (shareScale) => {
      rpc.client = admissionClient({ shareScale }, runtime(shareScale)) as never
      const admission = preflight(mode)
      await expect(admission).rejects.toThrow('Veda immutable share scale')
      await expect(admission).rejects.toBeInstanceOf(InspectionMismatchError)
    },
  )

  test.each([0, 6, 18, 77])('accepts the constructor scale for %s decimals', async (decimals) => {
    const shareScale = 10n ** BigInt(decimals)
    rpc.client = admissionClient({ decimals, shareScale }, runtime(shareScale)) as never
    await expect(preflight(mode)).resolves.toBeUndefined()
  })

  test('rejects decimals beyond the constructor limit', async () => {
    rpc.client = admissionClient({ decimals: 78 }) as never
    await expect(preflight(mode)).rejects.toThrow('Veda vault share decimals exceed 77')
  })
})

test.each([
  { code: runtime(1n, 2n), error: 'inconsistent immutable values' },
  { code: `0x62${runtime(1n).slice(4)}` as Hex, error: 'runtime does not match this checkout' },
])('rejects $error before trusting getter answers', async ({ code, error }) => {
  const reads = admissionClient({}, code)
  rpc.client = reads as never
  await expect(preflight('ready')).rejects.toThrow(error)
  expect(reads.readContract).not.toHaveBeenCalled()
})

test('rechecks retained Veda scale bindings without current-checkout runtime evidence', async () => {
  rpc.client = admissionClient({ shareScale: 1n }) as never
  await expect(
    preflightEarnDeployment(profile, 'https://chain.invalid', undefined, undefined, 'bindings'),
  ).rejects.toThrow('Veda immutable share scale')
})

function preflight(mode: 'ready' | 'bindings') {
  return preflightEarnDeployment(
    profile,
    'https://chain.invalid',
    undefined,
    undefined,
    mode,
    {},
    expectedRuntime,
  )
}

function admissionClient(overrides: Record<string, unknown> = {}, code = runtime(1_000_000n)) {
  return {
    ...client(overrides),
    getChainId: vi.fn(async () => profile.chainId),
    getCode: vi.fn(async () => code),
  }
}

function runtime(scale: bigint, other = scale): Hex {
  return `0x60${toHex(scale, { size: 32 }).slice(2)}61${toHex(other, { size: 32 }).slice(2)}`
}
