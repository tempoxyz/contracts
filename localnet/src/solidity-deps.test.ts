import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

const roots: string[] = []
const revision = 'd8'.repeat(20)
const target = 'x86_64-unknown-linux-musl'
const installedBytes = '#!/bin/sh\necho released-solar\n'
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('solidity-deps solar installation', () => {
  it('installs the checksummed release binary and records its digest', () => {
    const fixture = setup()
    const result = fixture.install()
    expect(result.status, result.stderr).toBe(0)
    expect(fixture.calls()).toHaveLength(1)
    expect(fixture.calls()[0]).toContain(
      `https://github.com/paradigmxyz/solar/releases/download/v9.9.9/solar-${target}.tar.gz`,
    )
    expect(readFileSync(fixture.binary, 'utf8')).toBe(installedBytes)
    expect(JSON.parse(readFileSync(fixture.receipt, 'utf8'))).toEqual({
      schemaVersion: 3,
      sourceRevision: revision,
      sha256: createHash('sha256').update(installedBytes).digest('hex'),
    })
    expect(readdirSync(join(fixture.root, '.solar'))).toEqual([revision])
  })

  it('refuses an archive whose checksum differs from solar-releases.json', () => {
    const fixture = setup({ tampered: true })
    const result = fixture.install()
    expect(result.status).not.toBe(0)
    expect(result.stderr).toContain('does not match solar-releases.json')
    expect(existsSync(fixture.binary)).toBe(false)
    expect(readdirSync(join(fixture.root, '.solar'))).toEqual([])
  })

  it('refuses a revision solar-releases.json does not list', () => {
    const fixture = setup({ listed: false })
    const result = fixture.install()
    expect(result.status).not.toBe(0)
    expect(result.stderr).toContain('lists no')
    expect(fixture.calls()).toEqual([])
  })

  it('refuses a platform without a release binary', () => {
    const fixture = setup({ platform: 'Plan9 mips' })
    const result = fixture.install()
    expect(result.status).not.toBe(0)
    expect(result.stderr).toContain('no solar release binary')
    expect(fixture.calls()).toEqual([])
  })

  it.each(['missing', 'malformed', 'revision', 'digest', 'binary'])(
    'reinstalls rather than adopting an existing compiler with %s receipt evidence',
    (kind) => {
      const fixture = setup()
      fixture.seed()
      if (kind === 'missing') rmSync(fixture.receipt)
      else if (kind === 'malformed') writeFileSync(fixture.receipt, '{')
      else if (kind === 'binary') writeFileSync(fixture.binary, 'substituted compiler')
      else
        writeFileSync(
          fixture.receipt,
          JSON.stringify({
            schemaVersion: 3,
            sourceRevision: kind === 'revision' ? 'ab'.repeat(20) : revision,
            sha256:
              kind === 'revision'
                ? createHash('sha256').update('existing compiler').digest('hex')
                : '00'.repeat(32),
          }),
        )
      const result = fixture.install()
      expect(result.status, result.stderr).toBe(0)
      expect(fixture.calls()).toHaveLength(1)
      expect(readFileSync(fixture.binary, 'utf8')).toBe(installedBytes)
      expect(result.stdout + result.stderr).toContain('fresh install')
    },
  )

  it('reuses only a receipt matching the revision and current executable bytes', () => {
    const fixture = setup()
    expect(fixture.install().status).toBe(0)
    const result = fixture.install(true)
    expect(result.status, result.stderr).toBe(0)
    expect(fixture.calls()).toHaveLength(1)
    expect(readFileSync(fixture.binary, 'utf8')).toBe(installedBytes)
  })

  it.each(['missing', 'mismatched'])(
    'preserves the old installation when a %s receipt triggers a failed download',
    (kind) => {
      const fixture = setup()
      fixture.seed()
      if (kind === 'missing') rmSync(fixture.receipt)
      else writeFileSync(fixture.binary, 'substituted compiler')
      const oldBinary = readFileSync(fixture.binary, 'utf8')
      const oldReceipt = existsSync(fixture.receipt)
        ? readFileSync(fixture.receipt, 'utf8')
        : undefined
      const result = fixture.install(true)
      expect(result.status).not.toBe(0)
      expect(fixture.calls()).toHaveLength(1)
      expect(readFileSync(fixture.binary, 'utf8')).toBe(oldBinary)
      expect(existsSync(fixture.receipt) ? readFileSync(fixture.receipt, 'utf8') : undefined).toBe(
        oldReceipt,
      )
      expect(readdirSync(join(fixture.root, '.solar'))).toEqual([revision])
    },
  )

  it('rejects project arguments before installing anything', () => {
    const fixture = setup()
    const result = fixture.install(false, ['earn'])
    expect(result.status).toBe(2)
    expect(result.stderr).toContain('usage: scripts/solidity-deps.sh')
    expect(fixture.calls()).toEqual([])
    expect(existsSync(join(fixture.root, '.solar'))).toBe(false)
  })

  it('does not publish a compiler or receipt from a failed first installation', () => {
    const fixture = setup()
    const result = fixture.install(true)
    expect(result.status).not.toBe(0)
    expect(fixture.calls()).toHaveLength(1)
    expect(existsSync(fixture.binary)).toBe(false)
    expect(existsSync(fixture.receipt)).toBe(false)
    expect(readdirSync(join(fixture.root, '.solar'))).toEqual([])
  })
})

