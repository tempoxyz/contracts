import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { expect, test } from 'vitest'

import { engineKinds } from './index.js'

const root = fileURLToPath(new URL('../../../../', import.meta.url))

// Engine-kind behavior lives in engine modules; generic code dispatches through their registries.
// Tests may name a kind to build a fixture.
test('generic code names no engine kind', () => {
  const files = execFileSync(
    'git',
    [
      'ls-files',
      '--',
      'deployments/core',
      'deployments/chain',
      'e2e/harness',
      'e2e/fixtures',
      'e2e/modules',
      'localnet/src',
      ':!localnet/src/engines',
      'app/src',
      'app/worker',
      ':!*.test.ts',
    ],
    { cwd: root, encoding: 'utf8' },
  )
    .split('\n')
    .filter((path) => /\.tsx?$/.test(path))
  expect(files.length).toBeGreaterThan(50)
  const kind = new RegExp(`['"\`](${engineKinds.join('|')})['"\`]`)
  const hits = files.flatMap((path) =>
    readFileSync(`${root}${path}`, 'utf8')
      .split('\n')
      .flatMap((line, index) => (kind.test(line) ? [`${path}:${index + 1}`] : [])),
  )
  expect(hits).toEqual([])
})
