import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'

import type { EarnStack } from '../../../core/stack.js'
import { policySiblingStacks, siblingEnvironment } from './cli.js'

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

  it('counts a symlink alias of the selected profile or a neighbour once', async () => {
    const { profiles, selected: path } = repository({
      'other-moderato': { profile: authored('other-moderato'), pending: true },
    })
    symlinkSync(join(profiles, 'selected-moderato'), join(profiles, 'latest'))
    symlinkSync(join(profiles, 'other-moderato'), join(profiles, 'zz-alias'))
    await expect(policySiblingStacks(path, selected, genesis)).rejects.toThrow(
      /profile other-moderato: it has an unpublished deployment/,
    )
  })

  it('skips a recorded neighbour on another chain without loading it strictly', async () => {
    const { profiles, selected: path } = repository({
      'other-mainnet': { profile: { ...authored('other-mainnet'), chainId: 4217 } },
    })
    writeFileSync(
      join(profiles, 'other-mainnet', 'deployment.json'),
      JSON.stringify({ target: { chainId: 4217, genesisHash: `0x${'22'.repeat(32)}` } }),
    )
    await expect(policySiblingStacks(path, selected, genesis)).resolves.toEqual([])
  })

  it.each([
    ['an empty genesis hash', { chainId: 42431, genesisHash: '' }, 42431],
    ['a truncated genesis hash', { chainId: 42431, genesisHash: '0x1234' }, 42431],
    ['a chain that disagrees with its profile', { chainId: 4217, genesisHash: 'G' }, 42431],
  ])('strictly loads a neighbour whose record has %s', async (_, target, authoredChain) => {
    const { profiles, selected: path } = repository({
      'other-moderato': { profile: { ...authored('other-moderato'), chainId: authoredChain } },
    })
    const record = {
      ...target,
      genesisHash: target.genesisHash === 'G' ? '0x' + '22'.repeat(32) : target.genesisHash,
    }
    writeFileSync(
      join(profiles, 'other-moderato', 'deployment.json'),
      JSON.stringify({ target: record }),
    )
    await expect(policySiblingStacks(path, selected, genesis)).rejects.toThrow(
      /profile other-moderato:/,
    )
  })

  it('strictly loads a recorded neighbour on the same chain and genesis', async () => {
    const { profiles, selected: path } = repository({
      'other-moderato': { profile: authored('other-moderato', '470') },
    })
    writeFileSync(
      join(profiles, 'other-moderato', 'deployment.json'),
      JSON.stringify({ target: { chainId: 42431, genesisHash: genesis } }),
    )
    await expect(policySiblingStacks(path, selected, genesis)).rejects.toThrow(
      /profile other-moderato:/,
    )
  })
})

describe('sibling environment', () => {
  afterEach(() => vi.unstubAllEnvs())

  it.each([
    ['a blank URL', 'TEMPO_RPC_URL=\n'],
    ['only a URL', 'TEMPO_RPC_URL=https://sibling.example\n'],
  ])('takes the whole RPC group from a file naming %s', (_, file) => {
    const { root } = repository({})
    writeFileSync(join(root, '.env.other-moderato'), file)
    vi.stubEnv('TEMPO_RPC_URL', 'https://shell.example')
    vi.stubEnv('TEMPO_RPC_USERNAME', 'shell-user')
    vi.stubEnv('TEMPO_RPC_PASSWORD', 'shell-pass')
    const values = siblingEnvironment(root, 'other-moderato')
    expect(values.TEMPO_RPC_USERNAME).toBeUndefined()
    expect(values.TEMPO_RPC_PASSWORD).toBeUndefined()
    expect(values.TEMPO_RPC_URL).not.toBe('https://shell.example')
  })

  it('keeps the shell RPC group when the file names none of it', () => {
    const { root } = repository({})
    writeFileSync(join(root, '.env.other-moderato'), 'OTHER=1\n')
    vi.stubEnv('TEMPO_RPC_URL', 'https://shell.example')
    vi.stubEnv('TEMPO_RPC_USERNAME', 'shell-user')
    vi.stubEnv('TEMPO_RPC_PASSWORD', 'shell-pass')
    expect(siblingEnvironment(root, 'other-moderato')).toMatchObject({
      TEMPO_RPC_URL: 'https://shell.example',
      TEMPO_RPC_USERNAME: 'shell-user',
      TEMPO_RPC_PASSWORD: 'shell-pass',
    })
  })
})
