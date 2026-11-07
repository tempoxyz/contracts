import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, test, vi } from 'vitest'

import {
  assertFoundryProjectEnvironment,
  assertFoundryVersion,
  sourceVerificationCompilerArguments,
  foundryVerificationEnvironment,
  foundryRpcEnvironment,
  requireStableFoundryVersion,
  solarVerificationArguments,
  solcWrapperVersion,
} from './foundry.js'

test('a solar solc wrapper names its exact build for source verification', () => {
  expect(
    solcWrapperVersion('solar the Solidity compiler\nVersion: 0.8.36+commit.d83529b.solar.0.2.0\n'),
  ).toBe('0.8.36+commit.d83529b.solar.0.2.0')
})

test('solc needs no compiler override', () => {
  expect(
    solcWrapperVersion(
      'solc, the solidity compiler commandline interface\nVersion: 0.8.36+commit.8a079791.Linux.g++\n',
    ),
  ).toBeNull()
  expect(solcWrapperVersion('solar Version: 0.2.0\nCommit SHA: d83529b\n')).toBeNull()
})

test('a solar build is passed to the verifier by its exact version', () => {
  expect(
    solarVerificationArguments(
      './solar-solc',
      'solar the Solidity compiler\nVersion: 0.8.36+commit.d83529b.solar.0.2.0\n',
    ),
  ).toEqual([
    '--compiler-version',
    '0.8.36+commit.d83529b.solar.0.2.0',
    '--compilation-profile',
    'default',
  ])
})

test('a solar build that does not name its version is refused before broadcast', () => {
  expect(() =>
    solarVerificationArguments(
      '/repo/.solar/abc/bin/solar',
      'solar Version: 0.2.0\nCommit SHA: abc\n',
    ),
  ).toThrow('does not report a source-verifiable build')
  expect(() =>
    solarVerificationArguments(
      './solar-solc',
      'Version: 0.8.36+commit.d83529b.solar.0.3.0-beta.1\n',
    ),
  ).toThrow('does not report a source-verifiable build')
})

test('solc needs no verification arguments', () => {
  expect(
    solarVerificationArguments(
      '/svm/0.8.36/solc-0.8.36',
      'Version: 0.8.36+commit.8a079791.Linux.g++\n',
    ),
  ).toEqual([])
})

