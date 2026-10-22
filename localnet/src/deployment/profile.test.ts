import { authoredProfile } from '@tempoxyz/earn/deployments/node'
import { parseEarnDeploymentProfile } from '@tempoxyz/earn/deployments/operations'
import { getAddress } from 'viem'
import { describe, expect, it } from 'vitest'

import { localizeProfile, type LocalTargets } from './profile.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)
const local: LocalTargets = {
  chainId: 1337,
  deployer: address('d'),
  factories: { earn: address('f1'), erc4626Engine: address('f2') },
  venueOrEngine: address('7e'),
  policyId: 5n,
  zoneId: 1,
  conversion: { privateAsset: address('a1'), pool: address('9001') },
  vaultAsset: address('ba5e'),
}
// A synthetic hosted profile with protected access, a Zone, and a pooled router; shared tests do
// not depend on a customer's live configuration.
const hosted = parseEarnDeploymentProfile({
  version: 3,
  id: 'acme-mainnet',
  chainId: 4217,
  tip403PolicyId: '42',
  engine: { kind: 'erc4626', venue: address('ee') },
  core: {
    fees: {
      protectedFixed: {
        recipient: address('0'),
        rateBps: 0,
        distributor: address('d15'),
        updateDelaySeconds: '604800',
      },
    },
  },
  zone: {
    id: 2,
    enableEarnShare: true,
    router: {
      privateAsset: address('a2'),
      pool: address('9002'),
      customerId: `0x${'ac'.repeat(32)}`,
    },
  },
})

describe('local deployment profiles', () => {
  it('replaces only the external dependencies of a reviewed profile', () => {
    const source = authoredProfile(hosted)
    const profile = localizeProfile(source, local)
    expect(profile).toMatchObject({
      id: 'acme-mainnet',
      version: source.version,
      chainId: 1337,
      deployer: local.deployer,
      owner: local.deployer,
      engine: { kind: 'erc4626', venue: local.venueOrEngine },
      access: { kind: 'tip403-whitelist', policyId: '5' },
      core: hosted.core,
      zone: {
        id: 1,
        router: { ...local.conversion, customerId: source.zone!.router.customerId },
      },
    })
    expect(profile.targetYield).toBeUndefined()
    expect(profile.boostRewards).toBeUndefined()
  })
})
