import { performance } from 'node:perf_hooks'

/**
 * Where a phase's duration comes from: `wall` is the harness's monotonic clock around what it
 * observed, so a phase that ends on a poll is quantized to the polling interval; `chain` is the
 * difference between two blocks' `timestampMillis`, independent of polling.
 */
type PhaseClock = 'wall' | 'chain'

export type Phase = { phase: string; ms: number; clock: PhaseClock }

/** One user action's phases, as the shared actions record them. */
export type ActionTiming = { action: string; phases: Phase[] }

/**
 * Collects the phase timings shared actions record during a run. An action may record a pending
 * entry so that block reads for chain phases happen outside the time it is measured over.
 */
export function createTimings() {
  const entries: (ActionTiming | Promise<ActionTiming>)[] = []
  return {
    record(entry: ActionTiming | Promise<ActionTiming>) {
      entries.push(entry)
    },
    /** A position to pass to `since`, taken before the actions to report. */
    mark() {
      return entries.length
    },
    since(mark: number): Promise<readonly ActionTiming[]> {
      return Promise.all(entries.slice(mark))
    },
  }
}

export type Timings = ReturnType<typeof createTimings>

/** Milliseconds on the harness's monotonic clock, rounded to the microsecond. */
export function wallMs(started: number, ended = performance.now()) {
  return Math.round((ended - started) * 1_000) / 1_000
}

/**
 * Milliseconds between two Tempo blocks' `timestampMillis`, or undefined when a block lacks it.
 * Clients that do not format the field return it as a hex string.
 */
export function chainMs(from: object, to: object): number | undefined {
  const millis = (block: object) => {
    const value = (block as { timestampMillis?: unknown }).timestampMillis
    if (typeof value === 'bigint') return value
    if (typeof value === 'string' || typeof value === 'number') return BigInt(value)
    return undefined
  }
  const [start, end] = [millis(from), millis(to)]
  return start === undefined || end === undefined ? undefined : Number(end - start)
}

/** One line per action, for the runner's and the benchmark's output. */
export function formatTiming(entry: ActionTiming) {
  const phases = entry.phases
    .map(
      (phase) =>
        `${phase.phase} ${phase.ms.toFixed(0)}ms${phase.clock === 'chain' ? ' (chain)' : ''}`,
    )
    .join(' · ')
  return `TIMING   ${entry.action}: ${phases}`
}
