import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import * as Config from './config.js'
import { assertImageIdentity, assertRuntimeCode, executable } from './card-runtime.js'

const provenance = JSON.parse(
  readFileSync(resolve(Config.root, 'localnet/fixtures/card-runtime-provenance.json'), 'utf8'),
)

describe('assertImageIdentity', () => {
  for (const role of ['l1', 'zone'] as const) {
    const expected = provenance.evidence.images[role]
    const image = {
      RepoDigests: [Config.image[role]],
      Config: {
        Labels: {
          'org.opencontainers.image.source': expected.source,
          'org.opencontainers.image.revision': expected.revision,
        },
      },
    }
    it(`accepts only the reviewed ${role} digest and source`, () => {
      expect(() => assertImageIdentity(role, image)).not.toThrow()
      for (const invalid of [
        {},
        { ...image, RepoDigests: [] },
        { ...image, RepoDigests: [Config.image[role] + ':latest'] },
        { ...image, Config: { Labels: null } },
        {
          ...image,
          Config: {
            Labels: {
              ...image.Config.Labels,
              'org.opencontainers.image.source': 'https://example.com',
            },
          },
        },
        {
          ...image,
          Config: {
            Labels: {
              ...image.Config.Labels,
              'org.opencontainers.image.revision': 'ab'.repeat(20),
            },
          },
        },
      ])
        expect(() => assertImageIdentity(role, invalid)).toThrow('Unreviewed')
    })
  }
  it('records separate source repositories and revisions for the two binaries', () => {
    expect(provenance.evidence.images.l1.revision).toBe(Config.runtimeLock.sourceCommit)
    expect(provenance.evidence.images.zone.revision).not.toBe(Config.runtimeLock.sourceCommit)
    expect(provenance.evidence.images.zone.source).toBe('https://github.com/tempoxyz/zones')
  })
})

describe('assertRuntimeCode', () => {
  it('refuses missing, empty and changed runtime bytes', () => {
    expect(() => assertRuntimeCode('Portal', '0x60AA', '0x60aa')).not.toThrow()
    for (const observed of [undefined, '0x', '0x60ab'] as const)
      expect(() => assertRuntimeCode('Portal', observed, '0x60aa')).toThrow('differs')
  })
})

describe('executable', () => {
  const trailer = `a2646970667358221220${'ab'.repeat(32)}64736f6c63430008230033`
  it('ignores only the IPFS hash and never masks executable differences', () => {
    expect(executable(`0x6000${trailer}`)).toBe('0x6000')
    expect(executable(`0x6000${trailer.replace('ab'.repeat(32), 'cd'.repeat(32))}`)).toBe('0x6000')
    expect(executable(`0x6001${trailer}`)).not.toBe('0x6000')
  })
  it.each(['0x', '0x0', '0xzz', '0x60000033', `0x6000${trailer.replace('0823', '0824')}`])(
    'refuses missing, malformed or different-compiler metadata: %s',
    (code) => expect(() => executable(code)).toThrow(),
  )
})
