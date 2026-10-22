import {
  configuredZoneChain as sharedZoneChain,
  hostedEnvironment,
  hostedEnvironments,
  type HostedEnvironmentId,
} from '@tempoxyz/earn/deployments'
import { loadDeploymentEnvironment, profileRepositoryRoot } from '@tempoxyz/earn/deployments/node'
import type { EarnStack } from '@tempoxyz/earn/deployments/operations'

/** One hosted E2E environment per `hostedEnvironments` entry; its facts stay in that table. */
const hostedDefinitions = Object.fromEntries(
  Object.keys(hostedEnvironments).map((id) => [
    id,
    { id, provider: 'hosted', pollingIntervalMs: 2_000 },
  ]),
) as {
  [Id in HostedEnvironmentId]: {
    readonly id: Id
    readonly provider: 'hosted'
    readonly pollingIntervalMs: number
  }
}

export const environmentDefinitions = {
  /** An existing non-hosted L1 and Zone carrying a fresh localnet stack; see `harness/devnet.ts`. */
  devnet: { id: 'devnet', provider: 'hosted', pollingIntervalMs: 2_000 },
  local: {
    id: 'local',
    provider: 'local',
    pollingIntervalMs: 250,
  },
  ...hostedDefinitions,
} as const

export type E2eEnvironmentId = keyof typeof environmentDefinitions
export type E2eEnvironmentDefinition = (typeof environmentDefinitions)[E2eEnvironmentId]
/** The hosted environment of a deployed profile's chain; any other chain fails. */
export function hostedEnvironmentId(chainId: number): HostedEnvironmentId {
  const environment = hostedEnvironment(chainId)
  if (!environment) {
    const ids = Object.keys(hostedEnvironments).join(', ')
    throw new Error(`Hosted E2E supports ${ids}; got chain ${chainId}`)
  }
  return environment.id
}

/**
 * Profile E2E loads only the dotenv paired with the authored profile ID, beside the repository that
 * owns the profile, failing when neither it nor the process environment supplies a `required` value.
 */
export function loadProfileRuntimeConfig(
  profilePath: string,
  profileId: string,
  required: readonly string[] = [],
) {
  return loadDeploymentEnvironment(
    profileRepositoryRoot(profilePath),
    profileId,
    process.env,
    required,
  )
}

export function configuredZoneChain(deployment: Pick<EarnStack, 'network'>) {
  const zone = deployment.network.zone
  if (!zone) throw new Error(`Deployment network ${deployment.network.name} has no Zone target`)
  return sharedZoneChain({ sourceId: deployment.network.chainId, zone })
}
