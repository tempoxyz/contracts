import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, test } from 'vitest'

import { hostedEnvironments } from '../chain/tempo.js'

const workflow = readFileSync(
  new URL('../../.github/workflows/hosted-e2e.yml', import.meta.url),
  'utf8',
)
const root = fileURLToPath(new URL('../../', import.meta.url))

describe('hosted E2E workflow', () => {
  test('runs only by hand from main, in the release environment and hosted-contracts queue', () => {
    expect(workflow).toMatch(/^on:\n {2}workflow_dispatch:/m)
    expect(workflow).not.toMatch(/^ {2}(?:pull_request|push|schedule|workflow_run)/m)
    expect(workflow.match(/^ {4}if: github\.ref == 'refs\/heads\/main'$/gm)).toHaveLength(2)
    expect(workflow).toContain('environment: factory-release-${{ needs.network.outputs.network }}')
    expect(workflow).toContain('group: hosted-contracts-${{ needs.network.outputs.network }}')
    // Read-only validation never receives the deployer key.
    expect(workflow).toContain(
      "DEPLOYER_PRIVATE_KEY: ${{ !inputs.validate-only && secrets.DEPLOYER_PRIVATE_KEY || '' }}",
    )
    expect(workflow).toContain('pnpm e2e:profile "$' + '{arguments[@]}"')
  })

  test('resolves every hosted network', () => {
    const listed = /for network in ([a-z ]+); do/.exec(workflow)?.[1]?.split(' ')
    expect(listed?.sort()).toEqual(Object.keys(hostedEnvironments).sort())
  })

  describe('resolving the profile network', () => {
    const resolveNetwork = (profile: string) => {
      const temp = mkdtempSync(join(tmpdir(), 'hosted-e2e-network-'))
      try {
        const output = join(temp, 'output')
        writeFileSync(output, '')
        execFileSync('bash', ['-c', step("Resolve the profile's network")], {
          cwd: root,
          encoding: 'utf8',
          stdio: 'pipe',
          env: { ...process.env, GITHUB_OUTPUT: output, PROFILE: profile, RUNNER_TEMP: temp },
        })
        return Object.fromEntries(
          readFileSync(output, 'utf8')
            .trim()
            .split('\n')
            .map((line) => line.split('=', 2)),
        )
      } finally {
        rmSync(temp, { recursive: true, force: true })
      }
    }

    test('maps each committed profile to its network', { timeout: 120_000 }, () => {
      expect(resolveNetwork('./profiles/e2e-moderato/profile.json')).toEqual({
        network: 'moderato',
        profile: 'profiles/e2e-moderato/profile.json',
      })
      expect(resolveNetwork('profiles/veda-mainnet/profile.json')).toEqual({
        network: 'mainnet',
        profile: 'profiles/veda-mainnet/profile.json',
      })
    })

    test('refuses a path that is not a committed profile', { timeout: 120_000 }, () => {
      expect(() => resolveNetwork('profiles/missing/profile.json')).toThrow()
      expect(() => resolveNetwork('package.json')).toThrow()
    })
  })

  test('summarizes each case and its status', () => {
    const temp = mkdtempSync(join(tmpdir(), 'hosted-e2e-summary-'))
    try {
      mkdirSync(join(temp, 'e2e/.results'), { recursive: true })
      writeFileSync(
        join(temp, 'e2e/.results/2026-01-01T00-00-00.000Z-erc4626-e2e-moderato.json'),
        JSON.stringify({
          schemaVersion: 2,
          selectedCases: ['a', 'b', 'c', 'd'],
          completed: false,
          cases: [
            { id: 'a', status: 'PASS', durationMs: 1500 },
            { id: 'b', status: 'FAIL', durationMs: 2000, failure: 'reverted | twice\nagain' },
            { id: 'c', status: 'BLOCKED', durationMs: 10, blocker: 'needs a top-up' },
          ],
        }),
      )
      const summary = join(temp, 'summary.md')
      execFileSync('bash', ['-c', step('Summarize')], {
        cwd: temp,
        stdio: 'pipe',
        env: {
          ...process.env,
          GITHUB_SHA: 'abcdef0123456789',
          GITHUB_STEP_SUMMARY: summary,
          GROUP: '',
          NETWORK: 'moderato',
          OUTCOME: 'failure',
          PROFILE: 'profiles/e2e-moderato/profile.json',
          VALIDATE_ONLY: 'false',
        },
      })
      expect(readFileSync(summary, 'utf8')).toMatchInlineSnapshot(`
        "## Hosted E2E · moderato · \`profiles/e2e-moderato/profile.json\` · abcdef0

        | Case | Status | Duration | Failure or blocker |
        | --- | --- | ---: | --- |
        | \`a\` | PASS | 1s |  |
        | \`b\` | FAIL | 2s | reverted \\| twice again |
        | \`c\` | BLOCKED | 0s | needs a top-up |
        | \`d\` | NOT RUN | | |

        3 cases: 1 passed, 1 failed, 1 blocked

        The run was interrupted before every selected case ran.
        "
      `)
    } finally {
      rmSync(temp, { recursive: true, force: true })
    }
  })
})

/** The shell script of the workflow step with this name, dedented. */
function step(name: string) {
  const lines = workflow.split('\n')
  const start = lines.findIndex((line) => line.trim() === `- name: ${name}`)
  const run = lines.findIndex((line, index) => index > start && /^ +run: \|$/.test(line))
  const indent = /^ */.exec(lines[run]!)![0].length
  const body: string[] = []
  for (const line of lines.slice(run + 1)) {
    if (line.trim() !== '' && /^ */.exec(line)![0].length <= indent) break
    body.push(line.slice(indent + 2))
  }
  return body.join('\n')
}
