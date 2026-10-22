import { readdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { describe, expect, test } from 'vitest'
import { getAddress } from 'viem'

import { accessMembers } from '../modules/access-policy/membership.js'
import { loadEarnProfileBundle } from './bundle.js'
import {
  authoredProfile,
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  parseEarnDeploymentProfile as parseProfile,
  profileCapabilities,
} from './profile.js'
import { engineDefinitions } from '../modules/engines/index.js'
import { parseRewardConfiguration } from '../modules/rewards/schema.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as `0x${string}`
const deployer = address('3')
const factories = { earn: address('4'), erc4626Engine: address('1') }

const boostRewards = {
  startTimestamp: 1_900_000_000,
  endTimestamp: 1_900_000_120,
  intervalSeconds: 60,
  targetAnnualRateBps: 300,
  perUserPrincipalCapAssets: '1000000',
  totalPrincipalCapAssets: '10000000',
  treasury: address('7'),
  funding: {
    wallet: address('17'),
  },
}

const generic = {
  version: 1,
  id: 'generic-erc4626',
  chainId: 4217,
  owner: address('5'),
  engine: {
    kind: 'erc4626',
    venue: address('2'),
  },
  core: {
    migrationMode: 'OperatorEnabled',
  },
}

function parseEarnDeploymentProfile(
  value: Record<string, unknown>,
  options: Parameters<typeof parseProfile>[1] = {},
) {
  return parseProfile(value, { deployer, factories, ...options })
}

describe('Earn deployment profile', () => {
  test('uses the same canonical rewards document as the administration API', () => {
    const authoredRewards = {
      targetYield: {
        startTimestamp: 1_900_000_000,
        endTimestamp: 1_900_000_120,
        intervalSeconds: 60,
        annualRate: { bps: 500 },
        funding: [{ wallet: address('18'), remainder: true as const }],
      },
      boostRewards,
    }
    const profile = parseEarnDeploymentProfile({ ...generic, ...authoredRewards })
    const parsed = parseRewardConfiguration(authoredRewards)

    expect({ targetYield: profile.targetYield, boostRewards: profile.boostRewards }).toEqual(parsed)
  })

  test('excludes offchain economics from deployment intent', () => {
    const first = parseEarnDeploymentProfile({ ...generic, boostRewards })
    const second = parseEarnDeploymentProfile({
      ...generic,
      boostRewards: { ...boostRewards, targetAnnualRateBps: 400 },
    })
    expect(deploymentIntentHash(first)).toBe(deploymentIntentHash(second))
    expect(componentDeploymentIntentHashes(first)).toEqual(componentDeploymentIntentHashes(second))
    const changedContract = parseEarnDeploymentProfile({
      ...generic,
      boostRewards: { ...boostRewards, treasury: address('20') },
    })
    expect(deploymentIntentHash(first)).not.toBe(deploymentIntentHash(changedContract))
    const firstComponents = componentDeploymentIntentHashes(first)
    const changedComponents = componentDeploymentIntentHashes(changedContract)
    expect(changedComponents.core).toBe(firstComponents.core)
    expect(changedComponents.engine).toBe(firstComponents.engine)
    expect(changedComponents.boostRewards).not.toBe(firstComponents.boostRewards)
  })

  test('derives complete Zone policy membership without owner, deployer, or distributor', () => {
    const profile = parseEarnDeploymentProfile({
      ...generic,
      id: 'protected-zone',
      core: {
        ...generic.core,
        fees: {
          fixed: [{ recipient: address('6'), rateBps: 20 }],
          protectedFixed: {
            recipient: address('7'),
            rateBps: 10,
            distributor: address('8'),
            updateDelaySeconds: '86400',
          },
        },
      },
      zone: {
        id: 2,
        enableEarnShare: true,
        router: {
          privateAsset: address('a'),
          pool: address('b'),
          customerId: `0x${'c'.repeat(64)}`,
        },
      },
      tip403PolicyId: '469',
      boostRewards: { ...boostRewards, treasury: address('16') },
    })
    const members = accessMembers(profile, {
      earnVault: address('e'),
      earnFees: address('f'),
      earnRouter: address('10'),
      zonePortal: address('11'),
      zoneMessenger: address('12'),
      zoneSequencer0: address('13'),
      zoneSequencer1: address('15'),
      zoneOutbox: address('14'),
    })
    expect(members).toEqual(
      expect.arrayContaining([
        address('6'),
        address('7'),
        address('e'),
        address('f'),
        address('10'),
        address('11'),
        address('12'),
        address('13'),
        address('15'),
        address('14'),
        address('16'),
      ]),
    )
    expect(members).not.toContain(address('3'))
    expect(members).not.toContain(address('5'))
    expect(members).not.toContain(address('8'))
  })

  test('rejects a builtin TIP-403 policy', () => {
    expect(() =>
      parseEarnDeploymentProfile({
        ...generic,
        tip403PolicyId: '1',
      }),
    ).toThrow('reusable uint64')
  })

  test('advertises only the exits its engine declares', () => {
    const profile = parseEarnDeploymentProfile(generic)
    const engine = engineDefinitions[profile.engine.kind]
    const declared = engine.capabilities
    engine.capabilities = {
      inKindDeposit: false,
      redeem: false,
      boundedRedeem: false,
      exactWithdraw: false,
      asyncRedeem: true,
    }
    try {
      const advertised = profileCapabilities(profile)
      expect(advertised).toMatchObject({ deposit: true, ...engine.capabilities })
      expect(Object.keys(advertised)).toEqual(expect.arrayContaining(Object.keys(declared)))
    } finally {
      engine.capabilities = declared
    }
  })
})

const profilesRoot = resolve(fileURLToPath(new URL('../../profiles', import.meta.url)))
const zoneProfiles = readdirSync(profilesRoot, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => loadEarnProfileBundle(resolve(profilesRoot, entry.name, 'profile.json')).profile)
  .filter((profile) => profile.zone !== null)

describe('committed Zone profiles', () => {
  test.each(zoneProfiles.map((profile) => [profile.id, profile] as const))(
    '%s round-trips through its authored form',
    (_, profile) => {
      const authored = JSON.parse(JSON.stringify(authoredProfile(profile))) as unknown
      expect(
        parseProfile(authored, { deployer: profile.deployer, factories: profile.factories }),
      ).toEqual(profile)
    },
  )
})
