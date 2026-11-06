import { readFileSync } from 'node:fs'
import { describe, expect, test } from 'vitest'
import { assertReviewedDeploymentIdentity, resolveEarnFactoryRelease } from './releases.js'

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
