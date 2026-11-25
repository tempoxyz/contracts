import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { describe, expect, test } from 'vitest'

const workflow = readFileSync(new URL('../../.github/workflows/spend.yml', import.meta.url), 'utf8')

describe('spend workflow', () => {
  test('starts on every pull request, so Required / Spend always reports', () => {
    expect(workflow).not.toMatch(/^ {4}paths:/m)
    expect(workflow).toContain('name: Required / Spend')
    for (const job of ['test', 'e2e', 'bridge-zone-e2e', 'bridge-smoke'])
      expect(workflow).toContain(`  ${job}:\n    name: `)
    expect(
      workflow.match(
        /^ {4}needs: scope\n {4}if: \$\{\{ needs\.scope\.outputs\.run == 'true' \}\}$/gm,
      ),
    ).toHaveLength(4)
    // Only pull request runs cancel earlier ones: an out-of-scope push to main would skip every job.
    expect(workflow).toContain("cancel-in-progress: ${{ github.event_name == 'pull_request' }}")
    // Each push to main has its own group, so a later push never replaces an earlier pending run.
    expect(workflow).toContain(
      "group: ${{ github.workflow }}-${{ github.event_name == 'pull_request' && github.ref || github.sha }}",
    )
  })

  describe('scope', () => {
    const scope = async (
      eventName: string,
      files?: { filename: string; previous_filename?: string }[],
    ) => {
      const outputs: Record<string, string> = {}
      const compared: string[] = []
      const github = {
        rest: {
          repos: {
            compareCommitsWithBasehead: async ({ basehead }: { basehead: string }) => {
              compared.push(basehead)
              return { data: { files } }
            },
          },
        },
      }
      const context = {
        eventName,
        payload: {
          after: 'b'.repeat(40),
          before: 'a'.repeat(40),
          pull_request: { base: { sha: 'c'.repeat(40) }, head: { sha: 'd'.repeat(40) } },
        },
        repo: { owner: 'o', repo: 'r' },
      }
      const core = {
        info: () => {},
        setOutput: (name: string, value: string) => (outputs[name] = value),
      }
      const AsyncFunction = (async () => {}).constructor as new (
        ...parameters: string[]
      ) => (...values: unknown[]) => Promise<void>
      await new AsyncFunction('github', 'context', 'core', block(/^ {10}script: \|$/m))(
        github,
        context,
        core,
      )
      lastCompared = compared
      return outputs.run
    }
    let lastCompared: string[] = []

    test.each([
      'src/zone/ZoneRouter.sol',
      'test/spend/CardSpender.t.sol',
      'snapshots/earn-tip20.json',
      'solar.lock',
      '.github/workflows/spend.yml',
    ])('runs the jobs for %s', async (filename) => {
      expect(await scope('pull_request', [{ filename: 'README.md' }, { filename }])).toBe('true')
      expect(await scope('push', [{ filename }])).toBe('true')
    })

    test('skips the jobs for changes outside card spend and its inputs', async () => {
      expect(
        await scope('pull_request', [
          { filename: 'README.md' },
          { filename: 'test/earn/core/EarnVault.t.sol' },
          { filename: 'deployments/core/deploy.ts' },
          { filename: 'e2e/engines/veda/cases.ts' },
          { filename: 'src.md' },
        ]),
      ).toBe('false')
    })

    test('counts a file moved out of scope', async () => {
      expect(
        await scope('pull_request', [
          { filename: 'README.md', previous_filename: 'docs/spend/README.md' },
        ]),
      ).toBe('true')
    })

    test('runs the jobs for other events and oversized changes', async () => {
      expect(await scope('workflow_dispatch')).toBe('true')
      const many = Array.from({ length: 300 }, () => ({ filename: 'README.md' }))
      expect(await scope('push', many)).toBe('true')
      expect(await scope('pull_request', many)).toBe('true')
    })

    test("compares the run's own commits, not the pull request's live head", async () => {
      await scope('pull_request', [{ filename: 'README.md' }])
      expect(lastCompared).toEqual([`${'c'.repeat(40)}...${'d'.repeat(40)}`])
      await scope('push', [{ filename: 'README.md' }])
      expect(lastCompared).toEqual([`${'a'.repeat(40)}...${'b'.repeat(40)}`])
    })
  })

  describe('Required / Spend', () => {
    const required = (env: Record<string, string>) =>
      execFileSync(
        'bash',
        ['-c', block(/^ {8}run: \|$/m, workflow.indexOf('name: Required / Spend'))],
        {
          encoding: 'utf8',
          env: { ...process.env, ...env },
          stdio: 'pipe',
        },
      )
    const passed = 'success success success success'

    test('passes out of scope, with every job skipped', () => {
      expect(
        required({
          SCOPE_RESULT: 'success',
          RUN: 'false',
          RESULTS: 'skipped skipped skipped skipped',
        }),
      ).toContain('not required')
    })

    test('passes in scope only when every job passes', () => {
      expect(() =>
        required({ SCOPE_RESULT: 'success', RUN: 'true', RESULTS: passed }),
      ).not.toThrow()
      for (const result of ['failure', 'cancelled', 'skipped'])
        expect(() =>
          required({
            SCOPE_RESULT: 'success',
            RUN: 'true',
            RESULTS: `success ${result} success success`,
          }),
        ).toThrow()
    })

    test('fails when the scope could not be selected', () => {
      expect(() =>
        required({ SCOPE_RESULT: 'failure', RUN: '', RESULTS: 'skipped skipped skipped skipped' }),
      ).toThrow()
    })
  })
})

/** The block scalar after the first line matching `header` at or after `from`, dedented. */
function block(header: RegExp, from = 0) {
  const lines = workflow.slice(from).split('\n')
  const start = lines.findIndex((line) => header.test(line))
  const indent = /^ */.exec(lines[start]!)![0].length
  const body: string[] = []
  for (const line of lines.slice(start + 1)) {
    if (line.trim() !== '' && /^ */.exec(line)![0].length <= indent) break
    body.push(line.slice(indent + 2))
  }
  return body.join('\n')
}
