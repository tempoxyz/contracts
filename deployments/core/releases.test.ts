import { readFileSync } from 'node:fs'
import { describe, expect, test } from 'vitest'
import {
  assertConsistentImmutableReferences,
  assertReviewedDeploymentIdentity,
  resolveEarnFactoryRelease,
  runtimeCodeIdentity,
  stripMetadata,
} from './releases.js'

const address = `0x${'1'.repeat(40)}` as const

describe('assertReviewedDeploymentIdentity', () => {
  test.each(['veda-moderato', 'e2e-moderato'])(
    'preserves the reviewed historical release of %s',
    (id) => {
      const record = JSON.parse(
        readFileSync(new URL(`../../profiles/${id}/deployment.json`, import.meta.url), 'utf8'),
      )
      const identity = { ...record, chainId: record.target.chainId }
      expect(() => assertReviewedDeploymentIdentity(identity)).not.toThrow()
      expect(() => assertReviewedDeploymentIdentity({ ...identity, deployer: address })).toThrow(
        'independently reviewed identity',
      )
      expect(() =>
        assertReviewedDeploymentIdentity({
          ...identity,
          factories: resolveEarnFactoryRelease(identity.chainId),
        }),
      ).toThrow('independently reviewed identity')
      const altered = { deployer: address, factories: resolveEarnFactoryRelease(identity.chainId) }
      expect(() => assertReviewedDeploymentIdentity({ ...identity, ...altered }, altered)).toThrow(
        'independently reviewed identity',
      )
      expect(() => assertReviewedDeploymentIdentity(identity, altered)).not.toThrow()
    },
  )

  test('unknown hosted records need separate trust, not a self-consistent record', () => {
    const record = {
      deploymentId: 'external',
      chainId: 4217,
      deployer: address,
      factories: resolveEarnFactoryRelease(4217),
    }
    expect(() => assertReviewedDeploymentIdentity(record)).toThrow('cannot approve itself')
    const trusted = { deployer: address, factories: resolveEarnFactoryRelease(4217) }
    expect(() => assertReviewedDeploymentIdentity(record, trusted)).not.toThrow()
    expect(() =>
      assertReviewedDeploymentIdentity({ ...record, deployer: `0x${'2'.repeat(40)}` }, trusted),
    ).toThrow('independently reviewed identity')
    expect(() => assertReviewedDeploymentIdentity({ ...record, chainId: 31337 })).not.toThrow()
  })
})

describe('assertConsistentImmutableReferences', () => {
  test.each([20, 32])(
    'compares every compiler-declared %s-byte copy before masking it',
    (length) => {
      const value = 'ab'.repeat(length)
      const references = [
        { start: 1, length },
        { start: length + 2, length },
      ]
      expect(() =>
        assertConsistentImmutableReferences(`0x60${value}61${value}`, [references]),
      ).not.toThrow()
      expect(() =>
        assertConsistentImmutableReferences(`0x60${value}61${'cd'.repeat(length)}`, [references]),
      ).toThrow('inconsistent immutable values')
      // Different declarations may hold different values, even when their encoded lengths match.
      expect(() =>
        assertConsistentImmutableReferences(
          `0x60${value}61${'cd'.repeat(length)}`,
          references.map((reference) => [reference]),
        ),
      ).not.toThrow()
    },
  )

  test('does not assume every occurrence uses the same PUSH width', () => {
    expect(() =>
      assertConsistentImmutableReferences('0x6000016101', [
        [
          { start: 1, length: 2 },
          { start: 4, length: 1 },
        ],
      ]),
    ).not.toThrow()
  })

  test.each([
    { start: -1, length: 1 },
    { start: 0, length: 0 },
    { start: 2, length: 1 },
    { start: 0.5, length: 1 },
  ])('refuses a malformed compiler reference %j', (reference) => {
    expect(() => assertConsistentImmutableReferences('0x6000', [[reference]])).toThrow(
      'outside the runtime bytecode',
    )
  })
})

describe('stripMetadata', () => {
  // Solar's tail: {ipfs: <34-byte multihash>, solar: <version>}, then its two-byte length.
  const tail = (hash: string, version = '000301') =>
    `a2646970667358221220${hash.repeat(32)}65736f6c617243${version}0034`

  test('removes the CBOR metadata tail', () => {
    expect(stripMetadata(`0x6001${tail('aa')}`)).toBe('0x6001')
    // A boolean entry, as solc's experimental flag, and a tail filling the whole code.
    expect(stripMetadata('0xa26178f5617941ab0008')).toBe('0x')
  })

  test.each([
    ['no tail', '0x60aa60bb'],
    ['a length past the code', '0x6001ffff'],
    ['a zero length', '0x60010000'],
    ['a tail that is not a map', '0x6001820102' + '0003'],
    ['an empty map', '0x6001a0' + '0001'],
    ['a map shorter than its length', '0x6001a1617802ab00' + '0006'],
    ['a map longer than its length', '0x6001a1617802abcd' + '0005'],
    ['a key that is not text', '0x6001a1427802abcd' + '0006'],
    ['an integer value', '0x6001a1617801' + '0004'],
  ])('keeps code with %s unchanged', (_, code) => {
    expect(stripMetadata(code as `0x${string}`)).toBe(code)
  })

  test('removes the metadata of child creation code a factory embeds before its tail', () => {
    // Solar puts each tail behind its own INVALID byte; the INVALID bytes stay.
    expect(stripMetadata(`0x6001fe${tail('aa')}fe${tail('bb')}`)).toBe('0x6001fefe')
    // Solc's tails are adjacent, behind one INVALID byte.
    const solc = (hash: string) => `a2646970667358221220${hash.repeat(32)}64736f6c63430008260033`
    expect(stripMetadata(`0x6001fe${solc('aa')}${solc('bb')}`)).toBe('0x6001fe')
    expect(stripMetadata(`0x6001fe${solc('aa')}fe${solc('bb')}fe${tail('cc')}`)).toBe(
      '0x6001fefefe',
    )
  })

  test('keeps embedded sections without a source hash', () => {
    // A boolean-only map is a valid tail, but not an embedded child's metadata.
    expect(stripMetadata(`0x6001a26178f5617941ab0008fe${tail('aa')}`)).toBe(
      '0x6001a26178f5617941ab0008fe',
    )
    expect(stripMetadata(`0x6001a26178f5617941ab0008${tail('aa')}`)).toBe(
      '0x6001a26178f5617941ab0008',
    )
  })

  test('builds that differ only in source text or compiler label share an identity', () => {
    const references = [{ start: 1, length: 1 }]
    const identity = runtimeCodeIdentity(`0x60aa${tail('11')}`, references)
    expect(runtimeCodeIdentity(`0x60bb${tail('22', '000302')}`, references)).toBe(identity)
    expect(runtimeCodeIdentity(`0x61aa${tail('11')}`, references)).not.toBe(identity)
    expect(runtimeCodeIdentity('0x60aa', references)).toBe(identity)
    // A factory embedding a child whose source text changed keeps its identity, not its code.
    const factory = runtimeCodeIdentity(`0x60aafe${tail('11')}fe${tail('22')}`, references)
    expect(runtimeCodeIdentity(`0x60bbfe${tail('33')}fe${tail('44')}`, references)).toBe(factory)
    expect(runtimeCodeIdentity(`0x60aa61fe${tail('11')}fe${tail('22')}`, references)).not.toBe(
      factory,
    )
  })
})
