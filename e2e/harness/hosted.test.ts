import { cpSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, test, vi } from 'vitest'

import { privateKeyToAccount } from 'viem/accounts'

import { derivedOutsiderPrivateKey, resolveHostedPrivateKeys, runHosted } from './hosted.js'
import { loadProfile } from './profile.js'

describe('hosted identities', () => {
  test('derives a private outsider from the operator key instead of a committed key', () => {
    const operator = `0x${'1'.repeat(64)}` as const
    const other = `0x${'3'.repeat(64)}` as const
    const { outsider } = resolveHostedPrivateKeys({ DEPLOYER_PRIVATE_KEY: operator })
    expect(outsider).toBe(derivedOutsiderPrivateKey(operator))
    expect(resolveHostedPrivateKeys({ DEPLOYER_PRIVATE_KEY: operator }).outsider).toBe(outsider)
    expect(derivedOutsiderPrivateKey(other)).not.toBe(outsider)
    expect(outsider).not.toBe(operator)
    // This key is public; the outsider must never resolve to it.
    expect(privateKeyToAccount(outsider).address).not.toBe(
      '0x2577f709Bfa0B5b7D13E8168B52F1425B8cbab65',
    )
  })
})

test('a hosted run of a Zone profile fails before any read without Zone RPC access', async () => {
  const root = mkdtempSync(join(tmpdir(), 'earn-hosted-zone-'))
  vi.stubEnv('TEMPO_API_KEY', '')
  vi.stubEnv('ZONE_RPC_URL', '')
  try {
    const id = 'e2e-moderato'
    cpSync(new URL(`../../profiles/${id}`, import.meta.url), join(root, 'profiles', id), {
      recursive: true,
    })
    const execute = vi.fn()
    await expect(
      runHosted(loadProfile(join(root, 'profiles', id, 'profile.json')), execute, {
        identities: 'public-fixture',
      }),
    ).rejects.toThrow('Set ZONE_RPC_URL (or TEMPO_API_KEY for the Tempo API) to verify Zone')
    expect(execute).not.toHaveBeenCalled()
  } finally {
    vi.unstubAllEnvs()
    rmSync(root, { recursive: true, force: true })
  }
})
