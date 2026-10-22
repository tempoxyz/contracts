import { readFileSync } from 'node:fs'
import { Devnet } from 'localnet'
import { describe, expect, expectTypeOf, test } from 'vitest'

import { parseE2eArguments } from './arguments.js'
import { groups } from './modules.js'
import type { CaseResult, Result } from './results.js'

// tempoxyz/workflows runs `pnpm e2e:devnet -- --group zone` and
// `pnpm devnet:deploy -- --out <dir> --eligible-account <address>` and reads their outputs.
const scripts = (path: string) =>
  (
    JSON.parse(readFileSync(new URL(path, import.meta.url), 'utf8')) as {
      scripts: Record<string, string>
    }
  ).scripts

describe('external profile repositories', () => {
  // `pnpm --filter … run` resets INIT_CWD, so a relative profile path passed from a repository that
  // holds Earn as a submodule would resolve inside Earn; `exec` keeps the caller's directory.
  test('runs every profile entry point with exec', () => {
    const root = scripts('../../package.json')
    for (const name of ['earn', 'profiles', 'e2e:profile', 'e2e:benchmark', 'e2e:fixture']) {
      expect(root[name], name).toMatch(/^pnpm --filter \S+ exec /)
    }
  })
})

describe('tempoxyz/workflows contract', () => {
  test('keeps the root entry points and their targets', () => {
    expect(scripts('../../package.json')).toMatchObject({
      'e2e:devnet': 'pnpm --filter e2e run devnet --',
      'devnet:deploy': 'pnpm --filter localnet run devnet:deploy --',
    })
    expect(scripts('../package.json').devnet).toBe('tsx harness/cli.ts --devnet')
    expect(scripts('../../localnet/package.json')['devnet:deploy']).toBe('tsx src/devnet-deploy.ts')
  })

  test('keeps the zone group selectable on a devnet run', () => {
    expect(groups).toContain('zone')
    expect(parseE2eArguments(['--devnet', '--', '--group', 'zone'])).toMatchObject({
      mode: 'run',
      devnet: true,
      selection: { mode: 'group', value: 'zone' },
    })
  })

  test('keeps the devnet:deploy output files', () => {
    expect(Devnet.outputFiles).toEqual([
      'earn-input-token',
      'earn-funding-helper',
      'earn-token',
      'earn-vault',
      'earn-router',
      'earn-source-revision',
    ])
  })

  test('keeps cases[].id and cases[].status in run results', () => {
    expectTypeOf<Result['schemaVersion']>().toEqualTypeOf<2>()
    expectTypeOf<CaseResult['id']>().toEqualTypeOf<string>()
    expectTypeOf<CaseResult['status']>().toEqualTypeOf<'PASS' | 'FAIL' | 'BLOCKED'>()
  })
})
