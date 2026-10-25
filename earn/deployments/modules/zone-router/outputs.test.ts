import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { expect, test, vi } from 'vitest'

import { inspectZone } from '../../chain/zone.js'
import { loadEarnProfileBundle } from '../../core/bundle.js'
import { discoverOutputs, verifyEarnProfile } from '../../core/deploy.js'
import { zoneRpcConfiguration } from './outputs.js'

vi.mock(import('../../chain/zone.js'), async (original) => ({
  ...(await original()),
  inspectZone: vi.fn(async ({ id, chainId }: { id: number; chainId: number }) => ({
    id,
    chainId,
    portal: `0x${'1'.repeat(40)}` as const,
    messenger: `0x${'2'.repeat(40)}` as const,
    sequencers: [`0x${'3'.repeat(40)}` as const],
    encryptionKeyCount: 1n,
  })),
}))

const root = resolve(fileURLToPath(new URL('../../..', import.meta.url)))
const profilePath = (id: string) => resolve(root, 'profiles', id, 'profile.json')
const { profile } = loadEarnProfileBundle(profilePath('e2e-moderato'))
const rpcUrl = 'http://127.0.0.1:1'

test('Zone verification without a Zone RPC names the variable and what it checks', async () => {
  await expect(discoverOutputs({ environment: {}, profile, rpcUrl })).rejects.toThrow(
    /^Set ZONE_RPC_URL \(or TEMPO_API_KEY for the Tempo API\) to verify Zone 3: its RPC must report chain ID \d+ and an inbox bound to the L1 Portal/,
  )
  expect(inspectZone).not.toHaveBeenCalled()
})

test('--skip-zone discovers the Zone from L1 alone', async () => {
  const outputs = await discoverOutputs({ environment: {}, profile, rpcUrl, skipLive: ['zone'] })
  expect(outputs.zonePortal).toBe(`0x${'1'.repeat(40)}`)
  expect(vi.mocked(inspectZone).mock.calls[0]![0].zoneClient).toBeUndefined()
})

test('--skip-zone is refused for a profile without a Zone', async () => {
  await expect(
    verifyEarnProfile({
      environment: {},
      profilePath: profilePath('veda-moderato'),
      root,
      rpcUrl,
      skipLive: ['zone'],
    }),
  ).rejects.toThrow('--skip-zone does not apply: profile veda-moderato has no Zone')
})

test('reads a Zone only through Tempo API or an explicit ZONE_RPC_URL', () => {
  const zone = profile.zone!
  const tempo = { TEMPO_RPC_URL: 'https://rpc.moderato.tempo.xyz' }
  expect(zoneRpcConfiguration(zone.chainId, tempo).url).toBeUndefined()
  expect(zoneRpcConfiguration(zone.chainId, { ...tempo, TEMPO_API_KEY: 'key' }).headers).toEqual({
    'tempo-api-key': 'key',
  })
})
