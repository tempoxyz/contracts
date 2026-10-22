import { earnFeesAbi } from '@tempoxyz/earn/abis'
import { E2ePrerequisiteError, errorSummary } from './support/utils.js'
import type { CaseSelection } from './arguments.js'
import { unsupportedReason, type E2eTarget, type RegisteredCase } from './case.js'
import type { E2eContext } from './context.js'
import { assertCaseIntegrity, captureCaseIntegrity } from './integrity.js'
import { caseById, cases, groups, validateLaunchFeatureCoverage } from './modules.js'
import type { LoadedProfile } from './profile.js'
import { writeResult, type CaseResult, type SourceState } from './results.js'
import { formatTiming } from './support/timings.js'

export async function runE2e(options: runE2e.Options) {
  const { context } = options
  const target = await contextTarget(context)
  const selected = selectCases(options.selection, target)
  if (options.selection.mode === 'launch') {
    validateLaunchFeatureCoverage(selectCases({ mode: 'launch' }, target), target)
  }
  let failures = 0
  let blocked = 0
  const caseResults: CaseResult[] = []

  console.log(`Environment · ${context.environmentId} (${context.provider})`)
  console.log(`Deployment · ${context.deploymentId}`)
  if (options.profile) console.log(`Profile · ${options.profile.profile.id}`)
  console.log(`Engine · ${context.engineKind}`)
  console.log(
    `Source · ${options.source.commit.slice(0, 12)} (${options.source.dirty ? 'dirty' : 'clean'})`,
  )
  console.log(`Selection · ${selected.length} shared E2E cases\n`)
  if (options.selection.shard) console.log(`Shard · ${options.selection.shard}\n`)

  for (const testCase of selected) {
    const started = Date.now()
    let caseError: unknown
    let status: CaseResult['status'] = 'PASS'
    if (caseResults.length > 0) process.stdout.write('\n')
    process.stdout.write(`RUN      ${testCase.id}\n`)
    if (testCase.flow) process.stdout.write(`FLOW     ${testCase.flow}\n`)
    try {
      await testCase.preflight?.(context)
    } catch (error) {
      caseError = error
    }
    const timingMark = context.timings.mark()
    if (!caseError) {
      const baseline = await captureCaseIntegrity(context)
      try {
        await testCase.run(context)
      } catch (error) {
        caseError = error
      } finally {
        try {
          const cleanup = testCase.cleanup
          if (cleanup) {
            await context.progress.withMuted(() => cleanup(context))
            context.progress.step('CLEANUP', 'reusable test state restored')
          }
          await assertCaseIntegrity(context, baseline)
        } catch (cleanupError) {
          caseError = caseError
            ? new AggregateError([caseError, cleanupError], 'case and guaranteed cleanup failed')
            : cleanupError
        }
      }
    }
    if (caseError) {
      failures += 1
      if (caseError instanceof E2ePrerequisiteError) {
        status = 'BLOCKED'
        blocked += 1
      } else {
        status = 'FAIL'
      }
      console.error(`${status.padEnd(9)}${testCase.id}: ${errorSummary(caseError)}`)
    } else {
      console.log(`PASS     ${testCase.id} (${duration(started)})`)
    }
    const timings = await context.timings.since(timingMark)
    for (const timing of timings) console.log(formatTiming(timing))
    caseResults.push({
      id: testCase.id,
      status,
      durationMs: Date.now() - started,
      ...(timings.length > 0 ? { timings } : {}),
      ...(caseError
        ? status === 'BLOCKED'
          ? { blocker: errorSummary(caseError) }
          : { failure: errorSummary(caseError) }
        : {}),
    })
  }

  const passed = selected.length - failures
  const failed = failures - blocked
  console.log(`\n${selected.length} cases: ${passed} passed, ${failed} failed, ${blocked} blocked`)
  if (options.selection.mode === 'launch') {
    console.log(`Launch readiness · ${failures === 0 ? 'PASS' : 'NOT READY'}`)
  }
  const artifact = writeResult(`${context.engineKind}-${context.deploymentId}`, {
    schemaVersion: 2,
    environment: { id: context.environmentId, provider: context.provider },
    engine: context.engineKind,
    deployment: {
      id: context.deploymentId,
      manifestSha256: options.manifest.sha256,
      source: options.manifest.source,
    },
    profile: options.profile && {
      id: options.profile.profile.id,
      source: options.profile.path,
      sha256: options.profile.sha256,
    },
    source: options.source,
    selectedCases: caseResults.map((result) => result.id),
    cases: caseResults,
  })
  console.log(`Results · ${artifact}`)
  return { failures }
}

