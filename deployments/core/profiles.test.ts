import { execFileSync } from 'node:child_process'
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { expect, test } from 'vitest'

import { loadEarnProfile, loadEarnProfileBundle } from './bundle.js'
import {
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  profileFactoryDeploymentId,
} from './profile.js'

test.each(['flag', 'environment'])(
  'profiles accepts separate reviewed hosted identity through %s',
  { timeout: 30_000 },
  (source) => {
    const root = mkdtempSync(join(tmpdir(), 'profiles-identity-cli-'))
    try {
      const knownDirectory = fileURLToPath(
        new URL('../../profiles/veda-moderato/', import.meta.url),
      )
      const folder = join(root, 'profiles', 'external-cli')
      cpSync(knownDirectory, folder, { recursive: true })
      cpSync(
        fileURLToPath(new URL('../../profiles/veda-mainnet/', import.meta.url)),
        join(root, 'profiles', 'veda-mainnet'),
        { recursive: true },
      )
      const path = join(folder, 'profile.json')
      const authored = JSON.parse(readFileSync(path, 'utf8'))
      authored.id = 'external-cli'
      writeFileSync(path, JSON.stringify(authored))
      const known = loadEarnProfileBundle(join(knownDirectory, 'profile.json'))
      const trusted = { deployer: known.profile.deployer, factories: known.profile.factories }
      const expected = loadEarnProfile(path, trusted)
      writeFileSync(
        join(folder, 'deployment.json'),
        JSON.stringify({
          ...known.record,
          deploymentId: expected.id,
          deploymentIntentHash: deploymentIntentHash(expected),
          componentDeploymentIntentHashes: componentDeploymentIntentHashes(expected),
          source: {
            ...known.record.source,
            factoryDeploymentId: profileFactoryDeploymentId(expected),
          },
        }),
      )
      const identityPath = join(root, 'reviewed-identity.json')
      writeFileSync(identityPath, JSON.stringify(trusted))
      const script = fileURLToPath(new URL('./profiles.ts', import.meta.url))
      const args = ['exec', 'tsx', script, '--profiles', 'profiles', '--matrix']
      const options = {
        encoding: 'utf8' as const,
        stdio: 'pipe' as const,
        env: {
          ...process.env,
          INIT_CWD: root,
          GITHUB_OUTPUT: '',
          EARN_TRUSTED_DEPLOYMENT_IDENTITY: '',
        },
      }
      expect(() => execFileSync('pnpm', args, options)).toThrow('cannot approve itself')
      expect(() =>
        execFileSync(
          'pnpm',
          [...args, '--trusted-identity', join(folder, 'deployment.json')],
          options,
        ),
      ).toThrow('not a deployment record')
      const additionalFlags: string[] = []
      if (source === 'flag') {
        const second = join(root, 'profiles', 'second-external')
        cpSync(folder, second, { recursive: true })
        const secondPath = join(second, 'profile.json')
        writeFileSync(secondPath, JSON.stringify({ ...authored, id: 'second-external' }))
        const secondIdentity = { ...trusted, deployer: `0x${'9'.repeat(40)}` as const }
        const secondProfile = loadEarnProfile(secondPath, secondIdentity)
        writeFileSync(
          join(second, 'deployment.json'),
          JSON.stringify({
            ...known.record,
            deployer: secondProfile.deployer,
            owner: secondProfile.owner,
            deploymentId: secondProfile.id,
            deploymentIntentHash: deploymentIntentHash(secondProfile),
            componentDeploymentIntentHashes: componentDeploymentIntentHashes(secondProfile),
            source: {
              ...known.record.source,
              factoryDeploymentId: profileFactoryDeploymentId(secondProfile),
            },
          }),
        )
        writeFileSync(join(root, 'second-identity.json'), JSON.stringify(secondIdentity))
        expect(() =>
          execFileSync('pnpm', [...args, '--trusted-identity', 'reviewed-identity.json'], options),
        ).toThrow('cannot approve itself')
        additionalFlags.push('--trusted-identity', 'second-identity.json')
      }
      const output =
        source === 'flag'
          ? execFileSync(
              'pnpm',
              [...args, '--trusted-identity', 'reviewed-identity.json', ...additionalFlags],
              options,
            )
          : execFileSync('pnpm', args, {
              ...options,
              env: { ...options.env, EARN_TRUSTED_DEPLOYMENT_IDENTITY: 'reviewed-identity.json' },
            })
      const matrix = JSON.parse(output) as { id: string; path: string }[]
      expect(matrix).toContainEqual(
        expect.objectContaining({ id: expected.id, path: 'profiles/external-cli/profile.json' }),
      )
      expect(matrix.map((entry) => entry.id)).toEqual(
        source === 'flag'
          ? ['external-cli', 'second-external', 'veda-mainnet']
          : ['external-cli', 'veda-mainnet'],
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  },
)

test.each(['flag', 'environment'])(
  'profiles cannot replace a registry baseline through %s',
  { timeout: 30_000 },
  (source) => {
    const root = mkdtempSync(join(tmpdir(), 'profiles-canonical-cli-'))
    try {
      const original = fileURLToPath(new URL('../../profiles/veda-moderato/', import.meta.url))
      const folder = join(root, 'profiles', 'veda-moderato')
      cpSync(original, folder, { recursive: true })
      const path = join(folder, 'profile.json')
      const known = loadEarnProfileBundle(join(original, 'profile.json'))
      const trusted = {
        deployer: `0x${'9'.repeat(40)}` as const,
        factories: known.profile.factories,
      }
      const profile = loadEarnProfile(path, trusted)
      writeFileSync(join(root, 'reviewed-identity.json'), JSON.stringify(trusted))
      writeFileSync(
        join(folder, 'deployment.json'),
        JSON.stringify({
          ...known.record,
          deployer: profile.deployer,
          owner: profile.owner,
          deploymentIntentHash: deploymentIntentHash(profile),
          componentDeploymentIntentHashes: componentDeploymentIntentHashes(profile),
          source: {
            ...known.record.source,
            factoryDeploymentId: profileFactoryDeploymentId(profile),
          },
        }),
      )
      const args = [
        'exec',
        'tsx',
        fileURLToPath(new URL('./profiles.ts', import.meta.url)),
        '--profiles',
        'profiles',
        '--matrix',
      ]
      const env = {
        ...process.env,
        INIT_CWD: root,
        GITHUB_OUTPUT: '',
        EARN_TRUSTED_DEPLOYMENT_IDENTITY: '',
      }
      if (source === 'flag') args.push('--trusted-identity', 'reviewed-identity.json')
      else env.EARN_TRUSTED_DEPLOYMENT_IDENTITY = 'reviewed-identity.json'
      expect(() => execFileSync('pnpm', args, { encoding: 'utf8', stdio: 'pipe', env })).toThrow(
        'independently reviewed identity',
      )
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  },
)
