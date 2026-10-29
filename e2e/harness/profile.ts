import { readFileSync } from 'node:fs'

import { resolveProfilePath } from '@tempoxyz/contracts/deployments/node'
import {
  parseEarnDeploymentProfile,
  type EarnDeploymentProfile,
} from '@tempoxyz/contracts/deployments/operations'
import { sha256 } from './results.js'

/** The deployment profile an E2E run validates, with its source for result provenance. */
export type LoadedProfile = {
  path: string
  sha256: string
  profile: EarnDeploymentProfile
}

export function loadProfile(path: string): LoadedProfile {
  const absolutePath = resolveProfilePath(path)
  const source = readFileSync(absolutePath, 'utf8')
  return {
    path: absolutePath,
    sha256: sha256(source),
    profile: parseEarnDeploymentProfile(JSON.parse(source)),
  }
}

/** Whether the profile charges any fee, which the deployed EarnFees must report. */
export function profileFeesActive(profile: EarnDeploymentProfile) {
  const fees = profile.core.fees
  return (
    fees.fixed.length > 0 || (fees.protectedFixed?.rateBps ?? 0) > 0 || fees.excess !== undefined
  )
}
