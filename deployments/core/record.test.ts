import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { describe, expect, test } from 'vitest'

import {
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  profileFactoryDeploymentId,
} from './profile.js'
import {
  loadProfileDeploymentRecord,
  profileDeploymentPath,
  publishProfileDeploymentRecord,
} from './bundle.js'
import { parseEarnDeploymentRecord, type EarnDeploymentRecord } from './record.js'
import { parseEarnDeploymentProfile } from './profile.js'
import { zoneMessengerAddress } from '../chain/zone.js'

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}` as const
const transaction = `0x${'1'.repeat(64)}` as const
const codeHash = `0x${'3'.repeat(64)}` as const
const sourceInputsHash = `0x${'4'.repeat(64)}` as const
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'record-test',
    chainId: 42431,
    owner: address('4'),
    engine: { kind: 'veda', address: address('1') },
  },
  { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
)
const factoryDeploymentId = profileFactoryDeploymentId(profile)
const zoneProfile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'zone-record-test',
    chainId: 4217,
    owner: address('4'),
    engine: { kind: 'veda', address: address('1') },
    zone: {
      id: 1,
      enableEarnShare: true,
      router: {
        privateAsset: address('d'),
        pool: address('e'),
        customerId: `0x${'c'.repeat(64)}`,
      },
    },
  },
  { deployer: address('2'), factories: { earn: address('3'), erc4626Engine: address('5') } },
)

function record(overrides: Partial<EarnDeploymentRecord> = {}): EarnDeploymentRecord {
  return {
    version: 4,
    deploymentId: profile.id,
    deployer: profile.deployer,
    owner: profile.owner,
    factories: profile.factories,
    deploymentIntentHash: deploymentIntentHash(profile),
    componentDeploymentIntentHashes: componentDeploymentIntentHashes(profile),
    target: { chainId: profile.chainId, genesisHash: `0x${'2'.repeat(64)}` },
    assetDecimals: 6,
    deploymentBlock: '123',
    generatedAt: '2026-01-01T00:00:00.000Z',
    source: {
      factoryDeploymentId,
      commit: `0x${'4'.repeat(40)}`,
      treeDirty: false,
      foundryVersion: 'forge test',
      contractVerification: 'verified',
      verifierUrl: 'https://contracts.tempo.xyz',
      contracts: {
        engine: { kind: 'source', name: 'VedaEngine', match: 'exact_match', sourceInputsHash },
        earnFees: {
          kind: 'minimal-proxy',
          implementation: address('a'),
          implementationCodeHash: codeHash,
        },
        earnShare: { kind: 'protocol-native', factory: address('9') },
        earnVault: {
          kind: 'erc1967-proxy',
          name: 'ERC1967Proxy',
          match: 'exact_match',
          sourceInputsHash,
          implementation: address('b'),
          implementationCodeHash: codeHash,
        },
      },
    },
    addresses: {
      asset: address('5'),
      engine: address('1'),
      earnFees: address('6'),
      earnShare: address('7'),
      earnVault: address('8'),
    },
    runtimeCodeHashes: {
      asset: codeHash,
      engine: codeHash,
      earnFees: codeHash,
      earnShare: codeHash,
      earnVault: codeHash,
    },
    actions: {
      'deploy-core': {
        completedAt: '2026-01-01T00:00:00.000Z',
        verification: 'broadcast',
        transactions: [transaction],
      },
      'bind-core': {
        completedAt: '2026-01-01T00:00:00.000Z',
        verification: 'chain',
        transactions: [],
      },
    },
    ...overrides,
  }
}

describe('deployment records', () => {
  test('rejects a Zone target that is not the profile Zone identity', () => {
    const deployed = record({
      deploymentId: zoneProfile.id,
      deploymentIntentHash: deploymentIntentHash(zoneProfile),
      componentDeploymentIntentHashes: componentDeploymentIntentHashes(zoneProfile),
      target: {
        chainId: zoneProfile.chainId,
        genesisHash: `0x${'2'.repeat(64)}`,
        zone: {
          id: 1,
          chainId: 421700001,
          portal: address('f'),
          messenger: zoneMessengerAddress,
        },
      },
      source: {
        ...record().source,
        factoryDeploymentId: profileFactoryDeploymentId(zoneProfile),
        contracts: {
          ...record().source.contracts,
          earnRouter: {
            kind: 'source',
            name: 'SingleZoneEarnRouter',
            match: 'exact_match',
            sourceInputsHash,
          },
        },
      },
      addresses: {
        ...record().addresses,
        zonePortal: address('f'),
        zoneMessenger: zoneMessengerAddress,
        zoneOutbox: address('11'),
        earnRouter: address('12'),
      },
      runtimeCodeHashes: {
        ...record().runtimeCodeHashes,
        zonePortal: codeHash,
        zoneMessenger: codeHash,
        earnRouter: codeHash,
      },
      actions: {
        ...record().actions,
        'deploy-router': {
          completedAt: '2026-01-01T00:00:00.000Z',
          verification: 'broadcast',
          transactions: [transaction],
        },
      },
    })
    expect(parseEarnDeploymentRecord(deployed, zoneProfile).target).toEqual(deployed.target)
    const invalidZoneTarget = structuredClone(deployed) as unknown as {
      target: { zone: Record<string, unknown> }
    }
    invalidZoneTarget.target.zone.genesisHash = `0x${'5'.repeat(64)}`
    expect(() => parseEarnDeploymentRecord(invalidZoneTarget, zoneProfile)).toThrow(
      'target.zone.genesisHash is not supported',
    )
  })

  test('rejects different deployment intent', () => {
    const root = mkdtempSync(join(tmpdir(), 'earn-record-'))
    const profilePath = join(root, 'profile.json')
    try {
      writeFileSync(
        profileDeploymentPath(profilePath),
        JSON.stringify(record({ deploymentIntentHash: 'stale' })),
      )
      expect(() => loadProfileDeploymentRecord(profilePath, profile)).toThrow('does not match')
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('loads an existing core for deployment-only reconciliation when boost rewards are added', () => {
    const {
      ownerExplicit: _ownerExplicit,
      factories: _factories,
      deployer: _deployer,
      access: _access,
      core: _core,
      zone: _zone,
      zoneRouter: _zoneRouter,
      ...authoredProfile
    } = profile
    const withBoost = parseEarnDeploymentProfile(
      {
        ...authoredProfile,
        boostRewards: {
          startTimestamp: 1_900_000_000,
          endTimestamp: 1_900_000_120,
          intervalSeconds: 60,
          targetAnnualRateBps: 300,
          perUserPrincipalCapAssets: '1000000',
          totalPrincipalCapAssets: '10000000',
          treasury: address('c'),
          funding: {
            wallet: address('d'),
          },
        },
      },
      { deployer: profile.deployer, factories: profile.factories },
    )
    const existing = record({
      componentDeploymentIntentHashes: componentDeploymentIntentHashes(profile),
    })
    expect(() => parseEarnDeploymentRecord(existing, withBoost)).toThrow('does not match')
    expect(
      parseEarnDeploymentRecord(existing, withBoost, 'deployment record', {
        allowPeripheryMismatch: true,
      }).addresses,
    ).toEqual(existing.addresses)
  })

  test('requires every intent component hash', () => {
    const { core: _core, ...withoutCore } = record().componentDeploymentIntentHashes
    expect(() =>
      parseEarnDeploymentRecord(
        record({ componentDeploymentIntentHashes: withoutCore as never }),
        profile,
      ),
    ).toThrow('componentDeploymentIntentHashes.core')
  })

  test('rejects a factory deployment ID other than the profile deployment', () => {
    expect(() =>
      publishProfileDeploymentRecord('/tmp/wrong-factory-id/profile.json', profile, {
        ...record(),
        source: { ...record().source, factoryDeploymentId: `0x${'6'.repeat(64)}` },
      }),
    ).toThrow('source.factoryDeploymentId does not match profile deployment')
  })
})
