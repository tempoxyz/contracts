import { readFileSync } from 'node:fs'
import { parseEnv } from 'node:util'

import { configuredZone } from '@tempoxyz/contracts/deployments/operations'
import {
  envPrivateKey,
  loadHostedProfileStack,
  missingZoneRpcError,
  zoneRpcConfiguration,
} from '@tempoxyz/contracts/deployments/node'
import { inspectZone } from '@tempoxyz/contracts/tempo/zone'
import { concat, createPublicClient, http, keccak256, stringify, stringToHex, type Hex } from 'viem'
import {
  loadOptionalProfileFixture,
  validateProfileFixtureRuntime,
} from '../fixtures/profile-fixture.js'
import { ensureFeeBalance } from './support/funding.js'
import {
  createDeploymentPublicClient,
  createE2eContext,
  e2eActors,
  type E2eActor,
  type E2eContext,
} from './context.js'
import { environmentDefinitions, loadProfileRuntimeConfig } from './environments.js'
import type { LoadedProfile } from './profile.js'
import { sha256 } from './results.js'
import { validateDeployment } from './validate.js'

const SECP256K1_ORDER = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n

/**
 * The negative-test outsider for configured runs. Hosted runs top up every fee actor, so a committed
 * key would leak real PATHUSD on mainnet; deriving it from the operator key keeps it private, stable
 * across runs, and recoverable. It is a fresh account that no access policy admits.
 */
export function derivedOutsiderPrivateKey(operator: Hex): Hex {
  const key = keccak256(concat([operator, stringToHex('tempo-earn:e2e-outsider:v1')]))
  const scalar = BigInt(key)
  if (scalar === 0n || scalar >= SECP256K1_ORDER) throw new Error('Derived outsider key is invalid')
  return key
}

/**
 * Loads one deployed profile as a hosted E2E target: its environment, runtime configuration, and a
 * stack built from its generated record and live reads. Hosted E2E has no other deployment source.
 * `required` names runtime values that must come from `.env.<profile-id>` or the environment.
 */
async function loadProfileDeployment(
  loaded: LoadedProfile,
  required: readonly string[],
  requireZoneRpc: boolean,
) {
  const values = loadProfileRuntimeConfig(loaded.path, loaded.profile.id, required)
  const profileZone = configuredZone(loaded.profile)
  const zoneRpc = profileZone ? zoneRpcConfiguration(profileZone.chainId, values) : undefined
  if (requireZoneRpc && profileZone && !zoneRpc?.url) {
    throw missingZoneRpcError(
      profileZone,
      'pnpm e2e:profile --validate-only checks everything else.',
    )
  }
  const { bundle, environment, stack, tempo } = await loadHostedProfileStack(loaded.path, values)
  const definition = environmentDefinitions[environment.id]
  const fixture = loadOptionalProfileFixture(loaded.path, bundle.profile, bundle.record)
  // Without a fixture, a Zone profile converts through its customer-owned pool and E2E consumes
  // prefunded actors.
  const stablecoinFixture =
    fixture?.record.stablecoinFixture ??
    (profileZone
      ? {
          baseAsset: stack.contracts.asset,
          alternateAsset: profileZone.privateAsset,
          venue: stack.contracts.venue,
          funder: null,
        }
      : undefined)
  const deployment = stablecoinFixture ? { ...stack, stablecoinFixture } : stack
  return {
    bundle,
    values,
    definition,
    deployment,
    environment: environment.id,
    fixture: fixture?.record,
    tempo,
    zoneRpc: zoneRpc?.url ? { ...zoneRpc, url: zoneRpc.url } : undefined,
  }
}

/**
 * The read-only checks every hosted run passes before it signs anything: the shared deployment
 * inspection, the fixture's live provenance, and E2E's own stack assumptions. With Zone RPC access
 * configured it also inspects the profile's live Zone graph through that RPC; without it, a Zone
 * profile reports `Zone` in `unverified`, or fails with `requireZoneRpc`. It never resolves a
 * signer, funds an actor, or sends a transaction.
 */
