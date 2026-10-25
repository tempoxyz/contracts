/**
 * Builds the browser catalog from the completed profiles `catalog` lists per environment and
 * writes `generated.json`. Each stack comes from the shared hosted-profile loader over the
 * profile's verified record and public RPC reads; the deployment must pass the same inspection as
 * `pnpm earn verify`, and every capability must report ready. It sends no transaction and needs
 * no key; rerun after a listed profile is redeployed.
 */
import { execFileSync } from 'node:child_process'
import { renameSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { createPublicClient, getAddress, http } from 'viem'
import { Addresses } from 'viem/tempo'
import {
  configuredTempoNetworkChain,
  hostedEnvironments,
  publicStack,
  tempoApiRpcUrl,
  type HostedEnvironment,
  type HostedEnvironmentId,
  type ZoneConfiguration,
} from '@tempoxyz/earn/deployments'
import { inspectEarnDeployment, loadHostedProfileStack } from '@tempoxyz/earn/deployments/node'
import { inspectZone, missingZoneTokens } from '@tempoxyz/earn/tempo/zone'

import { parsePublicEnvironmentCatalog, type CatalogStack } from './catalog.js'
import { privateRouteAsset, readMetadata } from './tokens.js'

/** One hosted environment: whether it shows its hosted Zone, and the listed profiles. */
type CatalogEnvironment = {
  /** Includes the environment's Tempo-owned hosted Zone from `hostedEnvironments`. */
  zone?: true | undefined
  /** Profile ID to description; the first is the environment's default stack. */
  stacks: Record<string, string>
}

/** The catalog's only input: the default environment and the profiles each environment lists. */
const catalog = {
  defaultEnvironmentId: 'moderato',
  environments: {
    moderato: {
      zone: true,
      stacks: {
        'app-moderato': 'Canonical customer-agnostic Tempo Earn stack.',
        'veda-moderato': 'Tempo Earn test stack over a Tempo-owned Veda-compatible PATHUSD vault.',
      },
    },
  },
} satisfies {
  defaultEnvironmentId: HostedEnvironmentId
  environments: Partial<Record<HostedEnvironmentId, CatalogEnvironment>>
}

const pathUsd = getAddress(Addresses.pathUsd)
const outputPath = fileURLToPath(new URL('generated.json', import.meta.url))
const profilesRoot = new URL('../../profiles/', import.meta.url)

type Client = ReturnType<typeof environmentClient>

const environments: unknown[] = []
for (const [id, environment] of Object.entries(catalog.environments)) {
  environments.push(await environmentCatalog(id as HostedEnvironmentId, environment))
}
const parsed = parsePublicEnvironmentCatalog({
  defaultEnvironmentId: catalog.defaultEnvironmentId,
  environments,
})
const temporary = `${outputPath}.tmp`
writeFileSync(temporary, `${JSON.stringify(parsed, null, 2)}\n`)
renameSync(temporary, outputPath)
execFileSync('vp', ['fmt', outputPath], { stdio: 'inherit' })
console.log(`Wrote ${outputPath}`)

function environmentClient(network: HostedEnvironment) {
  return createPublicClient({
    chain: configuredTempoNetworkChain(network),
    transport: http(network.rpcUrl, { timeout: 60_000 }),
  })
}

async function environmentCatalog(id: HostedEnvironmentId, environment: CatalogEnvironment) {
  const hosted = hostedEnvironments[id]
  const client = environmentClient(hosted)
  if ((await client.getChainId()) !== hosted.chainId)
    throw new Error(`${id} RPC does not serve its chain`)
  const network = {
    name: id,
    chainId: hosted.chainId,
    rpcUrl: hosted.rpcUrl,
    explorerUrl: hosted.explorerUrl,
    pathUsd,
    zone: environment.zone ? await networkZone(client, id, hosted.zone) : undefined,
  }
  const stacks: CatalogStack[] = []
  for (const [profileId, description] of Object.entries(environment.stacks)) {
    stacks.push(await listedStack(client, network, profileId, description))
  }
  return { id, network, defaultStackId: stacks[0]?.id, stacks }
}

/**
 * Discovers the environment Zone's Portal and sequencers from the L1 ZoneFactory. Private fees are
 * paid in PATHUSD, so its Portal must enable PATHUSD.
 */
async function networkZone(
  client: Client,
  name: string,
  zone: { id: number; chainId: number },
): Promise<ZoneConfiguration> {
  const descriptor = await inspectZone({ ...zone, l1Client: client })
  const [disabled] = await missingZoneTokens(client, descriptor.portal, [['PATHUSD', pathUsd]])
  if (disabled) throw new Error(`Zone ${descriptor.id} has not enabled PATHUSD`)
  return {
    name,
    id: descriptor.id,
    chainId: descriptor.chainId,
    rpcUrl: tempoApiRpcUrl(descriptor.chainId),
    portal: descriptor.portal,
    messenger: descriptor.messenger,
    sequencers: descriptor.sequencers,
  }
}

async function listedStack(
  client: Client,
  network: { name: string; zone?: ZoneConfiguration },
  profileId: string,
  description: string,
): Promise<CatalogStack> {
  const { bundle, environment, stack } = await loadHostedProfileStack(
    fileURLToPath(new URL(`${profileId}/profile.json`, profilesRoot)),
    {},
  )
  const { profile, record } = bundle
  if (environment.id !== network.name) {
    throw new Error(`Profile ${profile.id} does not target ${network.name}`)
  }
  if (record.addresses.asset !== pathUsd) {
    throw new Error(`Profile ${profile.id} must deposit canonical PATHUSD`)
  }
  const zone = stack.network.zone
  if (zone && (zone.id !== network.zone?.id || zone.portal !== network.zone.portal)) {
    throw new Error(`Profile ${profile.id} routes through a Zone ${network.name} does not list`)
  }
  const blockers = Object.values(
    await inspectEarnDeployment(client, profile, record.addresses),
  ).flatMap((readiness) => (readiness.status === 'blocked' ? readiness.blockers : []))
  if (blockers.length > 0) {
    throw new Error(`${stack.id} is not ready: ${blockers.join('; ')}.`)
  }
  // The browser implements no queued exits, so the catalog never advertises them.
  const listed = publicStack(
    { ...stack, capabilities: { ...stack.capabilities, asyncRedeem: false } },
    description,
  )
  const privateAsset = privateRouteAsset(listed)
  return {
    ...listed,
    privateAssetMetadata: privateAsset ? await readMetadata(client, privateAsset) : undefined,
  }
}