export function listE2eCases() {
  for (const testCase of cases) {
    console.log(`${testCase.id.padEnd(56)} ${testCase.group.padEnd(10)} ${testCase.description}`)
  }
}

export declare namespace runE2e {
  type Options = {
    context: E2eContext
    manifest: { sha256: string; source: string }
    /** The deployed profile, recorded in the result's provenance. */
    profile?: LoadedProfile | undefined
    selection: CaseSelection
    source: SourceState
  }

  type Result = Awaited<ReturnType<typeof runE2e>>
}

/** The target a live context offers, reading whether its fees are active. */
async function contextTarget(context: E2eContext): Promise<E2eTarget> {
  return {
    engineKind: context.engineKind,
    environment: context.environmentId,
    capabilities: context.deployment.capabilities,
    accessKind: context.deployment.access.kind,
    periphery: context.operations,
    feesActive: await context.l1Public.readContract({
      address: context.contracts.earnFees,
      abi: earnFeesAbi,
      functionName: 'feesActive',
    }),
  }
}

/**
 * The cases a selection runs on a target. A named case must support the target; every other mode
 * selects only the cases the target supports.
 */
export function selectCases(selection: CaseSelection, target: E2eTarget) {
  let selected: readonly RegisteredCase[]
  if (selection.mode === 'case') {
    const found = caseById(selection.value)
    if (!found) throw new Error(`Unknown case: ${selection.value}`)
    const reason = unsupportedReason(found, target)
    if (reason) throw new Error(`Case ${found.id} ${reason}`)
    selected = [found]
  } else {
    if (selection.mode === 'group' && !groups.includes(selection.value)) {
      throw new Error(`Unknown group ${selection.value}; expected one of ${groups.join(', ')}`)
    }
    selected = cases.filter(
      (testCase) =>
        !unsupportedReason(testCase, target) &&
        (selection.mode === 'all' ||
          (selection.mode === 'launch' && testCase.launch) ||
          (selection.mode === 'default' && testCase.default) ||
          (selection.mode === 'group' && testCase.group === selection.value)),
    )
    if (selected.length === 0) throw new Error('The selection has no case this target supports')
  }
  return selection.shard ? selectShard(selected, selection.shard) : selected
}

function selectShard(selected: readonly RegisteredCase[], shard: string) {
  const match = /^(\d+)\/(\d+)$/.exec(shard)
  if (!match) throw new Error(`Invalid shard ${shard}; expected index/count such as 1/2`)
  const index = Number(match[1])
  const count = Number(match[2])
  if (!Number.isSafeInteger(index) || !Number.isSafeInteger(count) || count < 2) {
    throw new Error(`Invalid shard ${shard}; count must be at least 2`)
  }
  if (index < 1 || index > count) {
    throw new Error(`Invalid shard ${shard}; index must be between 1 and ${count}`)
  }
  if (count > selected.length) {
    throw new Error(`Invalid shard ${shard}; count exceeds ${selected.length} selected cases`)
  }
  const bins = Array.from({ length: count }, () => ({
    weight: 0,
    cases: new Set<RegisteredCase>(),
  }))
  const weighted = selected
    .map((testCase, caseIndex) => ({ testCase, caseIndex, weight: testCase.weight ?? 1 }))
    .sort((left, right) => right.weight - left.weight || left.caseIndex - right.caseIndex)
  for (const item of weighted) {
    const bin = bins.reduce((lightest, candidate) =>
      candidate.weight < lightest.weight ? candidate : lightest,
    )
    bin.cases.add(item.testCase)
    bin.weight += item.weight
  }
  return selected.filter((testCase) => bins[index - 1]!.cases.has(testCase))
}

function duration(started: number) {
  return `${((Date.now() - started) / 1_000).toFixed(1)}s`
}
