import { expect, test, vi } from 'vitest'
import { zeroAddress, zeroHash } from 'viem'
import { engineDefinitions } from './index.js'
import {
  inspectManagedPropAMMEngine,
  managedPropamm,
  quoteManagedPropAMMRoute,
} from './managed-propamm.js'

const address = (n: number) => `0x${n.toString(16).padStart(40, '0')}` as const
const engine = address(1)
const livePair = {
  base: address(3),
  quote: address(2),
  oracle: address(5),
  baseDecimals: 6,
  quoteDecimals: 6,
  oracleDecimals: 8,
  priceScale: 100000000n,
  maxOracleAge: 86400n,
  maxPriceDeviationBps: 50n,
  access: 2,
}
const noPair = {
  ...livePair,
  base: zeroAddress,
  quote: zeroAddress,
  oracle: zeroAddress,
  baseDecimals: 0,
  quoteDecimals: 0,
  oracleDecimals: 0,
  priceScale: 0n,
  maxOracleAge: 0n,
  access: 0,
}
const defaults: Record<string, unknown> = {
  asset: address(2),
  baseToken: address(3),
  pool: address(4),
  pairIndex: 7,
  sponsorId: 9n,
  priceOracle: address(5),
  maxOracleAge: 86400n,
  shareScale: 1000000n,
  priceScale: 100000000n,
  customerId: `0x${'1'.repeat(64)}`,
  supportsInterface: true,
  isFeeValuationFresh: true,
  pair: livePair,
  pairHook: [zeroAddress, 0],
  paused: false,
  takerAccess: 1,
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

test('accepts a fresh admitted pair with the canonical bindings and capabilities', async () => {
  const rpc = client()
  expect(await inspectManagedPropAMMEngine(rpc as never, engine)).toMatchObject({
    asset: address(2),
    baseToken: address(3),
    pool: address(4),
    pairIndex: 7,
    sponsorId: 9n,
    oracle: address(5),
    readiness: { status: 'ready', blockers: [] },
  })
  // Every pool read names the engine's own pair, and access names the engine and its sponsor.
  const poolReads = rpc.readContract.mock.calls
    .map(([call]) => call as { address: string; functionName: string; args?: unknown[] })
    .filter((call) => call.address === address(4) && call.functionName !== 'paused')
  expect(poolReads.map((call) => call.functionName).sort()).toEqual([
    'pair',
    'pairHook',
    'takerAccess',
  ])
  for (const call of poolReads) expect(call.args?.[0]).toBe(7)
  expect(poolReads.find((call) => call.functionName === 'takerAccess')?.args).toEqual([
    7,
    engine,
    9n,
  ])
})

test.each([
  [{ pair: noPair }, 'no live pair 7'],
  [{ pair: { ...livePair, base: address(2) } }, 'token bindings'],
  [{ pair: { ...livePair, quote: address(6) } }, 'token bindings'],
  [{ pair: { ...livePair, oracle: address(6) } }, 'immutable engine oracle'],
  [{ [`${address(2)}:decimals`]: 18 }, 'unsupported decimals'],
  [{ pair: { ...livePair, baseDecimals: 18 } }, 'pair decimals'],
  [{ priceScale: 10n }, 'scale mismatch'],
  [{ pair: { ...livePair, priceScale: 10n } }, 'scale mismatch'],
  [{ pair: { ...livePair, maxOracleAge: 0n } }, 'must be nonzero'],
  [{ customerId: zeroHash }, 'route identifier'],
  [{ supportsInterface: false }, 'capability'],
  [{ paused: true }, 'paused'],
  [{ takerAccess: 3 }, 'pair is closed'],
  [{ takerAccess: 4 }, 'deny list'],
  [{ takerAccess: 5 }, 'sponsor is not registered'],
  [{ takerAccess: 6 }, 'sponsor is disabled'],
  [{ takerAccess: 7 }, 'does not admit the sponsor'],
  [{ takerAccess: 8 }, 'not on the access list'],
  [{ takerAccess: 0 }, 'not admitted'],
  [{ pairHook: [address(8), 1] }, 'hook'],
  [{ isFeeValuationFresh: false }, 'stale'],
] as const)('rejects unsafe managed PropAMM configuration %#', async (overrides, message) => {
  await expect(inspectManagedPropAMMEngine(client(overrides) as never, engine)).rejects.toThrow(
    message,
  )
})

test('rejects absent external runtime code', async () => {
  const rpc = client()
  rpc.getCode.mockResolvedValue('0x')
  await expect(inspectManagedPropAMMEngine(rpc as never, engine)).rejects.toThrow('no runtime code')
})

test('reports temporary readiness independently of valid deployment bindings', async () => {
  const rpc = client({ paused: true, isFeeValuationFresh: false, takerAccess: 3 })
  const result = await inspectManagedPropAMMEngine(rpc as never, engine, 'bindings')
  expect(result.readiness).toMatchObject({
    scope: 'deposit',
    status: 'blocked',
    blockers: ['pool is paused', 'pair is closed', 'fee valuation is stale'],
  })
  await expect(inspectManagedPropAMMEngine(rpc as never, engine)).rejects.toThrow(
    'deposits unavailable',
  )
  await expect(
    inspectManagedPropAMMEngine(
      client({ pair: { ...livePair, oracle: address(9) } }) as never,
      engine,
      'bindings',
    ),
  ).rejects.toThrow('immutable engine oracle')
  // A removed pair is a binding failure in either mode, never a temporary blocker.
  await expect(
    inspectManagedPropAMMEngine(client({ pair: noPair }) as never, engine, 'bindings'),
  ).rejects.toThrow('no live pair')
})

test('quotes the route on the engine pair with the engine as taker', async () => {
  const rpc = client({ quoteExactInputFor: [100n, 105000000n, 1n, 0n] })
  expect(await quoteManagedPropAMMRoute(rpc as never, engine, false, 105n)).toBe(100n)
  expect(rpc.readContract).toHaveBeenLastCalledWith(
    expect.objectContaining({
      address: address(4),
      functionName: 'quoteExactInputFor',
      args: [7, engine, defaults.customerId, false, 105n],
    }),
  )
  expect(await managedPropamm.quoteDeposit(rpc as never, { engine } as never, 105n)).toBe(100n)
})

test('is not a registered engine kind', () => {
  expect(Object.values(engineDefinitions)).not.toContain(managedPropamm)
  expect(
    Object.values(engineDefinitions).map((definition) => definition.engineContract),
  ).not.toContain(managedPropamm.engineContract)
})
