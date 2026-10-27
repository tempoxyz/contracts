import type { Address, Hex } from 'viem'

import {
  deploymentAddressComponents,
  optionalPeripheryKeys,
  type IntentComponent,
} from '../core/components.js'
import { unique } from '../core/parse.js'
import type { EarnDeploymentProfile } from '../core/profile.js'
import { accessPolicyModule } from './earn/access-policy/index.js'
import { validateAccess } from './earn/access-policy/steps.js'
import { bindCore, deployCore } from './earn/core/steps.js'
import { deployEngine } from './earn/engines/steps.js'
import type {
  AuthorityStep,
  CapabilityModule,
  DeploymentStep,
} from '../../deployments/modules/module.js'
import { deployContributionController, deployMerkleDistributor } from './earn/rewards/steps.js'
import {
  authorityClient,
  fundFromFaucet,
  type AuthorityDependencies,
} from '../../deployments/modules/signer.js'
import { zoneRouterModule } from './earn/zone-router/index.js'
import { zoneRouterModeModule } from './router/index.js'
import {
  authorizeZoneRouter,
  deployZoneRouter,
  deployZoneRouterFactory,
  enableZoneRouterTokens,
  registerZoneRouterGateway,
} from './router/steps.js'
import {
  authorizeRouter,
  deployRouter,
  enableZoneTokens,
  registerZoneGateway,
} from './earn/zone-router/steps.js'

/**
 * Every deployment step, in execution order; a profile's plan is the enabled subset. Each step
 * lives in its capability's `steps.ts`, and the order interleaves capabilities.
 */
const steps = [
  deployEngine,
  deployCore,
  bindCore,
  deployRouter,
  deployZoneRouterFactory,
  deployZoneRouter,
  deployMerkleDistributor,
  validateAccess,
  deployContributionController,
  authorizeRouter,
  enableZoneTokens,
  registerZoneGateway,
  authorizeZoneRouter,
  enableZoneRouterTokens,
  registerZoneRouterGateway,
] as const

unique(
  steps.map((step) => step.id),
  'deployment step',
)

// Each created contract is recorded by exactly one step, under the component that owns it, and
// every optional periphery contract has one.
const createdOutputs = steps.flatMap((step) => {
  if (step.execution !== 'foundry' || !step.source) return []
  const { output } = step.source
  if (!(step.intent as readonly IntentComponent[]).includes(deploymentAddressComponents[output]))
    throw new Error(`${step.id} records ${output} outside its intent`)
  return [output]
})
unique(createdOutputs, 'created contract')
for (const key of optionalPeripheryKeys)
  if (!createdOutputs.includes(key)) throw new Error(`No deployment step creates ${key}`)

export type EarnDeploymentActionId = (typeof steps)[number]['id']

/** Every authority a registered step names. */
export type EarnDeploymentAuthority = (typeof steps)[number]['authority']['id']

/** The signer keys registered steps read, by environment variable; values are never exposed. */
export type SignerEnvironment = {
  [Variable in (typeof steps)[number]['authority']['signer']]?: string | undefined
}

/** A registered step, typed by its literal action ID and authority. */
export type RegisteredStep = DeploymentStep & {
  id: EarnDeploymentActionId
  authority: { id: EarnDeploymentAuthority }
}

/** Capabilities with lifecycle hooks, in the order the core lifecycle runs them. */
export const capabilityModules: readonly CapabilityModule[] = [
  accessPolicyModule,
  zoneRouterModule,
  zoneRouterModeModule,
]

/** Every step-created contract a protected EarnShare must whitelist, in step order. */
export const accessMemberContracts = steps.flatMap((step) =>
  step.execution === 'foundry' && step.source?.accessMember
    ? [
        {
          step: step as RegisteredStep,
          output: step.source.output,
          member: step.source.accessMember,
        },
      ]
    : [],
)

/** The registered steps. */
export const deploymentSteps: readonly RegisteredStep[] = steps

export function deploymentStep(id: EarnDeploymentActionId): RegisteredStep {
  const step = deploymentSteps.find((candidate) => candidate.id === id)
  if (!step) throw new Error(`Unknown deployment step ${id}`)
  return step
}

export function authorityStep(id: EarnDeploymentActionId): AuthorityStep & RegisteredStep {
  const step = deploymentStep(id)
  if (step.execution !== 'authority') throw new Error(`${id} is not an authority action`)
  return step
}

/**
 * The enabled authority steps whose configured signer proves, with read-only calls, that it holds
 * the step's authority. Planning reports the rest as handoffs.
 */
export async function provenSigners(options: {
  environment: NodeJS.ProcessEnv
  profile: EarnDeploymentProfile
  rpcUrl: string
}) {
  const proven = new Set<EarnDeploymentActionId>()
  for (const step of deploymentSteps) {
    if (
      step.execution === 'authority' &&
      step.probeSigner &&
      step.enabled(options.profile) &&
      (await step.probeSigner(options))
    ) {
      proven.add(step.id)
    }
  }
  return proven
}

/** Uses an available authority signer; absence means the caller should surface the handoff. */
export async function executeAvailableAuthority(
  options: {
    action: { id: EarnDeploymentActionId }
    environment: NodeJS.ProcessEnv
    outputs: Record<string, Address>
    profile: EarnDeploymentProfile
    rpcUrl: string
  },
  dependencies: Partial<AuthorityDependencies> = {},
): Promise<{ transactions: Hex[] } | undefined> {
  const step = deploymentStep(options.action.id)
  if (step.execution !== 'authority') return undefined
  return step.execute(options, { authorityClient, fundFromFaucet, ...dependencies })
}
