import { existsSync, readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

import {
  configuredZone,
  type EarnDeploymentProfile,
} from '@tempoxyz/contracts/deployments/operations'
import type { EarnDeploymentRecord } from '@tempoxyz/contracts/deployments/node'
import { address, exactKeys, isBytes32, object } from '@tempoxyz/contracts/deployments'
import { getAddress, keccak256, type Address, type Hex } from 'viem'
import type { DeploymentPublicClient } from '../harness/context.js'

/** Disposable E2E stablecoin pair and the infrastructure provisioned around it. */
export type StablecoinFixture = {
  /** EarnVault asset. */
  baseAsset: Address
  /** Private Zone asset that the router converts 1:1 with the base asset. */
  alternateAsset: Address
  /** ERC-4626 venue whose asset is the base asset. */
  venue: Address
  /** Present only when the fixture provisioned the router's DirectPropAMM conversion pool. */
  conversionPool?:
    | {
        pool: Address
        /** The pool's price oracle. */
        oracle: Address
        /** Nonzero lowercase 32-byte pool route identifier used by the router profile. */
        customerId: Hex
      }
    | undefined
  /** Fixture token funder; null when E2E consumes explicitly prefunded actors. */
  funder: Address | null
}

/** Parses a `StablecoinFixture`; unknown keys are rejected. */
function parseStablecoinFixture(value: unknown, label: string): StablecoinFixture {
  const fixture = object(value, label)
  exactKeys(fixture, label, ['baseAsset', 'alternateAsset', 'venue', 'funder'], ['conversionPool'])
  const baseAsset = address(fixture.baseAsset, `${label}.baseAsset`)
  const alternateAsset = address(fixture.alternateAsset, `${label}.alternateAsset`)
  if (baseAsset === alternateAsset) {
    throw new Error(`${label}.alternateAsset must differ from baseAsset`)
  }
  let conversionPool: StablecoinFixture['conversionPool']
  if (fixture.conversionPool !== undefined) {
    const pool = object(fixture.conversionPool, `${label}.conversionPool`)
    exactKeys(pool, `${label}.conversionPool`, ['pool', 'oracle', 'customerId'])
    conversionPool = {
      pool: address(pool.pool, `${label}.conversionPool.pool`),
      oracle: address(pool.oracle, `${label}.conversionPool.oracle`),
      customerId: customerId(pool.customerId, `${label}.conversionPool.customerId`),
    }
  }
  return {
    baseAsset,
    alternateAsset,
    venue: address(fixture.venue, `${label}.venue`),
    ...(conversionPool ? { conversionPool } : {}),
    funder: fixture.funder === null ? null : address(fixture.funder, `${label}.funder`),
  }
}

/** Named contracts a stablecoin fixture provisions or binds, in a stable order. */
function stablecoinFixtureContracts(
  fixture: StablecoinFixture,
): [StablecoinFixtureContract, Address][] {
  const contracts: [StablecoinFixtureContract, Address][] = [
    ['baseAsset', fixture.baseAsset],
    ['alternateAsset', fixture.alternateAsset],
    ['venue', fixture.venue],
  ]
  if (fixture.funder) contracts.push(['funder', fixture.funder])
  if (fixture.conversionPool) {
    contracts.push(['pool', fixture.conversionPool.pool], ['oracle', fixture.conversionPool.oracle])
  }
  return contracts
}

type StablecoinFixtureContract =
  | 'baseAsset'
  | 'alternateAsset'
  | 'venue'
  | 'funder'
  | 'pool'
  | 'oracle'

function customerId(value: unknown, label: string): Hex {
  if (typeof value !== 'string' || !/^0x[0-9a-f]{64}$/.test(value) || /^0x0{64}$/.test(value)) {
    throw new Error(`${label} must be a nonzero lowercase 32-byte hex string`)
  }
  return value as Hex
}

/**
 * Generated provenance for disposable infrastructure that a profile fixture command created. The
 * optional `stablecoinFixture` follows the stack schema, the optional `engineFixtures` names
 * engine-specific fixture contracts as localnet does, at least one is present, and
 * `runtimeCodeHashes` names exactly the contracts of both.
 */
export type ProfileFixtureRecord = {
  version: 1
  profileId: string
  chainId: number
  genesisHash: Hex
  generatedAt: string
  /** Salt of the stablecoin bootstrap. */
  saltNonce?: string
  stablecoinFixture?: StablecoinFixture
  engineFixtures?: Record<string, Address>
  runtimeCodeHashes: Record<string, Hex>
  transactions: Hex[]
}

/** A profile's test fixture record sits beside its `profile.json`. */
export function profileFixturePath(profilePath: string) {
  return resolve(dirname(profilePath), 'fixture.json')
}

export function loadOptionalProfileFixture(
  profilePath: string,
  profile: EarnDeploymentProfile,
  deployment: EarnDeploymentRecord,
) {
  const path = profileFixturePath(profilePath)
  if (!existsSync(path)) return undefined
  const record = parseProfileFixtureRecord(JSON.parse(readFileSync(path, 'utf8')))
  validateProfileFixtureRecord(record, profile, deployment)
  return { path, record }
}

export function parseProfileFixtureRecord(value: unknown): ProfileFixtureRecord {
  const record = object(value, 'profile fixture')
  exactKeys(
    record,
    'profile fixture',
    [
      'version',
      'profileId',
      'chainId',
      'genesisHash',
      'generatedAt',
      'runtimeCodeHashes',
      'transactions',
    ],
    ['saltNonce', 'stablecoinFixture', 'engineFixtures'],
  )
  if (record.stablecoinFixture === undefined && record.engineFixtures === undefined) {
    throw new Error('Profile fixture requires stablecoinFixture or engineFixtures')
  }
  if (record.version !== 1) throw new Error('Profile fixture version must be 1')
  if (typeof record.profileId !== 'string' || record.profileId.length === 0) {
    throw new Error('Profile fixture profileId is required')
  }
  if (!Number.isSafeInteger(record.chainId) || Number(record.chainId) <= 0) {
    throw new Error('Profile fixture chainId must be a positive integer')
  }
  if (typeof record.generatedAt !== 'string' || Number.isNaN(Date.parse(record.generatedAt))) {
    throw new Error('Profile fixture generatedAt must be an ISO timestamp')
  }
  if (
    record.saltNonce !== undefined &&
    (typeof record.saltNonce !== 'string' || !/^\d+$/.test(record.saltNonce))
  ) {
    throw new Error('Profile fixture saltNonce must be an unsigned integer string')
  }
  const stablecoinFixture =
    record.stablecoinFixture === undefined
      ? undefined
      : parseStablecoinFixture(record.stablecoinFixture, 'stablecoinFixture')
  const engineFixtures =
    record.engineFixtures === undefined
      ? undefined
      : Object.fromEntries(
          Object.entries(object(record.engineFixtures, 'engineFixtures')).map(([name, entry]) => [
            name,
            address(entry, `engineFixtures.${name}`),
          ]),
        )
  const contracts = profileFixtureContracts({ stablecoinFixture, engineFixtures }).map(
    ([name]) => name,
  )
  if (new Set(contracts).size !== contracts.length) {
    throw new Error('Profile fixture engineFixtures must not reuse a stablecoin fixture name')
  }
  const hashes = object(record.runtimeCodeHashes, 'runtimeCodeHashes')
  exactKeys(hashes, 'runtimeCodeHashes', contracts)
  if (!Array.isArray(record.transactions)) {
    throw new Error('Profile fixture transactions is required')
  }
  if (record.transactions.length === 0) {
    throw new Error('Profile fixture transactions must be nonempty')
  }
  return {
    version: 1,
    profileId: record.profileId,
    chainId: Number(record.chainId),
    genesisHash: hash(record.genesisHash, 'genesisHash'),
    generatedAt: record.generatedAt,
    ...(record.saltNonce === undefined ? {} : { saltNonce: record.saltNonce as string }),
    ...(stablecoinFixture ? { stablecoinFixture } : {}),
    ...(engineFixtures ? { engineFixtures } : {}),
    runtimeCodeHashes: Object.fromEntries(
      contracts.map((name) => [name, hash(hashes[name], `runtimeCodeHashes.${name}`)]),
    ),
    transactions: record.transactions.map((transaction, index) =>
      hash(transaction, `transactions[${index}]`),
    ),
  }
}

/** Every named contract a fixture record provisions or binds, in a stable order. */
export function profileFixtureContracts(
  fixture: Pick<ProfileFixtureRecord, 'stablecoinFixture' | 'engineFixtures'>,
): [string, Address][] {
  return [
    ...(fixture.stablecoinFixture ? stablecoinFixtureContracts(fixture.stablecoinFixture) : []),
    ...Object.entries(fixture.engineFixtures ?? {}),
  ]
}

function validateProfileFixtureRecord(
  fixture: ProfileFixtureRecord,
  profile: EarnDeploymentProfile,
  deployment: EarnDeploymentRecord,
) {
  if (fixture.profileId !== profile.id) {
    throw new Error(`Profile fixture ${fixture.profileId} does not belong to ${profile.id}`)
  }
  if (fixture.chainId !== profile.chainId) {
    throw new Error(`Profile fixture for ${profile.id} targets chain ${fixture.chainId}`)
  }
  if (fixture.genesisHash !== deployment.target.genesisHash) {
    throw new Error(`Profile fixture ${profile.id} does not match the deployment genesis`)
  }
  const stablecoins = fixture.stablecoinFixture
  const zone = configuredZone(profile)
  if (!stablecoins) {
    // Without test stablecoins the stack runs on its deployed asset, and a route needs a fixture.
    if (zone) throw new Error(`Profile fixture ${profile.id} needs a stablecoin fixture route`)
    return
  }
  // An existing engine's venue is read from the engine; hosted validation compares it.
  if ('venue' in profile.engine && getAddress(profile.engine.venue) !== stablecoins.venue) {
    throw new Error(`Profile fixture ${profile.id} venue does not match the profile`)
  }
  if (
    zone &&
    (getAddress(zone.privateAsset) !== stablecoins.alternateAsset ||
      !stablecoins.conversionPool ||
      !zone.pool ||
      getAddress(zone.pool) !== stablecoins.conversionPool.pool ||
      zone.customerId.toLowerCase() !== stablecoins.conversionPool.customerId)
  ) {
    throw new Error(`Profile fixture ${profile.id} route does not match the profile`)
  }
  const deployedAsset = deployment.addresses.asset
  if (!deployedAsset || getAddress(deployedAsset) !== stablecoins.baseAsset) {
    throw new Error(`Profile fixture ${profile.id} base asset does not match the deployment`)
  }
}

/** Rejects a fixture whose checked-in runtime provenance no longer matches the live contracts. */
export async function validateProfileFixtureRuntime(
  client: DeploymentPublicClient,
  fixture: ProfileFixtureRecord,
) {
  const genesis = await client.getBlock({ blockNumber: 0n })
  if (genesis.hash !== fixture.genesisHash) {
    throw new Error(`Profile fixture ${fixture.profileId} does not match the live genesis`)
  }
  await Promise.all(
    profileFixtureContracts(fixture).map(async ([name, address]) => {
      const code = await client.getCode({ address })
      if (!code || code === '0x') throw new Error(`Profile fixture ${name} has no runtime code`)
      if (keccak256(code) !== fixture.runtimeCodeHashes[name]) {
        throw new Error(`Profile fixture ${name} runtime code does not match its record`)
      }
    }),
  )
}

function hash(value: unknown, label: string): Hex {
  if (!isBytes32(value)) throw new Error(`${label} must be a 32-byte hash`)
  return value
}
