import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { afterAll, afterEach, beforeAll, expect, it, vi } from 'vitest'

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
import { writeFileSync } from 'node:fs';
writeFileSync(${JSON.stringify(captured)}, JSON.stringify({
  arguments: process.argv.slice(2),
  cwd: process.cwd(),
  rpcUrl: process.env.FOUNDRY_ETH_RPC_URL,
  deployer: process.env.DEPLOYER_PRIVATE_KEY,
  authority: process.env.ZONE_ADMIN_PRIVATE_KEY,
  compiler: process.env.FOUNDRY_SOLC,
  broadcast: process.env.FOUNDRY_BROADCAST,
}));
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
  for (const path of [captured, installed, 'earn/.env', 'zone-router/.env'])
    rmSync(resolve(Config.root, path), { force: true })
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
  expect(() => releaseAddresses([])).toThrow(`Remove ${resolve(Config.earnRoot, '.env')}`)
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
