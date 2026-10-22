import { performance } from 'node:perf_hooks'
import { parseArgs } from 'node:util'

import { assert, errorSummary } from './support/utils.js'
import type { BenchmarkGroup } from './case.js'
import type { E2eContext } from './context.js'
import { runHosted } from './hosted.js'
import { benchmarks } from './modules.js'
import { loadProfile } from './profile.js'
import { readSourceState, writeResult, type SourceState } from './results.js'
import { formatTiming, type Phase, type Timings } from './support/timings.js'

// Module-level values must precede the top-level await below, which runs the benchmark.
const benchmarkGroups = ['public', 'private'] as const satisfies readonly BenchmarkGroup[]

// Measures user-perceived latency of the round trips modules register against a deployed profile.
const args = parseBenchmarkArguments(process.argv.slice(2))
const source = readSourceState()
const profile = loadProfile(args.profilePath)

await runHosted(
  profile,
  (context, manifest) =>
    runBenchmarks({
      context,
      group: args.group,
      manifest,
      samples: args.samples,
      source,
    }),
  // A stable identity keeps its policy membership and Zone account admission across runs.
  {
    identities: 'public-fixture',
    fundFeeActors: ['user'],
    requireZoneRpc: args.group !== 'public',
  },
)

type BenchmarkMeasurement = {
  flow: string
  sample: number
  status: 'PASS' | 'FAIL'
  durationMs: number
  /** The phases the flow's shared actions recorded within the measured action. */
  phases: Phase[]
  failure?: string
}

async function runBenchmarks(options: runBenchmarks.Options) {
  const roundTrips = benchmarkGroups
    .filter((group) => options.group === 'all' || options.group === group)
    .map((group) => {
      const roundTrip = benchmarks.find(({ roundTrip }) => roundTrip?.group === group)?.roundTrip
      assert(roundTrip !== undefined, `No module registers a ${group} benchmark`)
      return roundTrip
    })
  for (const benchmark of benchmarks) await benchmark.preflight?.(options.context)
  const measurements: BenchmarkMeasurement[] = []
  let failure: unknown

  console.log(`Environment · ${options.context.environmentId} (${options.context.provider})`)
  console.log(`Group · ${options.group}`)
  console.log(`Deployment · ${options.context.deploymentId}`)
  console.log(`Engine · ${options.context.engineKind}`)
  console.log(`Samples · ${options.samples}\n`)

  try {
    for (let sample = 1; sample <= options.samples; sample += 1) {
      console.log(`SAMPLE   ${sample}/${options.samples}`)
      for (const roundTrip of roundTrips) {
        await roundTrip.sample(options.context, (flow, run) =>
          measure(measurements, options.context.timings, flow, sample, run),
        )
      }
    }
  } catch (error) {
    failure = error
  }

  const summary = summarizeMeasurements(measurements)
  printSummary(summary)
  const artifact = writeResult(
    `benchmark-${options.context.engineKind}-${options.context.deploymentId}`,
    {
      schemaVersion: 2,
      benchmark: 'earn-user-action-latency',
      environment: {
        id: options.context.environmentId,
        provider: options.context.provider,
        chainId: options.context.deployment.network.chainId,
        zoneId: options.context.deployment.network.zone?.id,
      },
      engine: options.context.engineKind,
      deployment: {
        id: options.context.deploymentId,
        manifestSha256: options.manifest.sha256,
        source: options.manifest.source,
      },
      source: options.source,
      groupRequested: options.group,
      samplesRequested: options.samples,
      measurements,
      summary,
      failure: failure ? errorSummary(failure) : undefined,
    },
  )
  console.log(`\nResults · ${artifact}`)
  if (failure) throw failure
  return { artifact, measurements, summary }
}

declare namespace runBenchmarks {
  type Options = {
    context: E2eContext
    group: BenchmarkArguments['group']
    manifest: { sha256: string; source: string }
    samples: number
    source: SourceState
  }
}

