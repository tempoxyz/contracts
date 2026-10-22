import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { ActionTiming } from './support/timings.js'

const e2eRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const resultsDirectory = resolve(e2eRoot, '.results')

export function sha256(value: string) {
  return createHash('sha256').update(value).digest('hex')
}

export type SourceState = ReturnType<typeof readSourceState>

export function readSourceState() {
  const git = (...args: string[]) =>
    execFileSync('git', args, { cwd: dirname(e2eRoot), encoding: 'utf8' }).trim()
  return { commit: git('rev-parse', 'HEAD'), dirty: git('status', '--porcelain').length > 0 }
}

/** One case outcome. tempoxyz/workflows reads `cases[].id` and `cases[].status` from run results. */
export type CaseResult = {
  id: string
  status: 'PASS' | 'FAIL' | 'BLOCKED'
  durationMs: number
  /** Phase timings the case's shared actions recorded, in the order they ran. */
  timings?: readonly ActionTiming[]
  failure?: string
  blocker?: string
}

/** Every result artifact; a case run also carries `cases`. */
export type Result = { schemaVersion: 2; cases?: readonly CaseResult[] } & Record<string, unknown>

/** Writes one structured JSON result under `e2e/.results/`, named `<timestamp>-<name>.json`. */
export function writeResult(name: string, result: Result) {
  mkdirSync(resultsDirectory, { recursive: true })
  const generatedAt = new Date().toISOString()
  const path = resolve(resultsDirectory, `${generatedAt.replaceAll(':', '-')}-${name}.json`)
  writeFileSync(path, `${JSON.stringify({ ...result, generatedAt }, null, 2)}\n`)
  return path
}
