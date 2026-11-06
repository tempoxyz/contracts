import { execFileSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'

import { cleanSourceRevision, stackManifest } from './provenance.js'

const roots: string[] = []
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('cleanSourceRevision', () => {
  it('uses the requested checkout and rejects modified and untracked input', () => {
    const root = mkdtempSync(join(tmpdir(), 'fixture-provenance-'))
    roots.push(root)
    const git = (...args: string[]) =>
      execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim()
    git('init', '--quiet')
    git('config', 'user.name', 'Fixture test')
    git('config', 'user.email', 'fixture@example.test')
    writeFileSync(join(root, 'fixture.sol'), 'original\n')
    git('add', '.')
    git('-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')
    expect(cleanSourceRevision(root)).toBe(git('rev-parse', 'HEAD'))
    writeFileSync(join(root, 'fixture.sol'), 'modified\n')
    expect(() => cleanSourceRevision(root)).toThrow('clean source checkout')
    git('checkout', '--', 'fixture.sol')
    writeFileSync(join(root, 'untracked.sol'), 'new input\n')
    expect(() => cleanSourceRevision(root)).toThrow('clean source checkout')
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
