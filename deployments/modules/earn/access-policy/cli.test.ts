import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

import type { EarnStack } from '../../../core/stack.js'
import { policySiblingStacks } from './cli.js'

const venue = '0x0d136e26b4d9e4836fc5cb202baeb49cb6f5df48'

/** A profile repository with the selected profile and the given neighbours. */
function repository(neighbours: Record<string, { profile: unknown; pending?: boolean }>) {
  const root = mkdtempSync(join(tmpdir(), 'access-siblings-'))
  const write = (directory: string, id: string, profile: unknown, pending = false) => {
    mkdirSync(join(directory, id), { recursive: true })
    writeFileSync(join(directory, id, 'profile.json'), JSON.stringify(profile))
    if (pending) writeFileSync(join(directory, id, 'deployment.pending.json'), '{}')
  }
  const profiles = join(root, 'profiles')
  write(profiles, 'selected-moderato', authored('selected-moderato'))
  for (const [id, { profile, pending }] of Object.entries(neighbours)) {
    write(profiles, id, profile, pending)
  }
  return { root, profiles, selected: join(profiles, 'selected-moderato', 'profile.json') }
}

function authored(id: string, policy = '469') {
  return {
    version: 1,
    id,
    chainId: 42431,
    tip403PolicyId: policy,
    engine: { kind: 'erc4626', venue },
  }
}

const selected = {
  id: 'selected-moderato',
  network: { chainId: 42431 },
  access: { kind: 'tip403-whitelist', transferPolicyId: '469' },
} as unknown as EarnStack
const genesis = `0x${'11'.repeat(32)}`

describe('policy sibling discovery', () => {
  it('stops on an unpublished deployment that shares the policy, naming it', async () => {
    const { selected: path } = repository({
      'other-moderato': { profile: authored('other-moderato'), pending: true },
    })
    await expect(policySiblingStacks(path, selected, genesis)).rejects.toThrow(
      /profile other-moderato: it has an unpublished deployment on policy 469/,
    )
  })

  it('ignores an unpublished deployment on another policy', async () => {
    const { selected: path } = repository({
      'other-moderato': { profile: authored('other-moderato', '470'), pending: true },
    })
    await expect(policySiblingStacks(path, selected, genesis)).resolves.toEqual([])
  })

  it('names an unparseable neighbour instead of failing anonymously', async () => {
    const { selected: path } = repository({
      'broken-moderato': { profile: { id: 'broken-moderato' }, pending: true },
    })
    await expect(policySiblingStacks(path, selected, genesis)).rejects.toThrow(
      /profile broken-moderato:/,
    )
  })

  it('follows a symlinked neighbour directory', async () => {
    const { profiles, selected: path } = repository({})
    const elsewhere = mkdtempSync(join(tmpdir(), 'access-sibling-target-'))
    mkdirSync(join(elsewhere, 'linked-moderato'))
    writeFileSync(
      join(elsewhere, 'linked-moderato', 'profile.json'),
      JSON.stringify(authored('linked-moderato')),
    )
    writeFileSync(join(elsewhere, 'linked-moderato', 'deployment.pending.json'), '{}')
    symlinkSync(join(elsewhere, 'linked-moderato'), join(profiles, 'linked-moderato'))
    await expect(policySiblingStacks(path, selected, genesis)).rejects.toThrow(
      /profile linked-moderato: it has an unpublished deployment/,
    )
  })
})
