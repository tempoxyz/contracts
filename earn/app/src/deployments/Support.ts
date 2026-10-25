import {
  engineDefinitions,
  type EngineKind,
  type PublicEarnStack,
} from '@tempoxyz/earn/deployments'

import type { PublicEnvironment } from '../../deployments/catalog.js'
import { actionIds, actions } from '../earn/Actions.js'
import * as Environment from './Environment.js'

/** How a user reaches EarnVault: directly, or through the Zone and its router. */
export type Access = 'public' | 'private'

/**
 * The current environment's available deployment for one engine and access path, or why there is
 * none here.
 */
export type Resolution = { deploymentId: string } | { message: string }

/** Resolves one engine and access path across the public environment catalog. */
export function resolve(options: resolve.Options): Resolution {
  const candidates = options.environments.flatMap((environment) =>
    environment.stacks
      .filter(
        (deployment) =>
          deployment.engineKind === options.engine &&
          supportsAccess(deployment, options.access) &&
          actionIds.some((action) => actions[action].available(deployment.capabilities)),
      )
      .map((deployment) => {
        const mode =
          options.access === 'public' ? deployment.modes.public : deployment.modes.private
        return {
          available: mode?.availability === 'available',
          current: environment.id === options.environmentId,
          deploymentId: deployment.id,
          environmentLabel: Environment.displayName(environment.id),
          reason: mode?.reason,
        }
      }),
  )
  const current = candidates.find((candidate) => candidate.current && candidate.available)
  if (current) return { deploymentId: current.deploymentId }

  const label = `${engineDefinitions[options.engine].label} with ${options.access} access`
  const elsewhere = [
    ...new Set(
      candidates
        .filter((candidate) => candidate.available)
        .map((candidate) => candidate.environmentLabel),
    ),
  ]
  if (elsewhere.length > 0) return { message: `${label} is available in ${list(elsewhere)}.` }
  const blocked = candidates.find((candidate) => candidate.current) ?? candidates[0]
  if (blocked) {
    return {
      message:
        blocked.reason ?? `${label} is registered but blocked in ${blocked.environmentLabel}.`,
    }
  }
  return { message: `No registered deployment supports ${label}.` }
}

export declare namespace resolve {
  type Options = {
    access: Access
    engine: EngineKind
    environmentId: string
    environments: readonly PublicEnvironment[]
  }
}

/** Whether a stack is configured for an access path; private access needs its routed Zone mode. */
export function supportsAccess(deployment: PublicEarnStack, access: Access) {
  if (access === 'public') return true
  return (
    deployment.modes.private !== undefined &&
    deployment.capabilities.privateRouting &&
    deployment.contracts.earnRouter !== undefined
  )
}

function list(values: readonly string[]) {
  if (values.length < 2) return values[0]
  if (values.length === 2) return `${values[0]} and ${values[1]}`
  return `${values.slice(0, -1).join(', ')}, and ${values.at(-1)}`
}
