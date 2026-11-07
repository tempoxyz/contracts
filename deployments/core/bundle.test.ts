import { execFileSync } from 'node:child_process'
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { describe, expect, test } from 'vitest'

import {
  loadDeploymentEnvironment,
  loadEarnProfileBundle,
  loadEarnProfile,
  loadReviewedDeploymentIdentity,
  loadEarnProfileForEnvironment,
  loadEarnProfileForRead,
  profileRepositoryRoot,
} from './bundle.js'
import { loadPendingDeployment, savePendingDeployment } from './pending.js'
import {
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  profileFactoryDeploymentId,
} from './profile.js'
import { parseEarnDeploymentRecord } from './record.js'

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}`
const profile = {
  version: 1,
  id: 'bundle-test',
  chainId: 4217,
  owner: address('2'),
  engine: { kind: 'veda', address: address('3') },
}

describe('profile bundles', () => {
  test('accepts an explicit reviewed identity file but not a deployment record as its own trust input', () => {
    const directory = mkdtempSync(join(tmpdir(), 'earn-identity-input-'))
    try {
      const path = join(directory, 'reviewed.json')
      const trusted = {
        deployer: address('2'),
        factories: { earn: address('3'), erc4626Engine: address('4') },
      }
      writeFileSync(path, JSON.stringify(trusted))
      expect(loadReviewedDeploymentIdentity(path)).toEqual(trusted)
      writeFileSync(path, JSON.stringify({ ...trusted, deploymentId: 'from-record' }))
      expect(() => loadReviewedDeploymentIdentity(path)).toThrow('not a deployment record')
    } finally {
      rmSync(directory, { recursive: true, force: true })
    }
  })

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

      expect(loadEarnProfileForRead(path)).toEqual(resumed)
      expect(resumed.deployer).toBe(resolved.deployer)
      expect(resumed.owner).toBe(resolved.owner)
      expect(resumed.factories).toEqual(resolved.factories)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

// Customer profiles live in a private deployments repository that pins Earn as a submodule, so the
// tooling must treat any `<root>/profiles/<id>/` exactly like Earn's own. Its test starts
// `pnpm exec tsx` processes, which can take longer than the default 5s.
describe('profiles outside this repository', { timeout: 30_000 }, () => {
  const earn = resolve(fileURLToPath(new URL('../..', import.meta.url)))

  test('rejects a coherently rewritten identity before the record can choose its own baseline', () => {
    const external = mkdtempSync(join(tmpdir(), 'earn-record-identity-'))
    try {
      const directory = join(external, 'profiles', 'veda-moderato')
      cpSync(join(earn, 'profiles', 'veda-moderato'), directory, { recursive: true })
      const path = join(directory, 'profile.json')
      expect(loadEarnProfileBundle(path).profile.id).toBe('veda-moderato')
      const record = JSON.parse(readFileSync(join(directory, 'deployment.json'), 'utf8'))
      record.deployer = address('9')
      const substituted = loadEarnProfile(path, {
        deployer: record.deployer,
        factories: record.factories,
      })
      record.owner = substituted.owner
      record.deploymentIntentHash = deploymentIntentHash(substituted)
      record.componentDeploymentIntentHashes = componentDeploymentIntentHashes(substituted)
      record.source.factoryDeploymentId = profileFactoryDeploymentId(substituted)
      // A circular parse is internally consistent, but must not establish trust for a consumer.
      expect(() => parseEarnDeploymentRecord(record, substituted)).not.toThrow()
      writeFileSync(join(directory, 'deployment.json'), JSON.stringify(record))
      expect(() => loadEarnProfileBundle(path)).toThrow('independently reviewed identity')
      expect(() => loadEarnProfileForEnvironment(path, {})).toThrow(
        'independently reviewed identity',
      )
      expect(() => loadEarnProfileForRead(path)).toThrow('independently reviewed identity')
    } finally {
      rmSync(external, { recursive: true, force: true })
    }
  })

  test('requires explicit independent identity for an unknown hosted profile', () => {
    const external = mkdtempSync(join(tmpdir(), 'earn-trusted-identity-'))
    try {
      const directory = join(external, 'profiles', 'external')
      cpSync(join(earn, 'profiles', 'veda-moderato'), directory, { recursive: true })
      const path = join(directory, 'profile.json')
      const authored = JSON.parse(readFileSync(path, 'utf8'))
      authored.id = 'external'
      writeFileSync(path, JSON.stringify(authored))
      const known = loadEarnProfileBundle(join(earn, 'profiles', 'veda-moderato', 'profile.json'))
      // Caller config, not a value chosen by the document being loaded.
      const trusted = { deployer: known.profile.deployer, factories: known.profile.factories }
      const expected = loadEarnProfile(path, trusted)
      const record = {
        ...known.record,
        deploymentId: expected.id,
        deploymentIntentHash: deploymentIntentHash(expected),
        componentDeploymentIntentHashes: componentDeploymentIntentHashes(expected),
        source: {
          ...known.record.source,
          factoryDeploymentId: profileFactoryDeploymentId(expected),
        },
      }
      writeFileSync(join(directory, 'deployment.json'), JSON.stringify(record))
      expect(() => loadEarnProfileBundle(path)).toThrow('cannot approve itself')
      expect(loadEarnProfileBundle(path, trusted).profile).toEqual(expected)
      expect(loadEarnProfileForRead(path, trusted)).toEqual(expected)
      expect(loadEarnProfileForEnvironment(path, {}, trusted)).toEqual(expected)
    } finally {
      rmSync(external, { recursive: true, force: true })
    }
  })

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
