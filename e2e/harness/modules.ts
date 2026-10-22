import { readdirSync } from 'node:fs'

import type {
  CoverageDimension,
  E2eBenchmark,
  E2eModule,
  E2eTarget,
  LaunchFeature,
  RegisteredCase,
} from './case.js'

const modulesDirectory = new URL('../modules/', import.meta.url)

/**
 * Every capability module, discovered from `modules/<id>/module.ts`. The folder name is the module's
 * case group, so adding a module is adding its folder.
 */
const modules = await Promise.all(
  readdirSync(modulesDirectory, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
    .map(async (id) => {
      const module = (await import(new URL(`${id}/module.ts`, modulesDirectory).href)) as E2eModule
      return { id, ...module }
    }),
)

export const groups = modules.map(({ id }) => id)

export const cases: readonly RegisteredCase[] = modules.flatMap(({ id, cases }) =>
  cases.map((testCase) => ({ ...testCase, group: id })),
)

/** What modules contribute to the latency benchmark, in module order. */
export const benchmarks: readonly E2eBenchmark[] = modules.flatMap(({ benchmark }) =>
  benchmark ? [benchmark] : [],
)

/** Each module's stack checks, in module order; see `E2eModule.validate`. */
export const moduleValidators = modules.flatMap(({ validate }) => (validate ? [validate] : []))

/** Each module's case-integrity snapshot by module ID; see `E2eModule.integrity`. */
export const moduleIntegrity = modules.flatMap(({ id, integrity }) =>
  integrity ? [[id, integrity] as const] : [],
)

export const launchFeatures: Readonly<Record<string, LaunchFeature>> = {}
for (const { id, launchFeatures: owned } of modules) {
  for (const [feature, definition] of Object.entries(owned ?? {})) {
    // A second definition would silently replace the owner's requirements and weaken --launch.
    if (feature in launchFeatures)
      throw new Error(`Launch feature ${feature} is defined twice (${id})`)
    ;(launchFeatures as Record<string, LaunchFeature>)[feature] = definition
  }
}

for (const testCase of cases) {
  if (cases.filter(({ id }) => id === testCase.id).length > 1) {
    throw new Error(`Duplicate E2E case ${testCase.id}`)
  }
  const unknown = Object.keys(testCase.coverage ?? {}).find((feature) => !launchFeatures[feature])
  if (unknown) throw new Error(`E2E case ${testCase.id} covers unknown launch feature ${unknown}`)
  if (testCase.launch && Object.keys(testCase.coverage ?? {}).length === 0) {
    throw new Error(`Launch E2E case ${testCase.id} lacks feature metadata`)
  }
  // Hosted validation pins every other target dimension to the profile, so a default case may drop
  // out of a run only because the profile does not offer what the case needs.
  if (testCase.default && testCase.environments) {
    throw new Error(`Default E2E case ${testCase.id} cannot depend on the environment`)
  }
}

export function caseById(id: string) {
  return cases.find((testCase) => testCase.id === id)
}

/** The launch features, and their coverage dimensions, a target must cover. */
function requiredLaunchFeatures(target: E2eTarget) {
  const protectedAccess = target.accessKind === 'tip403-whitelist'
  return Object.entries(launchFeatures)
    .filter(([, feature]) => feature.applies(target))
    .map(
      ([id, feature]) =>
        [
          id,
          [
            ...feature.dimensions,
            ...(protectedAccess ? (feature.protectedDimensions ?? []) : []),
          ] as readonly CoverageDimension[],
        ] as const,
    )
}

export function validateLaunchFeatureCoverage(
  selected: readonly RegisteredCase[],
  target: E2eTarget,
) {
  for (const [feature, required] of requiredLaunchFeatures(target)) {
    for (const dimension of required) {
      const covered = selected.some(
        (testCase) => testCase.launch && testCase.coverage?.[feature]?.includes(dimension),
      )
      if (!covered) throw new Error(`${feature} has no ${dimension} E2E coverage`)
    }
  }
}
