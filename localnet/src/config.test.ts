import { createHash } from 'node:crypto'
import { readFileSync, readdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { ImageName } from 'testcontainers/build/container-runtime/image-name.js'
import { describe, expect, it } from 'vitest'

import * as Config from './config.js'

const digest = `sha256:${'a1'.repeat(32)}`

describe('parseRuntimeLock', () => {
  it('preserves the checked-in image references in the pinned Testcontainers parser', () => {
    const lock = Config.parseRuntimeLock(readJson('localnet/fixtures/runtime-lock.json'))
    expect(lock).toEqual(Config.runtimeLock)
    for (const image of [lock.l1Image, lock.zoneImage]) {
      const parsed = ImageName.fromString(image)
      expect(parsed.string).toBe(image)
      expect(parsed.digest).toBe(image.split('@')[1])
    }
  })

  it.each([
    `ghcr.io/tempoxyz/tempo@${digest}`,
    `ghcr.io/tempoxyz/tempo:v1.2.3@${digest}`,
    `localhost:5000/team/tempo-zone@${digest}`,
    `registry.example:5000/team/sub_team/tempo--zone:RC_1@${digest}`,
  ])('accepts an immutable reference without changing its digest: %s', (image) => {
    const lock = Config.parseRuntimeLock({
      ...Config.runtimeLock,
      l1Image: image,
      zoneImage: image,
    })
    for (const value of [lock.l1Image, lock.zoneImage]) {
      const parsed = ImageName.fromString(value)
      expect(value).toBe(image)
      expect(parsed.string).toBe(image)
      expect(parsed.digest).toBe(digest)
    }
  })

  it('rejects the multiple-@ input that the pinned parser reduces to a mutable tag', () => {
    const image = `ghcr.io/tempoxyz/tempo-zone@latest@${digest}`
    expect(ImageName.fromString(image).string).toBe('ghcr.io/tempoxyz/tempo-zone:latest')
    expect(() => Config.parseRuntimeLock({ ...Config.runtimeLock, zoneImage: image })).toThrow(
      'runtime lock images must use immutable sha256 digests',
    )
  })

  describe.each(['l1Image', 'zoneImage'] as const)('%s', (field) => {
    it.each([
      undefined,
      null,
      123,
      '',
      'ghcr.io/tempoxyz/tempo-zone',
      'ghcr.io/tempoxyz/tempo-zone:latest',
      `ghcr.io/tempoxyz/tempo-zone@latest@${digest}`,
      `ghcr.io/tempoxyz/tempo-zone@${digest}@latest`,
      `ghcr.io/tempoxyz/tempo-zone@@${digest}`,
      `ghcr.io/tempoxyz/tempo-zone@${digest}@`,
      `@${digest}`,
      `https://ghcr.io/tempoxyz/tempo-zone@${digest}`,
      `ghcr.io//tempo-zone@${digest}`,
      `ghcr.io/tempoxyz/tempo-zone:tag:other@${digest}`,
      `ghcr.io/tempoxyz/tempo-zone?tag=latest@${digest}`,
      `ghcr.io/tempoxyz/tempo-zone@sha512:${'a1'.repeat(64)}`,
      'ghcr.io/tempoxyz/tempo-zone@sha256:',
      `ghcr.io/tempoxyz/tempo-zone@sha256:${'a'.repeat(63)}`,
      `ghcr.io/tempoxyz/tempo-zone@sha256:${'a'.repeat(65)}`,
      `ghcr.io/tempoxyz/tempo-zone@sha256:${'g'.repeat(64)}`,
      `ghcr.io/tempoxyz/tempo-zone@sha256:${'A'.repeat(64)}`,
      `ghcr.io/tempoxyz/tempo-zone@${digest}:latest`,
      ` ghcr.io/tempoxyz/tempo-zone@${digest}`,
      `ghcr.io/tempoxyz/tempo-zone@${digest} `,
      `ghcr.io/tempoxyz/tempo-zone@${digest}\n`,
      `ghcr.io/tempoxyz/tempo\n-zone@${digest}`,
      `ghcr.io/tempoxyz/tempo-zone@${digest}\0`,
    ])('rejects malformed or mutable references: %s', (image) => {
      expect(() => Config.parseRuntimeLock({ ...Config.runtimeLock, [field]: image })).toThrow(
        'runtime lock images must use immutable sha256 digests',
      )
    })
  })

  it.each([null, [], 'lock', { ...Config.runtimeLock, extra: true }])(
    'rejects an unsupported lock shape: %s',
    (value) => {
      expect(() => Config.parseRuntimeLock(value)).toThrow('runtime lock')
    },
  )

  it('retains the protocol and provenance checks', () => {
    expect(() => Config.parseRuntimeLock({ ...Config.runtimeLock, zoneInfoFields: 8 })).toThrow(
      'unsupported protocol version',
    )
    expect(() =>
      Config.parseRuntimeLock({ ...Config.runtimeLock, sourceCommit: 'unknown' }),
    ).toThrow('provenance is invalid')
  })
})

describe('card runtime provenance', () => {
  const provenance = readJson('localnet/fixtures/card-runtime-provenance.json')

  it('records unresolved compatibility rather than promoting model acceptance to runtime proof', () => {
    expect(provenance.version).toBe(1)
    expect(provenance.compatibility.status).toBe('unresolved')
    expect(provenance.compatibility.foundryAssurance).toBe('model-only')
    expect(provenance.compatibility.runtimeEquivalenceEstablished).toBe(false)
    expect(provenance.vendor.sourceCommit).not.toBe(Config.runtimeLock.sourceCommit)
  })

  it('binds the vendor commit, complete Solidity source inventory, and compile inputs', () => {
    const documentation = readText('cards/vendor/VENDORED.md').split('## Zones runtime')[1]
    expect(documentation?.match(/`([0-9a-f]{40})`/)?.[1]).toBe(provenance.vendor.sourceCommit)
    expect(readJson('cards/foundry.lock')['lib/tempo-std'].rev).toBe(
      provenance.vendor.tempoStdCommit,
    )
    expect(sha256(readFile('cards/foundry.toml'))).toBe(provenance.vendor.foundryConfigSha256)
    const directory = 'cards/vendor/tempo-zones/src/runtime'
    const sources = readdirSync(resolve(Config.root, directory), {
      recursive: true,
      encoding: 'utf8',
    })
      .filter((path) => path.endsWith('.sol'))
      .sort()
    expect(sources).toEqual(Object.keys(provenance.vendor.sources).sort())
    for (const path of sources) {
      expect(sha256(readFile(`${directory}/${path}`)), path).toBe(provenance.vendor.sources[path])
    }
  })

  it('binds the exact image pair, fixture bytes and their declared source provenance', () => {
    expect(provenance.runtime).toEqual(Config.runtimeLock)
    const fixtureBytes = readFile(`localnet/fixtures/${Config.runtimeLock.runtimeFixture}`)
    expect(sha256(fixtureBytes)).toBe(provenance.runtime.runtimeFixtureSha256)
    const fixture = JSON.parse(fixtureBytes.toString('utf8'))
    expect(fixture.sourceCommit).toBe(provenance.runtime.sourceCommit)
    expect(fixture.solcVersion).toBe(provenance.runtime.solcVersion)
    for (const field of ['zonePortal', 'zoneMessenger', 'verifier']) {
      const code = fixture[field]
      expect(code).toMatch(/^0x(?:[0-9a-f]{2})+$/)
      expect(sha256(Buffer.from(code.slice(2), 'hex')), field).toBe(
        provenance.evidence.runtimeConstants[field].bytecodeSha256,
      )
    }
  })
})

function readFile(path: string) {
  return readFileSync(resolve(Config.root, path))
}

function readText(path: string) {
  return readFile(path).toString('utf8')
}

function readJson(path: string) {
  return JSON.parse(readText(path))
}

function sha256(value: Buffer) {
  return createHash('sha256').update(value).digest('hex')
}
