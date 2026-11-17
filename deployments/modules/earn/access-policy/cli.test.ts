import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'

import { loadEarnProfile } from '../../../core/bundle.js'
import { deploymentIntentHash } from '../../../core/profile.js'
import { resolveEarnFactoryRelease } from '../../../core/releases.js'
import type { EarnStack } from '../../../core/stack.js'
import { policySiblingStacks, redactUrls, siblingEnvironment } from './cli.js'

const venue = '0x0d136e26b4d9e4836fc5cb202baeb49cb6f5df48'

/** A profile repository with the selected profile and the given neighbours. */
function repository(neighbours: Record<string, { profile: unknown; pending?: boolean }>) {
  const root = mkdtempSync(join(tmpdir(), 'access-siblings-'))
  const write = (directory: string, id: string, profile: unknown, pending = false) => {
    mkdirSync(join(directory, id), { recursive: true })
    writeFileSync(join(directory, id, 'profile.json'), JSON.stringify(profile))
    if (pending) writePending(join(directory, id))
  }
  const profiles = join(root, 'profiles')
  write(profiles, 'selected-moderato', authored('selected-moderato'))
  for (const [id, { profile, pending }] of Object.entries(neighbours)) {
    write(profiles, id, profile, pending)
  }
  return { root, profiles, selected: join(profiles, 'selected-moderato', 'profile.json') }
}

const deployer = '0x00000000000000000000000000000000000000D1'

/** A pending deployment bound to the authored profile in `directory`, as `pnpm earn deploy` writes. */
function writePending(directory: string) {
  const path = join(directory, 'profile.json')
  const preliminary = loadEarnProfile(path)
  const factories = resolveEarnFactoryRelease(preliminary.chainId)
  const profile = loadEarnProfile(path, { deployer, factories })
  writeFileSync(
    join(directory, 'deployment.pending.json'),
    JSON.stringify({
      version: 3,
      profileId: profile.id,
      deployer: profile.deployer,
      owner: profile.owner,
      factories: profile.factories,
      deploymentIntentHash: deploymentIntentHash(profile),
      outputs: {},
      actions: {},
    }),
  )
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
      /profile other-moderato: it has an unpublished deployment/,
    )
  })

  it('ignores a pending deployment bound to another policy', async () => {
    const { selected: path } = repository({
      'other-moderato': { profile: authored('other-moderato', '470'), pending: true },
    })
    await expect(policySiblingStacks(path, selected, genesis)).resolves.toEqual([])
  })

  it('stops when a pending deployment no longer matches its edited profile', async () => {
    const { profiles, selected: path } = repository({
      'other-moderato': { profile: authored('other-moderato', '470'), pending: true },
    })
    writeFileSync(
      join(profiles, 'other-moderato', 'profile.json'),
      JSON.stringify(authored('other-moderato', '471')),
    )
    await expect(policySiblingStacks(path, selected, genesis)).rejects.toThrow(
      /profile other-moderato: Pending deployment .* does not match this profile/,
    )
  })

  it('names an unparseable neighbour instead of failing anonymously', async () => {
    const { selected: path } = repository({
      'broken-moderato': { profile: { id: 'broken-moderato' } },
    })
    writeFileSync(join(dirname(path), '..', 'broken-moderato', 'deployment.pending.json'), '{}')
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
    writePending(join(elsewhere, 'linked-moderato'))
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

  describe('a recorded neighbour naming another genesis of this chain', () => {
    const earnShare = '0x00000000000000000000000000000000000000E5'
    const setup = () => {
      const { profiles, selected: path } = repository({
        'other-moderato': { profile: authored('other-moderato') },
      })
      writeFileSync(
        join(profiles, 'other-moderato', 'deployment.json'),
        JSON.stringify({
          target: { chainId: 42431, genesisHash: '0x' + '33'.repeat(32) },
          addresses: { earnShare },
        }),
      )
      return path
    }

    it('is skipped when its EarnShare has no code here', async () => {
      const getCode = vi.fn(async () => undefined)
      await expect(policySiblingStacks(setup(), selected, genesis, { getCode })).resolves.toEqual(
        [],
      )
      expect(getCode).toHaveBeenCalledWith({ address: earnShare })
    })

    it('stops the removal when its EarnShare has code here', async () => {
      const getCode = vi.fn(async () => '0x6080' as const)
      await expect(policySiblingStacks(setup(), selected, genesis, { getCode })).rejects.toThrow(
        /profile other-moderato: its record names genesis 0x3333.*may be live on this chain/,
      )
    })

    it('stops the removal when liveness cannot be checked', async () => {
      await expect(policySiblingStacks(setup(), selected, genesis)).rejects.toThrow(
        /may be live on this chain/,
      )
    })
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

  it.each([
    ['credentials only', 'TEMPO_RPC_USERNAME=u\nTEMPO_RPC_PASSWORD=p\n'],
    [
      'a blank URL with credentials',
      'TEMPO_RPC_URL=\nTEMPO_RPC_USERNAME=u\nTEMPO_RPC_PASSWORD=p\n',
    ],
  ])('refuses a file with %s', (_, file) => {
    const { root } = repository({})
    writeFileSync(join(root, '.env.other-moderato'), file)
    vi.stubEnv('TEMPO_RPC_URL', 'https://private.example')
    expect(() => siblingEnvironment(root, 'other-moderato')).toThrow(
      'sets TEMPO_RPC credentials without TEMPO_RPC_URL',
    )
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

describe('neighbour failure messages', () => {
  it('redact a whole URL whose path contains parentheses', () => {
    expect(
      redactUrls('failed: https://rpc.example/(v2)/fake-api-secret?key=fake-query-secret.'),
    ).toBe('failed: https://rpc.example/[redacted].')
  })

  it('redact a whole URL whose credentials contain quotes or angle brackets', () => {
    for (const secret of ["pa'ss", 'pa"ss', 'pa<ss', 'pa>ss']) {
      const out = redactUrls(`failed: https://user:${secret}@rpc.example/v2 next`)
      expect(out).toBe('failed: https://rpc.example/[redacted] next')
    }
  })

  it('keep quotes and angle brackets around a URL outside it', () => {
    expect(redactUrls('url "https://rpc.example/v2/key" or <https://rpc.example>.')).toBe(
      'url "https://rpc.example/[redacted]" or <https://rpc.example>.',
    )
  })

  it('handle a long punctuation run in linear time', () => {
    const run = '.'.repeat(200_000)
    const started = performance.now()
    expect(redactUrls(`https://rpc.example/${run}x${run}`)).toBe(
      `https://rpc.example/[redacted]${run}`,
    )
    expect(performance.now() - started).toBeLessThan(1_000)
  })

  it('keep only the origin of each URL', () => {
    expect(
      redactUrls(
        'HTTP request failed. URL: https://rpc.example/v2/sk_live_123?key=abc Details: x (https://rpc.example)',
      ),
    ).toBe(
      'HTTP request failed. URL: https://rpc.example/[redacted] Details: x (https://rpc.example)',
    )
  })
})