test.each(['1.8.6', '1.8.7-stable', '1.9.0+commit.abc'])('accepts stable Foundry %s', (version) => {
  expect(() => requireStableFoundryVersion(`forge Version: ${version}\n`)).not.toThrow()
})
test.each(['1.8.5', '1.8.6-rc.1', '1.9.0-nightly', '2.0.0-beta.1'])(
  'rejects unsupported Foundry %s',
  (version) => {
    expect(() => requireStableFoundryVersion(`forge Version: ${version}\n`)).toThrow()
  },
)
test('read-only subprocesses receive neither signer nor compiler override', () => {
  const env = foundryVerificationEnvironment({
    PATH: '/bin',
    DEPLOYER_PRIVATE_KEY: 'secret',
    ZONE_ADMIN_PRIVATE_KEY: 'secret',
    FOUNDRY_SOLC: '/unreviewed',
  })
  expect(env).toEqual({ PATH: '/bin', FOUNDRY_PROFILE: 'deploy' })
  expect(
    foundryRpcEnvironment({ ...env, UNSET: undefined }, 'https://user:secret@rpc.example'),
  ).toEqual({
    ...env,
    FOUNDRY_ETH_RPC_URL: 'https://user:secret@rpc.example',
  })
})
test('rejects implicit project dotenv before any Forge/compiler process runs', () => {
  const root = mkdtempSync(join(tmpdir(), 'foundry-environment-'))
  try {
    expect(() => assertFoundryProjectEnvironment(root)).not.toThrow()
    writeFileSync(join(root, '.env'), 'FOUNDRY_SOLC=/unreviewed\nZONE_ADMIN_PRIVATE_KEY=secret')
    expect(() => assertFoundryProjectEnvironment(root)).toThrow('profile-specific environment file')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('version probe excludes exported keys from its actual child environment', () => {
  const root = mkdtempSync(join(tmpdir(), 'foundry-version-env-'))
  try {
    const executable = join(root, 'forge')
    writeFileSync(
      executable,
      '#!/bin/sh\nif [ -n "$DEPLOYER_PRIVATE_KEY$ZONE_ADMIN_PRIVATE_KEY" ]; then exit 42; fi\nprintf "forge Version: 1.8.7-stable\\n"\n',
    )
    chmodSync(executable, 0o700)
    vi.stubEnv('PATH', root)
    vi.stubEnv('DEPLOYER_PRIVATE_KEY', 'synthetic-deployer')
    vi.stubEnv('ZONE_ADMIN_PRIVATE_KEY', 'synthetic-authority')
    expect(() => assertFoundryVersion(root)).not.toThrow()
  } finally {
    vi.unstubAllEnvs()
    rmSync(root, { recursive: true, force: true })
  }
})

test('compiler identity mismatch is refused before launching the selected executable', () => {
  const root = mkdtempSync(join(tmpdir(), 'foundry-compiler-pin-'))
  try {
    writeFileSync(join(root, 'foundry.toml'), '[profile.default]\nsolc = "./reviewed-solc"\n')
    writeFileSync(join(root, 'forge'), `#!/bin/sh\nprintf '%s\\n' '{"solc":"./unreviewed-solc"}'\n`)
    writeFileSync(join(root, 'unreviewed-solc'), '#!/bin/sh\nprintf reached > invoked\n')
    chmodSync(join(root, 'forge'), 0o700)
    chmodSync(join(root, 'unreviewed-solc'), 0o700)
    expect(() => sourceVerificationCompilerArguments(root, { PATH: root })).toThrow(
      'reviewed foundry.toml pin',
    )
    expect(existsSync(join(root, 'invoked'))).toBe(false)
    // The review input is untouched, rather than silently rewriting it to match the tool's config.
    expect(readFileSync(join(root, 'foundry.toml'), 'utf8')).toContain('./reviewed-solc')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('accepts the solc_version alias used by the reviewed Zone router', () => {
  const root = mkdtempSync(join(tmpdir(), 'foundry-compiler-alias-'))
  try {
    writeFileSync(join(root, 'foundry.toml'), '[profile.default]\nsolc_version = "0.8.36"\n')
    writeFileSync(join(root, 'forge'), `#!/bin/sh\nprintf '%s\\n' '{"solc":"0.8.36"}'\n`)
    chmodSync(join(root, 'forge'), 0o700)
    expect(sourceVerificationCompilerArguments(root, { PATH: root })).toEqual([])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('real Forge resolves the environment-only RPC URL without credential arguments', ({
  skip,
}) => {
  const root = mkdtempSync(join(tmpdir(), 'foundry-rpc-config-'))
  try {
    writeFileSync(join(root, 'foundry.toml'), '[profile.default]\n')
    const rpcUrl = 'http://synthetic-user:synthetic-password@127.0.0.1:1'
    let output: string
    try {
      output = execFileSync('forge', ['config', '--json'], {
        cwd: root,
        encoding: 'utf8',
        env: foundryRpcEnvironment(foundryVerificationEnvironment(process.env), rpcUrl),
      })
    } catch (error) {
      // TypeScript-only CI has no Forge; an installed but broken Forge must still fail this probe.
      if (error instanceof Error && 'code' in error && error.code === 'ENOENT')
        skip('Forge is not installed; the environment helper is covered by the unit test above')
      throw error
    }
    const config = JSON.parse(output) as { eth_rpc_url: string | null }
    expect(config.eth_rpc_url).toBe(rpcUrl)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})
