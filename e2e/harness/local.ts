import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { toHex } from 'viem'

import { Environment, localStack } from 'localnet'
import type { Deployment as LocalDeployment } from 'localnet'
import {
  createDeploymentPublicClient,
  createE2eContext,
  type E2eContext,
  type E2eStack,
} from './context.js'
import { environmentDefinitions, type E2eEnvironmentDefinition } from './environments.js'
import type { LoadedProfile } from './profile.js'
import { sha256, type SourceState } from './results.js'
import { validateDeployment } from './validate.js'

const e2eRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const root = dirname(e2eRoot)
const localDirectory = resolve(e2eRoot, '.local')

/**
 * Runs the cases against a disposable stack. With a profile, localnet deploys that profile's
 * settings, and the required cases come from the localized profile it deployed, so
 * environment-specific values such as the TIP-403 policy ID are the local equivalents.
 */
export async function runLocal<Result>(
  source: SourceState,
  engineKind: LocalDeployment.EngineKind,
  profile: LoadedProfile | undefined,
  execute: (
    context: E2eContext,
    manifest: { sha256: string; source: string },
    profile: LoadedProfile | undefined,
  ) => Promise<Result>,
) {
  return await Environment.run({
    consumer: 'E2E integration suite',
    engineKind,
    earnProfile: profile?.profile,
    ready: (environment) => runOnStack(environment, source, profile, execute),
  })
}

/**
 * Checks the stack localnet deployed and verified, then runs the cases on it. Devnet runs share
 * this path with the stack localnet deployed onto their existing chains.
 */
export async function runOnStack<Result>(
  environment: Environment.State,
  source: SourceState,
  profile: LoadedProfile | undefined,
  execute: (
    context: E2eContext,
    manifest: { sha256: string; source: string },
    profile: LoadedProfile | undefined,
  ) => Promise<Result>,
  definition: E2eEnvironmentDefinition = environmentDefinitions.local,
) {
  const deployment = localDeployment(environment, source, definition.id)
  await validateDeployment(
    createDeploymentPublicClient(deployment, { environment: definition }),
    deployment,
  )
  const { accounts } = environment
  const context = createE2eContext({
    deployment,
    environment: definition,
    privateKeys: {
      user: accounts.user.privateKey,
      operator: accounts.deployer.privateKey,
      outsider: accounts.outsider.privateKey,
      accessAdministrator: accounts.accessAdministrator.privateKey,
    },
    zoneSubmissionRpcUrl: environment.zone.publicRpcUrl,
    engineFixtures: environment.deployment.engineFixtures,
  })
  const deploymentPath = resolve(
    localDirectory,
    `deployment-${definition.id}-${environment.deployment.earnProfile.id}.json`,
  )
  const manifestSource = `${JSON.stringify(deployment, null, 2)}\n`
  mkdirSync(localDirectory, { recursive: true })
  writeFileSync(deploymentPath, manifestSource)
  console.log(`\nE2E deployment · ${relative(root, deploymentPath)}\n`)
  // Cases run against the localized profile localnet actually deployed.
  return await execute(
    context,
    { sha256: sha256(manifestSource), source: deploymentPath },
    profile && { ...profile, profile: environment.deployment.earnProfile },
  )
}

function localDeployment(
  environment: Pick<Environment.State, 'deployment' | 'l1' | 'zone'>,
  source: SourceState,
  name: E2eEnvironmentDefinition['id'],
): E2eStack & { local: Record<string, string> } {
  const { deployment } = environment
  return {
    ...localStack(environment, { name }),
    metadata: {
      sourceCommit: source.commit,
      sourceTreeDirty: source.dirty,
      generatedAt: new Date().toISOString(),
      deployedAtBlock: toHex(deployment.deployedAtBlock),
      transactions: deployment.transactions,
    },
    stablecoinFixture: {
      baseAsset: deployment.baseAsset,
      alternateAsset: deployment.alternateAsset,
      venue: deployment.vault,
      conversionPool: {
        pool: deployment.earnRouterPool.pool,
        oracle: deployment.earnRouterPool.oracle,
        customerId: deployment.earnRouterPool.customerId,
      },
      funder: deployment.stablecoinFixture,
    },
    // Provenance of the disposable chains, recorded in the manifest.
    local: { l1Image: environment.l1.image, zoneImage: environment.zone.image },
  }
}
