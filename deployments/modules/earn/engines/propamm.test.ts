import { expect, test, vi } from 'vitest'
import { zeroAddress, zeroHash } from 'viem'
import { readEngineKind } from './index.js'
import { inspectPropAMMEngine, propamm } from './propamm.js'

const address = (n: number) => `0x${n.toString(16).padStart(40, '0')}` as const
const engine = address(1)
const defaults: Record<string, unknown> = {
  asset: address(2),
  pool: address(4),
  priceOracle: address(5),
  baseToken: address(3),
  quoteToken: address(2),
  oracle: address(5),
  maxOracleAge: 86400n,
  shareScale: 1000000n,
  priceScale: 100000000n,
  customerId: `0x${'1'.repeat(64)}`,
  supportsInterface: true,
  isFeeValuationFresh: true,
  paused: false,
  takerAllowed: true,
  recipientAllowed: true,
  resolveRecipient: engine,
}
function client(overrides: Record<string, unknown> = {}) {
  return {
    getCode: vi.fn(async () => '0x6000'),
    readContract: vi.fn(
      async ({ address: target, functionName }: { address: string; functionName: string }) => {
        const key = `${target}:${functionName}`
        if (key in overrides) return overrides[key]
        if (functionName in overrides) return overrides[functionName]
        if (functionName === 'decimals') return target === address(5) ? 8 : 6
        if (functionName in defaults) return defaults[functionName]
        throw new Error(`Unexpected read ${functionName}`)
      },
    ),
  }
}
test('accepts a fresh admitted pool with the canonical bindings and capabilities', async () => {
  expect(await inspectPropAMMEngine(client() as never, engine)).toMatchObject({
    asset: address(2),
    baseToken: address(3),
    pool: address(4),
    oracle: address(5),
  })
})
test.each([
  [{ [`${address(4)}:baseToken`]: address(2) }, 'token bindings'],
  [{ oracle: address(6) }, 'immutable engine oracle'],
  [{ [`${address(2)}:decimals`]: 18 }, 'unsupported decimals'],
  [{ priceScale: 10n }, 'scale mismatch'],
  [{ [`${address(4)}:maxOracleAge`]: 0n }, 'must be nonzero'],
  [{ customerId: zeroHash }, 'route identifier'],
  [{ supportsInterface: false }, 'capability'],
  [{ paused: true }, 'paused'],
  [{ takerAllowed: false }, 'admit'],
  [{ recipientAllowed: false }, 'admit'],
  [{ resolveRecipient: address(6) }, 'redirected'],
  [{ isFeeValuationFresh: false }, 'stale'],
] as const)('rejects unsafe PropAMM configuration %#', async (overrides, message) => {
  await expect(inspectPropAMMEngine(client(overrides) as never, engine)).rejects.toThrow(message)
})
test('rejects absent external runtime code', async () => {
  const rpc = client()
  rpc.getCode.mockResolvedValue('0x')
  await expect(inspectPropAMMEngine(rpc as never, engine)).rejects.toThrow('no runtime code')
})

test('reports temporary readiness independently of valid deployment bindings', async () => {
  const rpc = client({ paused: true, isFeeValuationFresh: false, takerAllowed: false })
  const result = await inspectPropAMMEngine(rpc as never, engine, 'bindings')
  expect(result.readiness).toMatchObject({
    scope: 'deposit',
    status: 'blocked',
    blockers: ['pool is paused', 'engine is not admitted as taker', 'fee valuation is stale'],
  })
  await expect(inspectPropAMMEngine(rpc as never, engine)).rejects.toThrow('deposits unavailable')
  await expect(
    inspectPropAMMEngine(client({ oracle: address(9) }) as never, engine, 'bindings'),
  ).rejects.toThrow('immutable engine oracle')
})

// An engine whose pool is a managed pool: it answers pool() and baseToken(), but its pool has no baseToken().
function managedShapedClient() {
  return {
    readContract: vi.fn(
      async ({ address: target, functionName }: { address: string; functionName: string }) => {
        if (target === engine && functionName === 'pool') return address(4)
        if (target === engine && functionName === 'baseToken') return address(3)
        if (functionName === 'supportsInterface') return false
        throw new Error(`execution reverted: ${functionName}`)
      },
    ),
  }
}

test('recognizes only an engine whose pool is a single-pair pool', async () => {
  expect(await propamm.recognizes(client() as never, engine)).toBe(true)
  expect(await readEngineKind(client({ supportsInterface: false }) as never, engine)).toBe(
    'propamm',
  )
  expect(
    await propamm.recognizes(client({ [`${address(4)}:baseToken`]: address(9) }) as never, engine),
  ).toBe(false)
  expect(await propamm.recognizes(client({ pool: zeroAddress }) as never, engine)).toBe(false)
})

test('refuses a managed-pool engine instead of resolving it as the single-pair kind', async () => {
  await expect(propamm.recognizes(managedShapedClient() as never, engine)).rejects.toThrow()
  await expect(readEngineKind(managedShapedClient() as never, engine)).rejects.toThrow(
    'unknown or ambiguous engine interfaces',
  )
})
