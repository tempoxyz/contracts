import { execFileSync } from 'node:child_process'
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { describe, expect, test } from 'vitest'

import {
  loadDeploymentEnvironment,
  loadEarnProfileBundle,
  loadEarnProfileForEnvironment,
  profileRepositoryRoot,
} from './bundle.js'
import { loadPendingDeployment, savePendingDeployment } from './pending.js'

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}`
const profile = {
  version: 1,
  id: 'bundle-test',
  chainId: 4217,
  owner: address('2'),
  engine: { kind: 'veda', address: address('3') },
}

describe('profile bundles', () => {
  test('pins deployer and factories from pending state without requiring the original key', () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-profile-bundle-'))
    try {
      mkdirSync(join(root, 'bundle-test'))
      const path = join(root, 'bundle-test', 'profile.json')
      writeFileSync(path, JSON.stringify(profile))
      const resolved = loadEarnProfileForEnvironment(path, {
        DEPLOYER_PRIVATE_KEY: `0x${'1'.repeat(64)}`,
      })
      savePendingDeployment(path, resolved, loadPendingDeployment(path, resolved))

      const resumed = loadEarnProfileForEnvironment(path, {})

      expect(resumed.deployer).toBe(resolved.deployer)
      expect(resumed.owner).toBe(resolved.owner)
      expect(resumed.factories).toEqual(resolved.factories)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

// Customer profiles live in a private deployments repository that pins Earn as a submodule, so the
// tooling must treat any `<root>/profiles/<id>/` exactly like Earn's own.
describe('profiles outside this repository', () => {
  const earn = resolve(fileURLToPath(new URL('../..', import.meta.url)))

  test('loads the record, dotenv, and drift matrix from the owning repository', () => {
    const external = mkdtempSync(join(tmpdir(), 'earn-external-profiles-'))
    try {
      cpSync(join(earn, 'profiles', 'veda-moderato'), join(external, 'profiles', 'veda-moderato'), {
        recursive: true,
      })
      const path = join(external, 'profiles', 'veda-moderato', 'profile.json')
      writeFileSync(join(external, '.env.veda-moderato'), 'TEMPO_RPC_URL=https://rpc.example\n')

      expect(profileRepositoryRoot(path)).toBe(external)
      expect(loadEarnProfileBundle(path).profile.id).toBe('veda-moderato')
      expect(
        loadDeploymentEnvironment(profileRepositoryRoot(path), 'veda-moderato', {}).TEMPO_RPC_URL,
      ).toBe('https://rpc.example')

      const matrix = JSON.parse(
        execFileSync('pnpm', ['exec', 'tsx', 'core/profiles.ts', '--matrix'], {
          cwd: join(earn, 'deployments'),
          encoding: 'utf8',
          env: { ...process.env, GITHUB_OUTPUT: '', INIT_CWD: external },
        }).replace(/^.*?(\[)/s, '$1'),
      )
      expect(matrix).toContainEqual(expect.objectContaining({ id: 'veda-moderato' }))
      const scoped = JSON.parse(
        execFileSync(
          'pnpm',
          // The bare `--` is what `pnpm profiles -- --matrix` forwards.
          ['exec', 'tsx', 'core/profiles.ts', '--', '--matrix', '--profiles', 'profiles'],
          {
            cwd: join(earn, 'deployments'),
            encoding: 'utf8',
            env: { ...process.env, GITHUB_OUTPUT: '', INIT_CWD: external },
          },
        ).replace(/^.*?(\[)/s, '$1'),
      )
      expect(scoped).toEqual([
        expect.objectContaining({
          id: 'veda-moderato',
          path: 'profiles/veda-moderato/profile.json',
        }),
      ])
    } finally {
      rmSync(external, { recursive: true, force: true })
    }
  })
})
