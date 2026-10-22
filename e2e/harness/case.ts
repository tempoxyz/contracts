import type { DeploymentCapabilities, EngineKind } from '@tempoxyz/earn/deployments'
import type {
  DeploymentAccess,
  OptionalPeriphery,
  OptionalPeripheryKey,
} from '@tempoxyz/earn/deployments/operations'
import { e2eEngines, type E2eEngineHook } from '../engines/index.js'
import type { DeploymentPublicClient, E2eContext, E2eStack } from './context.js'
import type { E2eEnvironmentId } from './environments.js'

export type CoverageDimension =
  | 'positive'
  | 'negative'
  | 'rollback'
  | 'authorization'
  | 'recovery'
  | 'third-party'

/** What a run targets, which decides the cases it can select and the launch features it must cover. */
export type E2eTarget = {
  engineKind: EngineKind
  environment: E2eEnvironmentId
  capabilities: DeploymentCapabilities
  accessKind: DeploymentAccess['kind']
  periphery: OptionalPeriphery
  feesActive: boolean
}

/** A feature the release-blocking `--launch` suite must cover on every target it applies to. */
export type LaunchFeature = {
  dimensions: readonly CoverageDimension[]
  /** Dimensions required only under protected access, such as restoring a removed holder's exit. */
  protectedDimensions?: readonly CoverageDimension[]
  applies(target: E2eTarget): boolean
}

/** One capability module: `modules/<id>/module.ts`, whose folder name is its case group. */
export type E2eModule = {
  cases: readonly E2eCase[]
  launchFeatures?: Readonly<Record<string, LaunchFeature>>
  benchmark?: E2eBenchmark
  /** Read-only checks of what the module's cases assume, run with the stack's before any case. */
  validate?(client: DeploymentPublicClient, stack: E2eStack): Promise<void>
  /** JSON-comparable state every case must restore, captured before and after each case. */
  integrity?(context: E2eContext): Promise<unknown>
}

export type BenchmarkGroup = 'public' | 'private'

/** Times one action; the latency benchmark records it under `flow`. */
type BenchmarkMeasure = <Result>(flow: string, run: () => Promise<Result>) => Promise<Result>

/**
 * A module's part in the latency benchmark (`harness/benchmark.ts`): an untimed check before the
 * first sample of any group, and the user round trip it times for one benchmark group.
 */
export type E2eBenchmark = {
  preflight?(context: E2eContext): Promise<void>
  roundTrip?: {
    group: BenchmarkGroup
    /** One sample: setup runs untimed, and only the actions passed to `measure` are timed. */
    sample(context: E2eContext, measure: BenchmarkMeasure): Promise<void>
  }
}

export interface E2eCase {
  id: string
  description: string
  /** Compact live explanation of the path or invariant exercised by the case. */
  flow?: string | undefined
  /** Included in a run that names no selector: the acceptance cases of every compatible target. */
  default: boolean
  /** Included in the release-blocking `--launch` suite. */
  launch: boolean
  requiredCapabilities?: readonly (keyof DeploymentCapabilities)[]
  /** Requires EarnShare to use protected TIP-403 access. */
  requiresProtectedAccess?: boolean | undefined
  /** Optional periphery the deployment must record for the case to run. */
  requiredPeriphery?: readonly OptionalPeripheryKey[] | undefined
  /** Asserts that a configured fee accrues, so it runs only when the deployment's fees are active. */
  requiresActiveFees?: boolean | undefined
  /** Engine behavior the case drives, so it runs on every engine that implements it. */
  requiredEngineHooks?: readonly E2eEngineHook[]
  environments?: readonly E2eEnvironmentId[]
  coverage?: Readonly<Record<string, readonly CoverageDimension[]>>
  weight?: number
  preflight?(context: E2eContext): void | Promise<void>
  cleanup?(context: E2eContext): void | Promise<void>
  run(context: E2eContext): Promise<void>
}

export type RegisteredCase = E2eCase & { group: string }

/** Why a target cannot run a case, or undefined when it can. */
export function unsupportedReason(testCase: E2eCase, target: E2eTarget) {
  const engine = e2eEngines[target.engineKind]
  const hook = testCase.requiredEngineHooks?.find((name) => !engine[name])
  if (hook) return `needs an engine implementing ${hook}`
  if (testCase.environments && !testCase.environments.includes(target.environment)) {
    return `does not support the ${target.environment} environment`
  }
  const capability = testCase.requiredCapabilities?.find((name) => !target.capabilities[name])
  if (capability) return `needs the ${capability} capability`
  if (testCase.requiresProtectedAccess && target.accessKind !== 'tip403-whitelist') {
    return 'needs protected TIP-403 access'
  }
  const periphery = testCase.requiredPeriphery?.find((key) => !target.periphery[key])
  if (periphery) return `needs ${periphery}`
  if (testCase.requiresActiveFees && !target.feesActive) return 'needs active fees'
  return undefined
}