export async function validateHostedProfile(
  loaded: LoadedProfile,
  required: readonly string[] = [],
  requireZoneRpc = false,
) {
  const loadedDeployment = await loadProfileDeployment(loaded, required, requireZoneRpc)
  const { bundle, definition, deployment, fixture, tempo, zoneRpc } = loadedDeployment
  const client = createDeploymentPublicClient(deployment, {
    environment: definition,
    headers: tempo.headers,
  })
  if (fixture) await validateProfileFixtureRuntime(client, fixture)
  await validateDeployment(client, deployment, bundle)
  const zone = configuredZone(bundle.profile)
  if (zone && zoneRpc) {
    const inspected = await inspectZone({
      id: zone.id,
      chainId: zone.chainId,
      l1Client: client,
      zoneClient: createPublicClient({
        transport: http(zoneRpc.url, {
          fetchOptions: { headers: zoneRpc.headers },
          timeout: 60_000,
        }),
      }),
    })
    console.log(`Zone ${zone.id} · ${stringify(inspected)}`)
  }
  return { ...loadedDeployment, unverified: zone && !zoneRpc ? ['Zone'] : [] }
}

export async function runHosted<Result>(
  loaded: LoadedProfile,
  execute: (context: E2eContext, manifest: { sha256: string; source: string }) => Promise<Result>,
  options: runHosted.Options = {},
) {
  const identities = options.identities ?? 'configured'
  const {
    bundle,
    values,
    definition,
    deployment,
    fixture,
    tempo,
    zoneRpc: zone,
  } = await validateHostedProfile(
    loaded,
    identities === 'configured' ? ['DEPLOYER_PRIVATE_KEY'] : [],
    options.requireZoneRpc ?? true,
  )
  if (zone && deployment.network.zone) deployment.network.zone.rpcUrl = zone.url
  const { defaulted, ...privateKeys } = resolveHostedPrivateKeys(values, identities)
  if (identities === 'configured' && defaulted.length > 0) {
    console.info(`E2E ${defaulted.join(' and ')} signs with DEPLOYER_PRIVATE_KEY`)
  }
  const context = createE2eContext({
    deployment,
    environment: definition,
    privateKeys,
    rpcHeaders: { tempo: tempo.headers, zone: zone?.headers },
    engineFixtures: fixture?.engineFixtures,
  })
  const actors = options.fundFeeActors ?? e2eActors
  for (const account of new Set(actors.map((actor) => context[actor].address))) {
    await ensureFeeBalance(context, account)
  }
  return await execute(context, {
    sha256: sha256(readFileSync(bundle.recordPath, 'utf8')),
    source: bundle.recordPath,
  })
}

export declare namespace runHosted {
  type Options = {
    identities?: 'configured' | 'public-fixture' | undefined
    /** Accounts topped up for fees; every actor unless a benchmark signs only as the user. */
    fundFeeActors?: readonly E2eActor[] | undefined
    /**
     * Whether a Zone profile needs Zone RPC access before anything runs; only a run that never
     * touches the Zone, such as the public benchmark, opts out.
     */
    requireZoneRpc?: boolean | undefined
  }
}

/**
 * Resolves hosted signers. The operator is `DEPLOYER_PRIVATE_KEY`; the access administrator and
 * positive user are the operator unless `EARN_ACCESS_ADMIN_PRIVATE_KEY` or `END_USER_PRIVATE_KEY`
 * names a distinct key, and `defaulted` lists the roles that use the operator key. Public-fixture
 * runs sign every role with the committed `.env.example` deployer key.
 */
export function resolveHostedPrivateKeys(
  values: NodeJS.ProcessEnv,
  identities: NonNullable<runHosted.Options['identities']> = 'configured',
) {
  const source =
    identities === 'public-fixture'
      ? parseEnv(readFileSync(new URL('../../.env.example', import.meta.url), 'utf8'))
      : values
  const operator = envPrivateKey(source, 'DEPLOYER_PRIVATE_KEY', { required: true })
  const accessAdministrator =
    identities === 'configured' ? envPrivateKey(source, 'EARN_ACCESS_ADMIN_PRIVATE_KEY') : undefined
  const user =
    identities === 'configured' ? envPrivateKey(source, 'END_USER_PRIVATE_KEY') : undefined
  return {
    accessAdministrator: accessAdministrator ?? operator,
    defaulted: [
      ...(accessAdministrator ? [] : ['access administrator']),
      ...(user ? [] : ['user']),
    ],
    operator,
    outsider: derivedOutsiderPrivateKey(operator),
    user: user ?? operator,
  }
}
