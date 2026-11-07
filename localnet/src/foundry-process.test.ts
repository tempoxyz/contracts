import { execFileSync, spawnSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { resolve } from 'node:path'
import { afterAll, afterEach, beforeAll, expect, it, vi } from 'vitest'

import { planFactoryRelease, predictRelease } from '@tempoxyz/contracts/deployments/node'
import type { Hex } from 'viem'

import * as Config from './config.js'
import { releaseAddresses, run, runLifecycleStep } from './foundry.js'

// Map the checkout into an isolated directory; exercise actual child processes without launching Forge.
vi.mock('./config.js', async (importOriginal) => {
  const config = await importOriginal<typeof import('./config.js')>()
  const { mkdtempSync } = await import('node:fs')
  const { tmpdir } = await import('node:os')
  const { resolve } = await import('node:path')
  const root = mkdtempSync(resolve(tmpdir(), 'localnet-foundry-'))
  return { ...config, root, earnRoot: resolve(root, 'earn') }
})

const runRoot = resolve(Config.root, 'run')
const broadcastDirectory = resolve(runRoot, 'broadcast')
const captured = resolve(Config.root, 'invocation.json')
const installed = resolve(Config.root, 'dependencies-called')
const history = resolve(Config.root, 'invocations.jsonl')
const nativeEnvironment = {
  PATH: process.env.PATH,
  HOME: process.env.HOME,
  FOUNDRY_PROFILE: 'deploy',
}
const solc = resolve(homedir(), '.svm/0.8.36/solc-0.8.36')
// The process probes above need no installed toolchain; this additional check never downloads one.
const nativeAvailable =
  existsSync(solc) && spawnSync('forge', ['--version'], { env: nativeEnvironment }).status === 0
const networkEnvironment = {
  HTTP_PROXY: 'http://upper-http.example:8080',
  HTTPS_PROXY: 'http://upper-https.example:8080',
  ALL_PROXY: 'socks5://upper-all.example:1080',
  NO_PROXY: 'localhost,127.0.0.1,.internal.example',
  http_proxy: 'http://lower-http.example:8081',
  https_proxy: 'http://lower-https.example:8081',
  all_proxy: 'socks5://lower-all.example:1081',
  no_proxy: '',
  SSL_CERT_FILE: '/trust/root.pem',
  SSL_CERT_DIR: '/trust/roots',
  GIT_SSL_CAINFO: '/trust/git.pem',
  GIT_SSL_CAPATH: '/trust/git',
  GIT_PROXY_SSL_CAINFO: '/trust/git-proxy.pem',
  CARGO_HTTP_PROXY: 'http://cargo.example:8080',
  CARGO_HTTP_CAINFO: '/trust/cargo.pem',
  CARGO_HTTP_PROXY_CAINFO: '/trust/cargo-proxy.pem',
}
const excludedEnvironment = {
  DEPLOYER_PRIVATE_KEY: 'synthetic-deployer',
  ZONE_ADMIN_PRIVATE_KEY: 'synthetic-authority',
  ENGINE_OWNER_PRIVATE_KEY: 'synthetic-owner',
  TEMPO_RPC_URL: 'https://user:synthetic-password@rpc.example',
  CARGO_REGISTRIES_PRIVATE_TOKEN: 'synthetic-token',
  FOUNDRY_PROFILE: 'unreviewed',
  FOUNDRY_SOLC: '/unreviewed',
  RUSTFLAGS: '--cfg unreviewed',
  GIT_SSL_NO_VERIFY: 'true',
  CARGO_HTTP_SSL_VERIFY: 'false',
}

beforeAll(() => {
  for (const name of ['earn', 'zone-router', 'run/broadcast', 'bin', 'scripts'])
    mkdirSync(resolve(Config.root, name), { recursive: true })
  const forge = resolve(Config.root, 'bin/forge')
  writeFileSync(
    forge,
    `#!/usr/bin/env node
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
// Model only Forge's build-directory boundary: existing output plus cache can skip compilation.
const out = process.env.FOUNDRY_OUT ?? resolve('out/deploy');
const cache = process.env.FOUNDRY_CACHE_PATH ?? resolve('cache/deploy');
const artifact = resolve(out, 'bytecode');
const index = resolve(cache, 'index');
const reused = existsSync(artifact) && existsSync(index);
if (!reused) {
  mkdirSync(out, { recursive: true });
  mkdirSync(cache, { recursive: true });
  writeFileSync(artifact, '0x6001');
  writeFileSync(index, 'compiled');
}
const bytecode = readFileSync(artifact, 'utf8');
const invocation = {
  arguments: process.argv.slice(2),
  cwd: process.cwd(),
  rpcUrl: process.env.FOUNDRY_ETH_RPC_URL,
  deployer: process.env.DEPLOYER_PRIVATE_KEY,
  authority: process.env.ZONE_ADMIN_PRIVATE_KEY,
  compiler: process.env.FOUNDRY_SOLC,
  broadcast: process.env.FOUNDRY_BROADCAST,
  out,
  cache,
  reused,
  bytecode,
};
writeFileSync(${JSON.stringify(captured)}, JSON.stringify(invocation));
appendFileSync(${JSON.stringify(history)}, JSON.stringify(invocation) + '\\n');
if (process.argv[2] === 'inspect') process.stdout.write(bytecode);
`,
  )
  chmodSync(forge, 0o700)
  const dependencies = resolve(Config.root, 'scripts/solidity-deps.sh')
  writeFileSync(
    dependencies,
    `#!/bin/sh
node --input-type=module <<'PROBE'
import { writeFileSync } from 'node:fs';
// Capture only synthetic test values, never the real host environment.
const inputs = ${JSON.stringify({ ...networkEnvironment, ...excludedEnvironment })};
writeFileSync(${JSON.stringify(installed)}, JSON.stringify(Object.fromEntries(
  Object.entries(inputs).filter(([name, value]) => process.env[name] === value),
)));
PROBE
`,
  )
  chmodSync(dependencies, 0o700)
})

afterEach(() => {
  vi.unstubAllEnvs()
  for (const path of [captured, history, installed, 'earn/.env', 'zone-router/.env', 'run/build'])
    rmSync(resolve(Config.root, path), { force: true, recursive: true })
})
afterAll(() => rmSync(Config.root, { recursive: true, force: true }))

it.each(['earn', 'zone-router'])(
  'refuses dotenv in the mapped %s project before dependencies or Forge run',
  (project) => {
    writeFileSync(
      resolve(Config.root, project, '.env'),
      'ZONE_ADMIN_PRIVATE_KEY=synthetic-authority\nFOUNDRY_SOLC=/unreviewed\n',
    )
    vi.stubEnv('PATH', `${resolve(Config.root, 'bin')}:${process.env.PATH}`)
    expect(() =>
      runLifecycleStep(
        {
          action: { id: 'deploy-fixture' },
          root: project === 'earn' ? runRoot : resolve(runRoot, '..', project),
          arguments: ['script', 'DeployFixture'],
          environment: { PATH: process.env.PATH! },
          rawGasEstimate: false,
        },
        broadcastDirectory,
      ),
    ).toThrow(`Remove ${resolve(Config.root, project, '.env')}`)
    expect(existsSync(captured)).toBe(false)
    expect(existsSync(installed)).toBe(false)
  },
)

it('refuses release inspection dotenv before dependencies or compilation', () => {
  writeFileSync(resolve(Config.earnRoot, '.env'), 'FOUNDRY_SOLC=/unreviewed\n')
  expect(() => releaseAddresses([], broadcastDirectory)).toThrow(
    `Remove ${resolve(Config.earnRoot, '.env')}`,
  )
  expect(existsSync(captured)).toBe(false)
  expect(existsSync(installed)).toBe(false)
})

it('passes proxy and CA settings to the actual dependency child without authority or build overrides', () => {
  vi.stubEnv('PATH', `${resolve(Config.root, 'bin')}:${process.env.PATH}`)
  for (const [name, value] of Object.entries({ ...networkEnvironment, ...excludedEnvironment }))
    vi.stubEnv(name, value)
  runLifecycleStep(
    {
      action: { id: 'deploy-router' },
      root: resolve(runRoot, '..', 'zone-router'),
      arguments: ['script', 'DeployFixture'],
      environment: { PATH: process.env.PATH! },
      rawGasEstimate: false,
    },
    broadcastDirectory,
  )
  expect(JSON.parse(readFileSync(installed, 'utf8'))).toEqual(networkEnvironment)
})

it('carries a credential-bearing fixture RPC only through the actual child environment', async () => {
  vi.stubEnv('PATH', `${resolve(Config.root, 'bin')}:${process.env.PATH}`)
  vi.stubEnv('ZONE_ADMIN_PRIVATE_KEY', 'synthetic-authority')
  vi.stubEnv('FOUNDRY_SOLC', '/unreviewed')
  const rpcUrl = 'https://user:synthetic-password@rpc.example/private-path?key=synthetic-query'
  const privateKey = `0x${'11'.repeat(32)}` as const
  // The process probe deliberately emits no transaction: successful execution is not a receipt.
  await expect(
    run({
      broadcastDirectory,
      chainId: 1337,
      client: {} as never,
      privateKey,
      rpcUrl,
      step: { name: 'DeployFixture.deploy', target: 'DeployFixture.s.sol', calldata: '0x12345678' },
    }),
  ).rejects.toThrow('Forge did not write a new broadcast transaction')
  const invocation = JSON.parse(readFileSync(captured, 'utf8'))
  expect(invocation.arguments).not.toContain('--rpc-url')
  expect(JSON.stringify(invocation.arguments)).not.toContain('synthetic')
  expect(invocation).toMatchObject({
    cwd: Config.earnRoot,
    rpcUrl,
    deployer: privateKey,
    broadcast: broadcastDirectory,
  })
  expect(invocation).not.toHaveProperty('authority')
  expect(invocation).not.toHaveProperty('compiler')
})

it('preserves the lifecycle RPC and profile-scoped broadcast directory at the mapped project', () => {
  const rpcUrl = 'https://rpc.example/private-path?key=synthetic-query'
  const scopedBroadcast = resolve(broadcastDirectory, 'profile-hash')
  runLifecycleStep(
    {
      action: { id: 'deploy-engine' },
      root: runRoot,
      arguments: ['script', 'DeployFixture'],
      environment: {
        PATH: `${resolve(Config.root, 'bin')}:${process.env.PATH}`,
        FOUNDRY_ETH_RPC_URL: rpcUrl,
        FOUNDRY_BROADCAST: scopedBroadcast,
      },
      rawGasEstimate: false,
    },
    broadcastDirectory,
  )
  const invocation = JSON.parse(readFileSync(captured, 'utf8'))
  expect(invocation).toMatchObject({
    cwd: Config.earnRoot,
    rpcUrl,
    broadcast: scopedBroadcast,
  })
  expect(JSON.stringify(invocation.arguments)).not.toContain('synthetic')
})

it('keeps inspection, fixture scripts and sibling lifecycle builds off stale output and cache overrides', async () => {
  vi.stubEnv('PATH', `${resolve(Config.root, 'bin')}:${process.env.PATH}`)
  const stale = [
    ['earn/out/deploy', 'earn/cache/deploy'],
    ['zone-router/out/deploy', 'zone-router/cache/deploy'],
    ['override/out', 'override/cache'],
  ]
  for (const [out, cache] of stale) {
    mkdirSync(resolve(Config.root, out!), { recursive: true })
    mkdirSync(resolve(Config.root, cache!), { recursive: true })
    writeFileSync(resolve(Config.root, out!, 'bytecode'), '0xdead')
    writeFileSync(resolve(Config.root, cache!, 'index'), 'stale compiler')
  }
  const overrides = {
    FOUNDRY_OUT: resolve(Config.root, 'override/out'),
    FOUNDRY_CACHE_PATH: resolve(Config.root, 'override/cache'),
  }
  for (const [name, value] of Object.entries(overrides)) vi.stubEnv(name, value)

  releaseAddresses([], broadcastDirectory)
  const inspected = JSON.parse(readFileSync(history, 'utf8').trim().split('\n')[0]!)
  expect(inspected).toMatchObject({
    cwd: Config.earnRoot,
    out: resolve(runRoot, 'build/earn/out'),
    cache: resolve(runRoot, 'build/earn/cache'),
    reused: false,
    bytecode: '0x6001',
  })
  await expect(
    run({
      broadcastDirectory,
      chainId: 1337,
      client: {} as never,
      privateKey: `0x${'11'.repeat(32)}`,
      rpcUrl: 'http://rpc.example',
      step: { name: 'DeployFixture.deploy', target: 'DeployFixture.s.sol', calldata: '0x12345678' },
    }),
  ).rejects.toThrow('Forge did not write a new broadcast transaction')
  expect(JSON.parse(readFileSync(captured, 'utf8'))).toMatchObject({
    out: inspected.out,
    cache: inspected.cache,
    reused: true,
    bytecode: '0x6001',
  })
  for (const project of ['earn', 'zone-router']) {
    for (const attempt of [0, 1]) {
      runLifecycleStep(
        {
          action: { id: 'deploy-fixture' },
          root: project === 'earn' ? runRoot : resolve(runRoot, '..', project),
          arguments: ['script', 'DeployFixture'],
          environment: { PATH: process.env.PATH!, ...overrides },
          rawGasEstimate: false,
        },
        broadcastDirectory,
      )
      expect(JSON.parse(readFileSync(captured, 'utf8'))).toMatchObject({
        cwd: resolve(Config.root, project),
        out: resolve(runRoot, 'build', project, 'out'),
        cache: resolve(runRoot, 'build', project, 'cache'),
        reused: project === 'earn' || attempt > 0,
        bytecode: '0x6001',
      })
    }
  }
  // Nothing cleans, overwrites, or adopts a developer's unrelated build state.
  for (const [out, cache] of stale) {
    expect(readFileSync(resolve(Config.root, out!, 'bytecode'), 'utf8')).toBe('0xdead')
    expect(readFileSync(resolve(Config.root, cache!, 'index'), 'utf8')).toBe('stale compiler')
  }
})

it('never shares artifact or cache state between run directories', () => {
  vi.stubEnv('PATH', `${resolve(Config.root, 'bin')}:${process.env.PATH}`)
  releaseAddresses([], broadcastDirectory)
  const first = JSON.parse(readFileSync(captured, 'utf8'))
  writeFileSync(resolve(first.out, 'bytecode'), '0xdead')
  const nextBroadcast = resolve(Config.root, 'another-run/broadcast')
  releaseAddresses([], nextBroadcast)
  const second = JSON.parse(readFileSync(captured, 'utf8'))
  expect(second.out).not.toBe(first.out)
  expect(second.cache).not.toBe(first.cache)
  expect(second.bytecode).toBe('0x6001')
  expect(readFileSync(resolve(first.out, 'bytecode'), 'utf8')).toBe('0xdead')
})

it.skipIf(!nativeAvailable)(
  'real Forge ignores poisoned checkout artifacts while retaining them for their owner',
  () => {
    vi.stubEnv('PATH', nativeEnvironment.PATH)
    const plan = planFactoryRelease('core', 0)
    mkdirSync(resolve(Config.earnRoot, 'src/core'), { recursive: true })
    writeFileSync(
      resolve(Config.earnRoot, 'foundry.toml'),
      `
[profile.default]
solc = ${JSON.stringify(solc)}
[profile.deploy]
out = "out/deploy"
cache_path = "cache/deploy"
`,
    )
    for (const { name } of plan.contracts)
      writeFileSync(
        resolve(Config.earnRoot, 'src/core', `${name}.sol`),
        `
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
contract ${name} { function value() external pure returns (uint256) { return 42; } }
`,
      )
    const forge = (...args: string[]) =>
      execFileSync('forge', args, {
        cwd: Config.earnRoot,
        env: nativeEnvironment,
        encoding: 'utf8',
      }).trim()
    forge('build')
    const bytecodes = Object.fromEntries(
      plan.contracts.map(({ contract }) => [
        contract,
        forge('inspect', contract, 'bytecode') as Hex,
      ]),
    )
    const expected = Object.fromEntries(
      predictRelease(plan, (contract) => bytecodes[contract]!).map(({ name, address }) => [
        name,
        address,
      ]),
    )
    const poisoned = resolve(Config.earnRoot, 'out/deploy/EarnVault.sol/EarnVault.json')
    const artifact = JSON.parse(readFileSync(poisoned, 'utf8'))
    artifact.bytecode.object = '0xdead'
    writeFileSync(poisoned, JSON.stringify(artifact))
    // Prove the stale-cache failure with the real binary, not the probe's model of reuse.
    expect(forge('inspect', 'src/core/EarnVault.sol:EarnVault', 'bytecode')).toBe('0xdead')
    vi.stubEnv('FOUNDRY_OUT', resolve(Config.earnRoot, 'out/deploy'))
    vi.stubEnv('FOUNDRY_CACHE_PATH', resolve(Config.earnRoot, 'cache/deploy'))
    expect(releaseAddresses([], broadcastDirectory)).toEqual(expected)
    const fresh = JSON.parse(
      readFileSync(resolve(runRoot, 'build/earn/out/EarnVault.sol/EarnVault.json'), 'utf8'),
    )
    expect(fresh.bytecode.object).toBe(bytecodes['src/core/EarnVault.sol:EarnVault'])
    expect(JSON.parse(readFileSync(poisoned, 'utf8')).bytecode.object).toBe('0xdead')
  },
)
