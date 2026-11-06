import { cpSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, test, vi } from 'vitest'

import { main } from './cli.js'
import { loadEarnProfile, loadEarnProfileBundle, loadEarnProfileForEnvironment } from './bundle.js'
import {
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  profileFactoryDeploymentId,
} from './profile.js'
import { loadPendingDeployment, savePendingDeployment } from './pending.js'

describe('earn CLI', () => {
  // An unset shell variable must fail instead of silently defaulting the receiver to the depositor.
  test('rejects an empty option value', async () => {
    await expect(
      main(['deposit', 'profile.json', '--assets', '1', '--receiver', ''], console, '/'),
    ).rejects.toThrow('--receiver requires a value')
    await expect(
      main(['access', '--', '--earn-file=', 'status', `0x${'1'.repeat(40)}`], console, '/'),
    ).rejects.toThrow('--earn-file requires a value')
  })

  test('accepts --skip-zone only on verify', async () => {
    await expect(main(['deploy', 'profile.json', '--skip-zone'], console, '/')).rejects.toThrow(
      '--skip-zone is supported only by verify',
    )
  })
})

test.each(['plan', 'status'])('%s reads a pending deployment without a signer', async (command) => {
  const root = mkdtempSync(join(tmpdir(), 'signer-free-cli-'))
  try {
    const folder = join(root, 'profiles', 'pending-cli')
    mkdirSync(folder, { recursive: true })
    const path = join(folder, 'profile.json')
    writeFileSync(
      path,
      JSON.stringify({
        version: 1,
        id: 'pending-cli',
        chainId: 4217,
        owner: `0x${'2'.repeat(40)}`,
        engine: { kind: 'veda', address: `0x${'3'.repeat(40)}` },
      }),
    )
    const profile = loadEarnProfileForEnvironment(path, {
      DEPLOYER_PRIVATE_KEY: `0x${'1'.repeat(64)}`,
    })
    savePendingDeployment(path, profile, loadPendingDeployment(path, profile))
    vi.stubEnv('DEPLOYER_PRIVATE_KEY', '')
    vi.stubEnv('TEMPO_RPC_URL', '')
    const output = { log: vi.fn(), warn: vi.fn() }
    await main([command, path, '--json'], output, '/')
    const result = JSON.parse(output.log.mock.calls[0]![0])
    expect(result.deploymentId).toBe('pending-cli')
    if (command === 'plan') expect(result.resolved.deployer).toBe(profile.deployer)
  } finally {
    vi.unstubAllEnvs()
    rmSync(root, { recursive: true, force: true })
  }
})

test('rejects 10000 slippage bps at the CLI boundary, while 9999 proceeds to profile loading', async () => {
  await expect(
    main(['deposit', 'missing-profile.json', '--assets', '1', '--slippage-bps', '10000']),
  ).rejects.toThrow('0 through 9999')
  await expect(
    main(['deposit', 'missing-profile.json', '--assets', '1', '--slippage-bps', '9999']),
  ).rejects.toThrow('ENOENT')
})

test.each(['plan', 'status'])(
  '%s requires separate trusted identity for an unknown hosted profile',
  async (command) => {
    const root = mkdtempSync(join(tmpdir(), 'trusted-identity-cli-'))
    try {
      const knownDirectory = fileURLToPath(
        new URL('../../profiles/veda-moderato/', import.meta.url),
      )
      const folder = join(root, 'profiles', 'external-cli')
      cpSync(knownDirectory, folder, { recursive: true })
      const path = join(folder, 'profile.json')
      const authored = JSON.parse(readFileSync(path, 'utf8'))
      authored.id = 'external-cli'
      writeFileSync(path, JSON.stringify(authored))
      const known = loadEarnProfileBundle(join(knownDirectory, 'profile.json'))
      const trusted = { deployer: known.profile.deployer, factories: known.profile.factories }
      const expected = loadEarnProfile(path, trusted)
      const recordPath = join(folder, 'deployment.json')
      writeFileSync(
        recordPath,
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
      vi.stubEnv('DEPLOYER_PRIVATE_KEY', '')
      vi.stubEnv('TEMPO_RPC_URL', '')
      const output = { log: vi.fn(), warn: vi.fn() }
      await expect(main([command, path, '--json'], output, '/')).rejects.toThrow(
        'cannot approve itself',
      )
      await expect(
        main([command, path, '--trusted-identity', recordPath, '--json'], output, '/'),
      ).rejects.toThrow('not a deployment record')
      await main([command, path, '--trusted-identity', identityPath, '--json'], output, '/')
      expect(JSON.parse(output.log.mock.calls[0]![0]).deploymentId).toBe(expected.id)
    } finally {
      vi.unstubAllEnvs()
      rmSync(root, { recursive: true, force: true })
    }
  },
)
