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
const installedBytes = '#!/bin/sh\necho fresh-pinned-install\n'
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('solidity-deps solar installation', () => {
  it('records the digest only after a fresh pinned cargo installation', () => {
    const fixture = setup()
    const result = fixture.install()
    expect(result.status, result.stderr).toBe(0)
    expect(fixture.calls()).toHaveLength(1)
    expect(fixture.calls()[0]).toEqual([
      'install',
      '--quiet',
      '--locked',
      '--git',
      'https://github.com/paradigmxyz/solar',
      '--rev',
      revision,
      '--root',
      expect.any(String),
      'solar-compiler',
    ])
    expect(fixture.calls()[0]![8]).not.toBe(fixture.directory)
    expect(fixture.calls()[0]![8]!.startsWith(join(fixture.root, '.solar', '.build-'))).toBe(true)
    expect(readFileSync(fixture.binary, 'utf8')).toBe(installedBytes)
    expect(JSON.parse(readFileSync(fixture.receipt, 'utf8'))).toEqual({
      schemaVersion: 1,
      sourceRevision: revision,
      sha256: createHash('sha256').update(installedBytes).digest('hex'),
    })
    expect(readdirSync(join(fixture.root, '.solar'))).toEqual([revision])
  })

  it.each(['missing', 'malformed', 'revision', 'digest', 'binary'])(
    'rebuilds rather than adopting an existing compiler with %s receipt evidence',
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
            schemaVersion: 1,
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
      expect(JSON.parse(readFileSync(fixture.receipt, 'utf8')).sha256).toBe(
        createHash('sha256').update(installedBytes).digest('hex'),
      )
      expect(result.stdout + result.stderr).toContain('rebuild')
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
    'preserves the old installation when a %s receipt triggers a failed rebuild',
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

function setup() {
  const root = mkdtempSync(join(tmpdir(), 'solidity-deps-'))
  roots.push(root)
  for (const path of ['scripts', 'bin', 'earn']) mkdirSync(join(root, path))
  copyFileSync(
    new URL('../../scripts/solidity-deps.sh', import.meta.url),
    join(root, 'scripts/solidity-deps.sh'),
  )
  writeFileSync(join(root, 'earn/foundry.lock'), '{}')
  writeFileSync(join(root, 'earn/solar.lock'), `${revision}\n`)
  const callsFile = join(root, 'cargo-calls.jsonl')
  writeFileSync(
    join(root, 'bin/cargo'),
    `#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const args = process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(callsFile)}, JSON.stringify(args) + '\\n');
const target = args[args.indexOf('--root') + 1];
fs.mkdirSync(path.join(target, 'bin'), { recursive: true });
fs.writeFileSync(path.join(target, 'bin/solar'), ${JSON.stringify(installedBytes)}, { mode: 0o700 });
if (process.env.TEST_CARGO_FAIL === '1') process.exit(33);
`,
  )
  chmodSync(join(root, 'bin/cargo'), 0o700)
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
    install: (fail = false) =>
      spawnSync('bash', ['scripts/solidity-deps.sh', 'earn'], {
        cwd: root,
        encoding: 'utf8',
        env: {
          HOME: root,
          PATH: `${join(root, 'bin')}:${process.env.PATH}`,
          TEST_CARGO_FAIL: fail ? '1' : '0',
        },
      }),
    seed: () => {
      mkdirSync(join(directory, 'bin'), { recursive: true })
      writeFileSync(binary, 'existing compiler', { mode: 0o700 })
      writeFileSync(
        receipt,
        JSON.stringify({
          schemaVersion: 1,
          sourceRevision: revision,
          sha256: createHash('sha256').update('existing compiler').digest('hex'),
        }),
      )
    },
  }
}
