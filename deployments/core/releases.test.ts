import { readFileSync } from 'node:fs'
import { describe, expect, test } from 'vitest'
import {
  assertConsistentImmutableReferences,
  assertReviewedDeploymentIdentity,
  resolveEarnFactoryRelease,
} from './releases.js'

const address = `0x${'1'.repeat(40)}` as const

describe('assertReviewedDeploymentIdentity', () => {
  test.each(['veda-mainnet', 'veda-moderato', 'e2e-moderato'])(
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
