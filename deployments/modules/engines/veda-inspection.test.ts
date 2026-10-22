import { expect, test, vi } from 'vitest'
import { InspectionMismatchError } from '../../chain/inspect.js'
import { inspectVedaEngine, inspectVedaPeriphery } from './veda-inspection.js'

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
