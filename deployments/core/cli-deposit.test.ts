import { fileURLToPath } from 'node:url'
import { afterEach, beforeEach, expect, test, vi } from 'vitest'

import { loadEarnProfileBundle } from './bundle.js'

const { depositEarnProfile, verifyEarnProfile } = vi.hoisted(() => ({
  depositEarnProfile: vi.fn(),
  verifyEarnProfile: vi.fn(),
}))
vi.mock('./deposit.js', async (actual) => ({
  ...(await actual<typeof import('./deposit.js')>()),
  depositEarnProfile,
}))
vi.mock('./deploy.js', async (actual) => ({
  ...(await actual<typeof import('./deploy.js')>()),
  verifyEarnProfile,
}))

const { main } = await import('./cli.js')

const profilePath = fileURLToPath(
  new URL('../../profiles/veda-moderato/profile.json', import.meta.url),
)
const deposit = [
  'deposit',
  profilePath,
  '--assets',
  '1',
  '--rpc-url',
  'http://127.0.0.1:1',
  '--json',
]
const output = { log: vi.fn(), warn: vi.fn() }

beforeEach(() => {
  vi.stubEnv('DEPLOYER_PRIVATE_KEY', '')
  depositEarnProfile.mockReset().mockResolvedValue({ state: 'preview' })
  verifyEarnProfile.mockReset()
})
afterEach(() => vi.unstubAllEnvs())

test('broadcast refuses to fund a record that fails verification', async () => {
  verifyEarnProfile.mockRejectedValue(
    new Error('Runtime bytecode hash changed for addresses.earnVault'),
  )
  await expect(main([...deposit, '--broadcast'], output, '/')).rejects.toThrow(
    'Runtime bytecode hash changed',
  )
  expect(verifyEarnProfile).toHaveBeenCalledOnce()
  expect(depositEarnProfile).not.toHaveBeenCalled()
})

test('broadcast funds only the verified record', async () => {
  const verified = { addresses: {} }
  verifyEarnProfile.mockResolvedValue({ record: verified })
  await main([...deposit, '--broadcast', '--skip-zone'], output, '/')
  expect(verifyEarnProfile).toHaveBeenCalledWith(
    expect.objectContaining({ profilePath, rpcUrl: 'http://127.0.0.1:1', skipLive: ['zone'] }),
  )
  expect(depositEarnProfile).toHaveBeenCalledWith(
    expect.objectContaining({ broadcast: true, record: verified }),
  )
})

test('a preview quotes the recorded stack without verification', async () => {
  await main(deposit, output, '/')
  expect(verifyEarnProfile).not.toHaveBeenCalled()
  expect(depositEarnProfile).toHaveBeenCalledWith(
    expect.objectContaining({
      broadcast: false,
      record: loadEarnProfileBundle(profilePath).record,
    }),
  )
})
