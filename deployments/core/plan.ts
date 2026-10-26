import {
  deploymentSteps,
  type EarnDeploymentActionId,
  type EarnDeploymentAuthority,
  type SignerEnvironment,
} from '../../deployments/modules/index.js'
import { stepSignerAvailable } from '../../deployments/modules/module.js'
import { type EarnDeploymentProfile } from './profile.js'

export type { EarnDeploymentActionId } from '../../deployments/modules/index.js'

export type EarnDeploymentAction = {
  id: EarnDeploymentActionId
  authority: EarnDeploymentAuthority
  execution: 'foundry' | 'authority'
  summary: string
}

/** The plan is always derived from the reviewed profile; it is never a second authored document. */
export function planEarnDeployment(profile: EarnDeploymentProfile): EarnDeploymentAction[] {
  return deploymentSteps
    .filter((step) => step.enabled(profile))
    .map(({ id, authority, execution, summary }) => ({
      id,
      authority: authority.id,
      execution,
      summary,
    }))
}

export type PresentedEarnDeploymentAction = Omit<EarnDeploymentAction, 'execution'> & {
  execution: EarnDeploymentAction['execution'] | 'handoff'
}

/** Describes what the current environment can execute, without reading or exposing key material. */
export function presentEarnDeploymentPlan(
  profile: EarnDeploymentProfile,
  environment: SignerEnvironment,
  provenSigners: ReadonlySet<EarnDeploymentActionId> = new Set(),
): PresentedEarnDeploymentAction[] {
  return deploymentSteps
    .filter((step) => step.enabled(profile))
    .map((step) => {
      const action = {
        id: step.id,
        authority: step.authority.id,
        execution: step.execution,
        summary: step.summary,
      }
      if (
        step.execution !== 'authority' ||
        stepSignerAvailable(step, profile, environment, provenSigners.has(step.id))
      ) {
        return action
      }
      return { ...action, execution: 'handoff' as const, summary: step.handoffSummary }
    })
}

/** Actions required to publish an immutable, source-verified deployment record. */
export function deploymentActions(profile: EarnDeploymentProfile) {
  return planEarnDeployment(profile).filter((action) => phaseOf(action.id) === 'deployment')
}

/** Mutable external readiness reconciled after the deployment record is available. */
export function activationActions(profile: EarnDeploymentProfile) {
  return planEarnDeployment(profile).filter((action) => phaseOf(action.id) === 'activation')
}

function phaseOf(id: EarnDeploymentActionId) {
  return deploymentSteps.find((step) => step.id === id)!.phase
}