function setup(options: { listed?: boolean; platform?: string; tampered?: boolean } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'solidity-deps-'))
  roots.push(root)
  for (const path of ['scripts', 'bin', `fixture/solar-${target}`])
    mkdirSync(join(root, path), { recursive: true })
  copyFileSync(
    new URL('../../scripts/solidity-deps.sh', import.meta.url),
    join(root, 'scripts/solidity-deps.sh'),
  )
  writeFileSync(join(root, 'foundry.lock'), '{}')
  writeFileSync(join(root, 'solar.lock'), `${revision}\n`)
  // A release archive laid out like solar's: solar-<target>/solar.
  writeFileSync(join(root, `fixture/solar-${target}/solar`), installedBytes, { mode: 0o755 })
  const archive = join(root, 'release.tar.gz')
  spawnSync('tar', ['-czf', archive, '-C', join(root, 'fixture'), `solar-${target}`])
  const digest = createHash('sha256').update(readFileSync(archive)).digest('hex')
  writeFileSync(
    join(root, 'solar-releases.json'),
    JSON.stringify(
      options.listed === false
        ? {}
        : {
            [revision]: {
              version: '9.9.9',
              sha256: { [target]: options.tampered ? '00'.repeat(32) : digest },
            },
          },
    ),
  )
  const [system, machine] = (options.platform ?? 'Linux x86_64').split(' ')
  writeFileSync(
    join(root, 'bin/uname'),
    `#!/bin/sh\ncase "$1" in -s) echo ${system} ;; -m) echo ${machine} ;; esac\n`,
  )
  chmodSync(join(root, 'bin/uname'), 0o700)
  const callsFile = join(root, 'curl-calls.jsonl')
  writeFileSync(
    join(root, 'bin/curl'),
    `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(callsFile)}, JSON.stringify(args) + '\\n');
if (process.env.TEST_CURL_FAIL === '1') process.exit(22);
fs.copyFileSync(${JSON.stringify(archive)}, args[args.indexOf('--output') + 1]);
`,
  )
  chmodSync(join(root, 'bin/curl'), 0o700)
  const directory = join(root, '.solar', revision)
  const binary = join(directory, 'bin/solar')
  const receipt = join(directory, 'install-receipt.json')
  return {
    root,
    directory,
    binary,
    receipt,
    calls: () =>
      existsSync(callsFile)
        ? readFileSync(callsFile, 'utf8')
            .trim()
            .split('\n')
            .map((line) => JSON.parse(line) as string[])
        : [],
    install: (fail = false, args: readonly string[] = []) =>
      spawnSync('bash', ['scripts/solidity-deps.sh', ...args], {
        cwd: root,
        encoding: 'utf8',
        env: {
          HOME: root,
          PATH: `${join(root, 'bin')}:${process.env.PATH}`,
          TEST_CURL_FAIL: fail ? '1' : '0',
        },
      }),
    seed: () => {
      mkdirSync(join(directory, 'bin'), { recursive: true })
      writeFileSync(binary, 'existing compiler', { mode: 0o700 })
      writeFileSync(
        receipt,
        JSON.stringify({
          schemaVersion: 3,
          sourceRevision: revision,
          sha256: createHash('sha256').update('existing compiler').digest('hex'),
        }),
      )
    },
  }
}
