#!/usr/bin/env node
import { appendFileSync, existsSync, readdirSync } from 'node:fs'
import { dirname, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseArgs } from 'node:util'

import { hostedEnvironment } from '../chain/tempo.js'
import {
  loadEarnProfile,
  loadEarnProfileBundle,
  pendingDeploymentPath,
  profileDeploymentPath,
} from './bundle.js'

/**
 * Validates every committed profile. Each carries its completed record; only an in-progress
 * deployment, marked by its local or CI-restored `deployment.pending.json`, may lack one. With
 * `--matrix`, emits the recorded-profile matrix instead: every recorded profile paired with its
 * hosted chain's public L1 RPC, as the `profiles` output under GitHub Actions or on stdout.
 * `--profiles <directory>` scans another repository's profiles directory instead of Earn's own.
 * A bare `--`, which `pnpm profiles -- --matrix` forwards, is ignored.
 */
const { values: args } = parseArgs({
  args: process.argv.slice(2).filter((argument) => argument !== '--'),
  options: { profiles: { type: 'string' }, matrix: { type: 'boolean', default: false } },
  strict: true,
})
const directory = args.profiles
  ? resolve(process.env.INIT_CWD ?? process.cwd(), args.profiles)
  : resolve(fileURLToPath(new URL('../../profiles', import.meta.url)))
const root = dirname(directory)
const paths = readdirSync(directory, { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map((entry) => resolve(directory, entry.name, 'profile.json'))
  .sort()

const ids = new Set<string>()
const recorded: { id: string; path: string; rpcUrl: string }[] = []
for (const path of paths) {
  const relativePath = relative(root, path)
  const recordPath = profileDeploymentPath(path)
  if (!existsSync(recordPath)) {
    if (!existsSync(pendingDeploymentPath(path))) {
      throw new Error(
        `Deployment profile ${relativePath} has no ${relative(root, recordPath)}; ` +
          'complete `pnpm earn deploy` and commit the profile with its record',
      )
    }
    const { id } = loadEarnProfile(path)
    if (ids.has(id)) throw new Error(`Duplicate deployment profile id ${id}`)
    ids.add(id)
    continue
  }
  const { id, chainId } = loadEarnProfileBundle(path).profile
  if (ids.has(id)) throw new Error(`Duplicate deployment profile id ${id}`)
  ids.add(id)
  const environment = hostedEnvironment(chainId)
  if (!environment) throw new Error(`${relativePath} targets unsupported chain ${chainId}`)
  recorded.push({ id, path: relativePath, rpcUrl: environment.rpcUrl })
}

if (args.matrix) {
  const output = JSON.stringify(recorded)
  // Single-line JSON, so the plain `name=value` form cannot inject another output.
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `profiles=${output}\n`)
  else console.log(output)
} else {
  const pending = paths.length - recorded.length
  console.log(
    `deployment profiles valid: ${paths.length} profile(s)` +
      (pending > 0 ? `, ${pending} with an in-progress deployment` : ''),
  )
}
