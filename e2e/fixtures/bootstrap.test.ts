import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, describe, expect, it } from 'vitest'

const roots: string[] = []
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function bootstrap(id: string, network = 'moderato', kind = 'erc4626') {
  const root = mkdtempSync(join(tmpdir(), 'fixture-bootstrap-'))
  roots.push(root)
  const directory = join(root, 'profiles', 'test-profile')
  mkdirSync(directory, { recursive: true })
  const path = join(directory, 'profile.json')
  const address = `0x${'11'.repeat(20)}`
  writeFileSync(
    path,
    JSON.stringify({
      version: 1,
      id,
      chainId: network === 'mainnet' ? 4217 : 42431,
      engine: kind === 'veda' ? { kind, address } : { kind, venue: address },
    }),
  )
  const result = spawnSync(
    process.execPath,
    [
      '--import',
      'tsx',
      fileURLToPath(new URL('./bootstrap.ts', import.meta.url)),
      '--profile',
      path,
      '--network',
      network,
      '--broadcast',
    ],
    {
      cwd: fileURLToPath(new URL('../', import.meta.url)),
      env: { PATH: process.env.PATH },
      encoding: 'utf8',
      timeout: 30_000,
    },
  )
  expect(result.status).not.toBe(0)
  return result.stderr
}

describe('fixture bootstrap admission', () => {
  it.each(['../another', 'different-profile'])(
    'rejects invalid or mismatched identity %s before dotenv selection',
    (id) => {
      const error = bootstrap(id)
      expect(error).toMatch(/must be|lowercase/)
      expect(error).not.toContain('DEPLOYER_PRIVATE_KEY')
      expect(error).not.toContain('.env.')
    },
    45_000,
  )
  it('rejects a mainnet Veda fixture before signer selection or broadcast', () => {
    const error = bootstrap('test-profile', 'mainnet', 'veda')
    expect(error).toContain('Synthetic fixtures are test-only')
    expect(error).not.toContain('DEPLOYER_PRIVATE_KEY')
  }, 45_000)
})
