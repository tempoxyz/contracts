import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  chmodSync,
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'

import {
  assertBuildProvenanceUnchanged,
  captureBuildProvenance,
  cleanSourceRevision,
  stackManifest,
} from './provenance.js'

// Isolate only the CLI's network/deployment boundary; provenance uses real files and Git processes.
const cli = vi.hoisted(() => ({ root: '', deploy: vi.fn(), configuration: vi.fn() }))
vi.mock('./config.js', () => ({
  get root() {
    return cli.root
  },
}))
vi.mock('./devnet.js', () => ({ deploy: cli.deploy, configuration: cli.configuration }))

const roots: string[] = []
afterEach(() => {
  vi.unstubAllEnvs()
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('cleanSourceRevision', () => {
  it('uses the requested checkout and rejects modified and untracked input', () => {
    const { root, git } = checkout()
    expect(cleanSourceRevision(root)).toBe(git(root, 'rev-parse', 'HEAD'))
    writeFileSync(join(root, 'fixture.sol'), 'modified\n')
    expect(() => cleanSourceRevision(root)).toThrow('clean source checkout')
    git(root, 'checkout', '--', 'fixture.sol')
    writeFileSync(join(root, 'untracked.sol'), 'new input\n')
    expect(() => cleanSourceRevision(root)).toThrow('clean source checkout')
  })

  it.each(['earn', 'zone-router'])('rejects modified pinned %s dependency sources', (project) => {
    const { root, dependency } = checkout()
    writeFileSync(join(dependency(project), 'library.sol'), 'modified\n')
    expect(() => cleanSourceRevision(root)).toThrow('dependency')
  })

  it.each(['added.sol', 'ignored.sol'])('rejects unpublished dependency input %s', (file) => {
    const { root, dependency } = checkout()
    writeFileSync(join(dependency('earn'), file), 'new input\n')
    expect(() => cleanSourceRevision(root)).toThrow('dependency')
  })

  it('rejects a clean dependency at a different revision', () => {
    const { root, dependency, git } = checkout()
    const directory = dependency('earn')
    writeFileSync(join(directory, 'library.sol'), 'another revision\n')
    git(directory, 'add', '.')
    git(directory, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'unreviewed')
    expect(() => cleanSourceRevision(root)).toThrow('dependency')
  })

  it('rejects a missing dependency rather than accepting the parent Git checkout', () => {
    const { root, dependency } = checkout()
    rmSync(join(dependency('earn'), '.git'), { recursive: true, force: true })
    expect(() => cleanSourceRevision(root)).toThrow('dependency')
  })

  it('rejects a missing installed library', () => {
    const { root, dependency } = checkout()
    rmSync(dependency('earn'), { recursive: true, force: true })
    expect(() => cleanSourceRevision(root)).toThrow('dependency')
  })

  it('rejects a dependency symlink even when its target is at the pin', () => {
    const { root, dependency } = checkout()
    rmSync(dependency('earn'), { recursive: true, force: true })
    symlinkSync(dependency('zone-router'), dependency('earn'))
    expect(() => cleanSourceRevision(root)).toThrow('dependency')
  })

  it('accepts empty upstream submodules but refuses unpublished files in their directories', () => {
    const fixture = checkout()
    const submodule = addSubmodule(fixture)
    rmSync(submodule, { recursive: true })
    mkdirSync(submodule)
    expect(cleanSourceRevision(fixture.root)).toBe(fixture.git(fixture.root, 'rev-parse', 'HEAD'))
    writeFileSync(join(submodule, 'unexpected.sol'), 'unreviewed\n')
    expect(() => cleanSourceRevision(fixture.root)).toThrow('dependency')
  })

  it('checks populated submodule pins and ignored inputs recursively', () => {
    const fixture = checkout()
    const submodule = addSubmodule(fixture)
    expect(cleanSourceRevision(fixture.root)).toBe(fixture.git(fixture.root, 'rev-parse', 'HEAD'))
    writeFileSync(join(submodule, 'ignored.sol'), 'unreviewed\n')
    expect(() => cleanSourceRevision(fixture.root)).toThrow('dependency')
    rmSync(join(submodule, 'ignored.sol'))
    writeFileSync(join(submodule, 'library.sol'), 'another revision\n')
    fixture.git(submodule, 'add', '.')
    fixture.git(submodule, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'unpinned')
    expect(() => cleanSourceRevision(fixture.root)).toThrow('dependency')
  })

  it('rejects an unpinned library alongside locked dependencies', () => {
    const { root } = checkout()
    mkdirSync(join(root, 'earn/lib/unpinned'))
    writeFileSync(join(root, 'earn/lib/unpinned/library.sol'), 'unreviewed\n')
    expect(() => cleanSourceRevision(root)).toThrow('dependency')
  })
})

describe('captureBuildProvenance', () => {
  it('records local compiler bytes separately from the requested source revision', () => {
    const { root, git, compiler, solarRevision, binary } = checkout()
    const expected = {
      schemaVersion: 1,
      sourceRevision: git(root, 'rev-parse', 'HEAD'),
      solar: {
        path: `.solar/${solarRevision}/bin/solar`,
        requestedSourceRevision: solarRevision,
        sha256: createHash('sha256').update(binary).digest('hex'),
        authenticated: false,
      },
    }
    expect(captureBuildProvenance(root)).toEqual(expected)
    // The fake compiler is never executed, and neither its path nor version proves its origin.
    const replacement = `${binary}# modified compiler\n`
    writeFileSync(compiler, replacement)
    expect(() => captureBuildProvenance(root)).toThrow('run pnpm deps')
  })

  it.each(['missing', 'malformed', 'revision', 'digest'])(
    'refuses an installation receipt that is %s',
    (kind) => {
      const { root, receipt, solarRevision, binary } = checkout()
      if (kind === 'missing') rmSync(receipt)
      else if (kind === 'malformed') writeFileSync(receipt, '{')
      else
        writeFileSync(
          receipt,
          JSON.stringify({
            schemaVersion: 1,
            sourceRevision: kind === 'revision' ? 'ab'.repeat(20) : solarRevision,
            sha256:
              kind === 'revision'
                ? createHash('sha256').update(binary).digest('hex')
                : '00'.repeat(32),
          }),
        )
      expect(() => captureBuildProvenance(root)).toThrow('run pnpm deps')
    },
  )

  it('refuses a missing compiler before deployment', () => {
    const { root, compiler } = checkout()
    rmSync(compiler)
    expect(() => captureBuildProvenance(root)).toThrow('run pnpm deps')
  })

  it('refuses a compiler without execute permission', () => {
    const { root, compiler } = checkout()
    chmodSync(compiler, 0o600)
    expect(() => captureBuildProvenance(root)).toThrow('run pnpm deps')
  })
})

describe('assertBuildProvenanceUnchanged', () => {
  it('accepts unchanged inputs and refuses replaced compiler bytes', () => {
    const { root, compiler } = checkout()
    const before = captureBuildProvenance(root)
    expect(() => assertBuildProvenanceUnchanged(root, before)).not.toThrow()
    writeFileSync(compiler, '#!/bin/sh\nexit 1\n')
    expect(() => assertBuildProvenanceUnchanged(root, before)).toThrow('run pnpm deps')
  })

  it('refuses changed dependency sources before emitting a success record', () => {
    const { root, dependency } = checkout()
    const before = captureBuildProvenance(root)
    writeFileSync(join(dependency('zone-router'), 'library.sol'), 'modified\n')
    expect(() => assertBuildProvenanceUnchanged(root, before)).toThrow('dependency')
  })

  it('refuses a different clean repository revision', () => {
    const { root, git } = checkout()
    const before = captureBuildProvenance(root)
    writeFileSync(join(root, 'fixture.sol'), 'another revision\n')
    git(root, 'add', '.')
    git(root, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'changed revision')
    expect(() => assertBuildProvenanceUnchanged(root, before)).toThrow('build inputs changed')
  })
})

describe('devnet deployment provenance boundary', () => {
  it('refuses dirty ignored dependency input before resolving credentials or deploying', async () => {
    const { root, dependency } = checkout()
    writeFileSync(join(dependency('earn'), 'library.sol'), 'modified\n')
    await expect(runCli(root)).rejects.toThrow('dependency')
    expect(cli.configuration).not.toHaveBeenCalled()
    expect(cli.deploy).not.toHaveBeenCalled()
    expect(existsSync(join(root, '.solar/install.json'))).toBe(false)
    expect(readFileSync(join(dependency('earn'), 'library.sol'), 'utf8')).toBe('modified\n')
  })

  it.each(['substituted', 'unreceipted'])(
    'rebuilds a %s compiler before capturing or resolving credentials',
    async (kind) => {
      const { root, compiler, receipt, freshBinary } = checkout()
      if (kind === 'substituted') writeFileSync(compiler, 'substituted before capture')
      else rmSync(receipt)
      const directory = await runCli(root)
      expect(readFileSync(compiler, 'utf8')).toBe(freshBinary)
      expect(
        JSON.parse(readFileSync(join(directory, 'earn-build-provenance.json'), 'utf8')),
      ).toEqual(captureBuildProvenance(root))
      expect(cli.configuration).toHaveBeenCalledOnce()
      expect(cli.deploy).toHaveBeenCalledOnce()
    },
  )

  it('installs missing Earn, Zone and compiler inputs through a credential-free child before configuration', async () => {
    const { root, compiler, receipt } = checkout()
    rmSync(join(root, 'earn/lib'), { recursive: true })
    rmSync(join(root, 'zone-router/lib'), { recursive: true })
    rmSync(compiler)
    rmSync(receipt)
    vi.stubEnv('DEPLOYER_PRIVATE_KEY', 'synthetic-deployer')
    vi.stubEnv('ZONE_ADMIN_PRIVATE_KEY', 'synthetic-authority')
    vi.stubEnv('TEMPO_RPC_URL', 'https://synthetic-rpc-secret.example')
    vi.stubEnv('FOUNDRY_SOLC', '/unreviewed-compiler')
    await runCli(root)
    expect(JSON.parse(readFileSync(join(root, '.solar/install.json'), 'utf8'))).toEqual({
      projects: ['earn', 'zone-router'],
      leaked: {},
    })
    expect(() => captureBuildProvenance(root)).not.toThrow()
    expect(cli.configuration).toHaveBeenCalledOnce()
  })

  it('refuses unpinned installed libraries before the installer can replace them', async () => {
    const { root, dependency, git } = checkout()
    const directory = dependency('zone-router')
    writeFileSync(join(directory, 'library.sol'), 'unreviewed revision\n')
    git(directory, 'add', '.')
    git(directory, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'unreviewed')
    await expect(runCli(root)).rejects.toThrow('dependency')
    expect(existsSync(join(root, '.solar/install.json'))).toBe(false)
    expect(readFileSync(join(directory, 'library.sol'), 'utf8')).toBe('unreviewed revision\n')
    expect(cli.configuration).not.toHaveBeenCalled()
    expect(cli.deploy).not.toHaveBeenCalled()
  })

  it.each(['fail-install', 'skip-install'])(
    'refuses %s before configuration or deployment',
    async (failure) => {
      const { root, dependency } = checkout()
      rmSync(dependency('earn'), { recursive: true })
      writeFileSync(join(root, '.solar', failure), 'true')
      await expect(runCli(root)).rejects.toThrow()
      expect(cli.configuration).not.toHaveBeenCalled()
      expect(cli.deploy).not.toHaveBeenCalled()
    },
  )

  it('writes source and compiler evidence alongside the existing address outputs', async () => {
    const { root } = checkout()
    const directory = await runCli(root)
    const provenance = captureBuildProvenance(root)
    expect(JSON.parse(readFileSync(join(directory, 'earn-build-provenance.json'), 'utf8'))).toEqual(
      provenance,
    )
    expect(readFileSync(join(directory, 'earn-source-revision'), 'utf8')).toBe(
      provenance.sourceRevision,
    )
    for (const name of [
      'earn-input-token',
      'earn-funding-helper',
      'earn-token',
      'earn-vault',
      'earn-router',
    ])
      expect(readFileSync(join(directory, name), 'utf8')).toBe(
        '0x1111111111111111111111111111111111111111',
      )
    expect(cli.deploy).toHaveBeenCalledOnce()
  })

  it('certifies an unignored output directory inside the source checkout', async () => {
    const { root, git } = checkout()
    const provenance = captureBuildProvenance(root)
    const directory = join(root, 'outputs')
    await runCli(root, undefined, directory)
    expect(cli.deploy).toHaveBeenCalledOnce()
    expect(JSON.parse(readFileSync(join(directory, 'earn-build-provenance.json'), 'utf8'))).toEqual(
      provenance,
    )
    expect(readFileSync(join(directory, 'earn-source-revision'), 'utf8')).toBe(
      provenance.sourceRevision,
    )
    expect(git(root, 'status', '--porcelain', '--untracked-files=all')).toContain(
      '?? outputs/earn-router',
    )
    for (const name of [
      'earn-input-token',
      'earn-funding-helper',
      'earn-token',
      'earn-vault',
      'earn-router',
    ])
      expect(readFileSync(join(directory, name), 'utf8')).toBe(
        '0x1111111111111111111111111111111111111111',
      )
  })

  it.each(['source', 'dependency', 'compiler'] as const)(
    'preserves unignored recovery addresses without certifying changed %s inputs',
    async (input) => {
      const { root, compiler, dependency } = checkout()
      const directory = join(root, 'outputs')
      const path = {
        source: join(root, 'fixture.sol'),
        dependency: join(dependency('zone-router'), 'library.sol'),
        compiler,
      }[input]!
      const message = {
        source: 'clean source checkout',
        dependency: 'dependency sources must be clean and pinned',
        compiler: 'run pnpm deps',
      }[input]!
      await expect(runCli(root, () => writeFileSync(path, 'changed'), directory)).rejects.toThrow(
        message,
      )
      expect(cli.deploy).toHaveBeenCalledOnce()
      for (const name of ['earn-build-provenance.json', 'earn-source-revision'])
        expect(existsSync(join(directory, name))).toBe(false)
      for (const name of [
        'earn-input-token',
        'earn-funding-helper',
        'earn-token',
        'earn-vault',
        'earn-router',
      ])
        expect(readFileSync(join(directory, name), 'utf8')).toBe(
          '0x1111111111111111111111111111111111111111',
        )
    },
  )

  it.each([false, true])(
    'preserves recovery addresses but no certification after compiler changes (reused directory: %s)',
    async (reused) => {
      const { root, compiler } = checkout()
      const directory = join(root, '.solar/outputs')
      if (reused) {
        await runCli(root)
        writeFileSync(join(directory, 'earn-token'), 'previous deployment')
        expect(existsSync(join(directory, 'earn-build-provenance.json'))).toBe(true)
      }
      await expect(runCli(root, () => writeFileSync(compiler, 'changed'))).rejects.toThrow(
        'run pnpm deps',
      )
      expect(cli.deploy).toHaveBeenCalledOnce()
      for (const name of ['earn-build-provenance.json', 'earn-source-revision'])
        expect(existsSync(join(directory, name))).toBe(false)
      for (const name of [
        'earn-input-token',
        'earn-funding-helper',
        'earn-token',
        'earn-vault',
        'earn-router',
      ])
        expect(readFileSync(join(directory, name), 'utf8')).toBe(
          '0x1111111111111111111111111111111111111111',
        )
    },
  )

  it('clears old certification before calling a deployment that fails', async () => {
    const { root } = checkout()
    const directory = await runCli(root)
    await expect(
      runCli(root, () => {
        throw new Error('deployment failed')
      }),
    ).rejects.toThrow('deployment failed')
    for (const name of ['earn-build-provenance.json', 'earn-source-revision'])
      expect(existsSync(join(directory, name))).toBe(false)
  })
})

describe('stackManifest', () => {
  it('removes userinfo and all path, query, and fragment material without changing runtime URLs', () => {
    const stack = {
      id: 'devnet',
      network: {
        rpcUrl: 'https://alice:password@l1.example/v2/path-key?apikey=query-key#secret',
        zone: { id: 7, rpcUrl: 'https://zone.example:8545/unrecognized-secret?custom=secret' },
      },
    }
    const manifest = stackManifest(stack)
    expect(manifest).toEqual({
      id: 'devnet',
      network: {
        rpcUrl: 'https://l1.example',
        zone: { id: 7, rpcUrl: 'https://zone.example:8545' },
      },
    })
    expect(stack.network.rpcUrl).toContain('password')
    expect(stack.network.zone.rpcUrl).toContain('unrecognized-secret')
  })
})

function checkout() {
  const root = mkdtempSync(join(tmpdir(), 'fixture-provenance-'))
  roots.push(root)
  const git = (cwd: string, ...args: string[]) =>
    execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()
  const init = (directory: string) => {
    git(directory, 'init', '--quiet')
    git(directory, 'config', 'user.name', 'Fixture test')
    git(directory, 'config', 'user.email', 'fixture@example.test')
  }
  init(root)
  writeFileSync(join(root, '.gitignore'), '*/lib/\n.solar/\n')
  writeFileSync(join(root, 'fixture.sol'), 'original\n')
  const dependency = (project: string) => join(root, project, 'lib/fixture')
  for (const project of ['earn', 'zone-router']) {
    const directory = dependency(project)
    mkdirSync(directory, { recursive: true })
    init(directory)
    writeFileSync(join(directory, '.gitignore'), 'ignored.sol\n')
    writeFileSync(join(directory, 'library.sol'), 'original\n')
    git(directory, 'add', '.')
    git(directory, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'library')
    writeFileSync(
      join(root, project, 'foundry.lock'),
      JSON.stringify({ 'lib/fixture': { tag: { rev: git(directory, 'rev-parse', 'HEAD') } } }),
    )
  }
  const solarRevision = 'd8'.repeat(20)
  writeFileSync(join(root, 'earn/solar.lock'), `${solarRevision}\n`)
  const compiler = join(root, '.solar', solarRevision, 'bin/solar')
  mkdirSync(join(root, '.solar', solarRevision, 'bin'), { recursive: true })
  const binary = '#!/bin/sh\necho local-unverified-compiler\nexit 1\n'
  writeFileSync(compiler, binary, { mode: 0o700 })
  const receipt = join(root, '.solar', solarRevision, 'install-receipt.json')
  writeFileSync(
    receipt,
    JSON.stringify({
      schemaVersion: 1,
      sourceRevision: solarRevision,
      sha256: createHash('sha256').update(binary).digest('hex'),
    }),
  )
  // This subprocess substitutes only fetching/building inputs; strict provenance still uses real Git and files.
  for (const project of ['earn', 'zone-router'])
    cpSync(dependency(project), join(root, '.solar/seed', project), { recursive: true })
  const freshBinary = '#!/bin/sh\necho freshly-built-fixture-compiler\n'
  mkdirSync(join(root, 'scripts'))
  writeFileSync(
    join(root, 'scripts/solidity-deps.sh'),
    `#!/usr/bin/env node
const { createHash } = require('node:crypto');
const { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } = require('node:fs');
const { resolve } = require('node:path');
const root = process.cwd();
const projects = process.argv.slice(2);
const names = ['DEPLOYER_PRIVATE_KEY', 'ZONE_ADMIN_PRIVATE_KEY', 'TEMPO_RPC_URL', 'FOUNDRY_SOLC'];
writeFileSync(resolve(root, '.solar/install.json'), JSON.stringify({
  projects, leaked: Object.fromEntries(names.flatMap(name => process.env[name] ? [[name, process.env[name]]] : [])),
}));
if (existsSync(resolve(root, '.solar/fail-install'))) process.exit(33);
if (existsSync(resolve(root, '.solar/skip-install'))) process.exit(0);
for (const project of projects) {
  const target = resolve(root, project, 'lib/fixture');
  if (!existsSync(target)) cpSync(resolve(root, '.solar/seed', project), target, { recursive: true });
}
const compiler = ${JSON.stringify(compiler)};
const receipt = ${JSON.stringify(receipt)};
const revision = ${JSON.stringify(solarRevision)};
let valid = false;
try {
  const installed = JSON.parse(readFileSync(receipt, 'utf8'));
  valid = installed.sourceRevision === revision && installed.sha256 === createHash('sha256').update(readFileSync(compiler)).digest('hex');
} catch {}
if (!valid) {
  const binary = ${JSON.stringify(freshBinary)};
  writeFileSync(compiler, binary, { mode: 0o700 });
  writeFileSync(receipt, JSON.stringify({ schemaVersion: 1, sourceRevision: revision, sha256: createHash('sha256').update(binary).digest('hex') }));
}
`,
    { mode: 0o700 },
  )
  git(root, 'add', '.')
  git(root, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
  return { root, dependency, git, compiler, solarRevision, binary, freshBinary, receipt }
}

async function runCli(
  root: string,
  duringDeploy?: () => void,
  directory = join(root, '.solar/outputs'),
) {
  cli.root = root
  cli.configuration.mockReset().mockImplementation(() => {
    // Missing installation or capture after key resolution would fail this boundary assertion.
    expect(existsSync(join(root, '.solar/install.json'))).toBe(true)
    captureBuildProvenance(root)
    return { privateKeys: { deployer: `0x${'11'.repeat(32)}` } }
  })
  cli.deploy.mockReset().mockImplementation(async () => {
    duringDeploy?.()
    const address = '0x1111111111111111111111111111111111111111'
    return {
      alternateAsset: address,
      stablecoinFixture: address,
      earnShare: address,
      earnVault: address,
      earnRouter: address,
    }
  })
  const argv = process.argv
  const log = vi.spyOn(console, 'log').mockImplementation(() => {})
  process.argv = [
    argv[0]!,
    'devnet-deploy.ts',
    '--out',
    directory,
    '--eligible-account',
    '0x1111111111111111111111111111111111111111',
  ]
  try {
    vi.resetModules()
    await import('./devnet-deploy.js')
    return directory
  } finally {
    process.argv = argv
    log.mockRestore()
  }
}

function addSubmodule({ root, dependency, git }: ReturnType<typeof checkout>) {
  const directory = dependency('earn')
  const submodule = join(directory, 'vendor/child')
  mkdirSync(submodule, { recursive: true })
  git(submodule, 'init', '--quiet')
  git(submodule, 'config', 'user.name', 'Fixture test')
  git(submodule, 'config', 'user.email', 'fixture@example.test')
  writeFileSync(join(submodule, '.gitignore'), 'ignored.sol\n')
  writeFileSync(join(submodule, 'library.sol'), 'original\n')
  git(submodule, 'add', '.')
  git(submodule, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'submodule')
  git(
    directory,
    'update-index',
    '--add',
    '--cacheinfo',
    `160000,${git(submodule, 'rev-parse', 'HEAD')},vendor/child`,
  )
  git(directory, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'submodule pin')
  writeFileSync(
    join(root, 'earn/foundry.lock'),
    JSON.stringify({ 'lib/fixture': { rev: git(directory, 'rev-parse', 'HEAD') } }),
  )
  git(root, 'add', '.')
  git(root, '-c', 'commit.gpgsign=false', 'commit', '-qm', 'library pin')
  return submodule
}