async function measure<Result>(
  measurements: BenchmarkMeasurement[],
  timings: Timings,
  flow: string,
  sample: number,
  run: () => Promise<Result>,
) {
  const mark = timings.mark()
  const recorded = () => timings.since(mark)
  const phases = async () => (await recorded()).flatMap((entry) => entry.phases)
  const started = performance.now()
  try {
    const result = await run()
    const durationMs = elapsed(started)
    measurements.push({ flow, sample, status: 'PASS', durationMs, phases: await phases() })
    console.log(`PASS     ${flow} (${formatDuration(durationMs)})`)
    for (const entry of await recorded()) console.log(formatTiming(entry))
    return result
  } catch (error) {
    const durationMs = elapsed(started)
    measurements.push({
      flow,
      sample,
      status: 'FAIL',
      durationMs,
      phases: await phases(),
      failure: errorSummary(error),
    })
    console.error(`FAIL     ${flow}: ${errorSummary(error)}`)
    throw error
  }
}

function elapsed(started: number) {
  return Math.round((performance.now() - started) * 1_000) / 1_000
}

/**
 * Per-flow statistics over passing samples, in the order flows were first measured, with the same
 * statistics for each phase the flow recorded.
 */
function summarizeMeasurements(measurements: readonly BenchmarkMeasurement[]) {
  const flows = [...new Set(measurements.map((measurement) => measurement.flow))]
  return flows.flatMap((flow) => {
    const passed = measurements.filter(
      (measurement) => measurement.flow === flow && measurement.status === 'PASS',
    )
    const overall = statistics(passed.map((measurement) => measurement.durationMs))
    if (!overall) return []
    const phaseNames = [
      ...new Set(passed.flatMap((measurement) => measurement.phases.map(({ phase }) => phase))),
    ]
    const phases = phaseNames.flatMap((phase) => {
      const values = passed.flatMap((measurement) =>
        measurement.phases.filter((entry) => entry.phase === phase).map((entry) => entry.ms),
      )
      const clock = passed
        .flatMap((measurement) => measurement.phases)
        .find((entry) => entry.phase === phase)!.clock
      const stats = statistics(values)
      return stats ? [{ phase, clock, ...stats }] : []
    })
    return [{ flow, ...overall, phases }]
  })
}

function statistics(values: readonly number[]) {
  if (values.length === 0) return undefined
  const sorted = [...values].sort((left, right) => left - right)
  return {
    samples: sorted.length,
    minMs: sorted[0]!,
    p50Ms: percentile(sorted, 50),
    p95Ms: percentile(sorted, 95),
    maxMs: sorted.at(-1)!,
  }
}

function percentile(sorted: readonly number[], value: number) {
  return sorted[Math.ceil((value / 100) * sorted.length) - 1]!
}

function printSummary(summary: ReturnType<typeof summarizeMeasurements>) {
  console.log('\nSummary')
  for (const item of summary) {
    console.log(
      `${item.flow.padEnd(16)} p50 ${formatDuration(item.p50Ms)} · p95 ${formatDuration(item.p95Ms)} · n=${item.samples}`,
    )
    for (const phase of item.phases) {
      console.log(
        `  ${phase.phase.padEnd(28)} p50 ${formatDuration(phase.p50Ms)} · p95 ${formatDuration(phase.p95Ms)}${phase.clock === 'chain' ? ' (chain)' : ''}`,
      )
    }
  }
}

function formatDuration(durationMs: number) {
  return `${(durationMs / 1_000).toFixed(3)}s`
}

type BenchmarkArguments = {
  profilePath: string
  group: 'all' | BenchmarkGroup
  samples: number
}

function parseBenchmarkArguments(argv: readonly string[]): BenchmarkArguments {
  const { values } = parseArgs({
    // pnpm forwards each `--` separator.
    args: argv.filter((argument) => argument !== '--'),
    options: {
      'earn-file': { type: 'string' },
      group: { type: 'string', default: 'all' },
      samples: { type: 'string', default: '10' },
    },
    strict: true,
  })
  const { group } = values
  if (group !== 'all' && group !== 'private' && group !== 'public') {
    throw new Error(`--group must be all, private, or public; got ${group}`)
  }
  const samples = Number(values.samples)
  if (!Number.isSafeInteger(samples) || samples < 1 || samples > 20) {
    throw new Error(`--samples must be an integer between 1 and 20; got ${values.samples}`)
  }
  const profilePath = values['earn-file']
  if (!profilePath) throw new Error('--earn-file <profile.json> is required')
  return { profilePath, group, samples }
}
