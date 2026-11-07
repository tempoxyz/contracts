import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'

import * as Config from './config.js'
import { executable } from './card-runtime.js'

const provenance = JSON.parse(
  readFileSync(resolve(Config.root, 'localnet/fixtures/card-runtime-provenance.json'), 'utf8'),
)
const sha256 = (value: Buffer) => createHash('sha256').update(value).digest('hex')
const vendor = resolve(Config.root, 'cards/vendor/tempo-zones/src/runtime')
for (const [path, digest] of Object.entries(provenance.vendor.sources))
  assert.equal(sha256(readFileSync(resolve(vendor, path))), digest, `Unreviewed vendor ${path}`)
const std = resolve(Config.root, 'cards/lib/tempo-std')
assert.equal(
  execFileSync('git', ['rev-parse', 'HEAD'], { cwd: std, encoding: 'utf8' }).trim(),
  provenance.vendor.tempoStdCommit,
)
assert.equal(
  execFileSync('git', ['status', '--porcelain', '--untracked-files=all', '--ignored'], {
    cwd: std,
    encoding: 'utf8',
  }).trim(),
  '',
  'tempo-std must have no unpublished inputs',
)
const fixtureBytes = readFileSync(
  resolve(Config.root, 'localnet/fixtures', Config.runtimeLock.runtimeFixture),
)
assert.equal(sha256(fixtureBytes), Config.runtimeLock.runtimeFixtureSha256)
const fixture = JSON.parse(fixtureBytes.toString('utf8'))
const directory = mkdtempSync(resolve(tmpdir(), 'card-runtime-'))
try {
  cpSync(vendor, resolve(directory, 'src'), { recursive: true })
  mkdirSync(resolve(directory, 'lib'), { recursive: true })
  cpSync(resolve(std, 'src'), resolve(directory, 'lib/tempo-std/src'), { recursive: true })
  writeFileSync(
    resolve(directory, 'foundry.toml'),
    `[profile.default]
src = 'src'
solc_version = '0.8.35'
evm_version = 'osaka'
via_ir = true
optimizer = true
optimizer_runs = 200
auto_detect_remappings = false
remappings = ['tempo-std/=lib/tempo-std/src/']
`,
  )
  // No caller Foundry overrides or signing credentials enter this isolated read-only rebuild.
  execFileSync('forge', ['build', '--skip', 'test', '--skip', 'script'], {
    cwd: directory,
    env: { PATH: process.env.PATH, HOME: process.env.HOME },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  for (const [contract, field] of [
    ['ZonePortal', 'zonePortal'],
    ['ZoneMessenger', 'zoneMessenger'],
    ['Verifier', 'verifier'],
  ]) {
    const artifact = JSON.parse(
      readFileSync(resolve(directory, `out/${contract}.sol/${contract}.json`), 'utf8'),
    )
    const built = executable(artifact.deployedBytecode.object)
    assert.equal(built, executable(fixture[field!]), `${contract} executable mismatch`)
    console.log(
      JSON.stringify({
        contract,
        compiler: '0.8.35',
        evmVersion: 'osaka',
        executableBytes: (built.length - 2) / 2,
        executableSha256: sha256(Buffer.from(built.slice(2), 'hex')),
        matchesLockedRuntime: true,
      }),
    )
  }
} finally {
  rmSync(directory, { recursive: true, force: true })
}
