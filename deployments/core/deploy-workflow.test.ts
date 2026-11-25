import { execFileSync } from 'node:child_process'
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, test } from 'vitest'

import { hostedEnvironment, hostedEnvironments } from '../chain/tempo.js'

const workflow = readFileSync(
  new URL('../../.github/workflows/deploy.yml', import.meta.url),
  'utf8',
)

const profiles = (...flags: string[]) =>
  execFileSync(
    'pnpm',
    ['exec', 'tsx', fileURLToPath(new URL('./profiles.ts', import.meta.url)), ...flags],
    { encoding: 'utf8', stdio: 'pipe', env: { ...process.env, GITHUB_OUTPUT: '' } },
  )

describe('deploy workflow', () => {
  test('offers every hosted network and both, Moderato first', () => {
    const options = /^ {6}networks:[\s\S]*?^ {8}options: \[([^\]]*)\]$/m
      .exec(workflow)?.[1]
      ?.split(/,\s*/)
    expect(options?.sort()).toEqual(['both', ...Object.keys(hostedEnvironments)].sort())
    expect(workflow).toContain('["moderato","mainnet"]')
    const recorded = /for network in ([a-z ]+); do/.exec(workflow)?.[1]?.split(' ')
    expect(recorded?.sort()).toEqual(Object.keys(hostedEnvironments).sort())
    // Records are named by network, so the record job finds them nested or flat.
    expect(workflow).toContain('changes-$NETWORK.patch')
    expect(workflow).toContain('-name "changes-$network.patch"')
    expect(workflow).toContain('if [[ -z "${TEMPO_RPC_URL:-}" ]]; then')
    // Resubmission reaches the releases and every profile deploy, and only with broadcast.
    expect(workflow).toContain('RESUBMIT: ${{ inputs.broadcast && inputs.resubmit-verification }}')
    expect(workflow.match(/arguments\+=\(--resubmit-verification\)/g)).toHaveLength(2)
    expect(workflow).toContain('deploy+=(--resubmit-verification)')
    expect(workflow).toContain('ZONE_ADMIN_PRIVATE_KEY: ${{ secrets.ZONE_ADMIN_PRIVATE_KEY }}')
  })

  test('runs only from main, in the release environment and hosted-contracts queue', () => {
    expect(workflow).not.toMatch(/^ {2}(?:pull_request|push|schedule|workflow_run)/m)
    expect(workflow.match(/^ {4}if: .*github\.ref == 'refs\/heads\/main'/gm)).toHaveLength(2)
    expect(workflow).toContain('environment: factory-release-${{ matrix.network }}')
    expect(workflow).toContain('group: hosted-contracts-${{ matrix.network }}')
  })

  test('reconciles the releases, the Zone router factory, then every profile on the network', () => {
    const steps = [
      'pnpm factory-release "${arguments[@]}"',
      'pnpm zone-router-release "${arguments[@]}"',
      'pnpm profiles --network "$NETWORK"',
      'pnpm earn "${deploy[@]}"',
    ].map((step) => workflow.indexOf(step))
    expect(steps.every((index) => index > 0)).toBe(true)
    expect([...steps].sort((a, b) => a - b)).toEqual(steps)
    expect(workflow).toContain('arguments=("$NETWORK" all ')
    expect(workflow).toContain('arguments=("$NETWORK" zoneRouterFactory --parameters \'{}\' ')
  })
})

describe('deploy record', () => {
  // The collect and apply commands, as the workflow runs them.
  const line = (pattern: RegExp) => {
    const match = pattern.exec(workflow)?.[0]
    if (!match) throw new Error(`No line matching ${pattern}`)
    return match.trim()
  }
  const intentToAdd = line(/^ +git add --intent-to-add .*$/m)
  const diff = line(/^ +git diff --binary .*$/m).replace(/ > .*$/, '')
  const stage = line(/^ +git add --all -- deployments.*$/m)
  const check = line(/^ +if git diff --cached --quiet .*; then$/m).replace(/^if (.*); then$/, '$1')

  const run = (cwd: string, script: string) =>
    execFileSync('bash', ['-euo', 'pipefail', '-c', script], {
      cwd,
      encoding: 'utf8',
      env: {
        ...process.env,
        GIT_AUTHOR_EMAIL: 'test@example.com',
        GIT_AUTHOR_NAME: 'test',
        GIT_COMMITTER_EMAIL: 'test@example.com',
        GIT_COMMITTER_NAME: 'test',
      },
    })

  test("carries a new profile's first record to the record job", () => {
    const root = mkdtempSync(join(tmpdir(), 'deploy-record-'))
    try {
      const repo = (name: string) => {
        const dir = join(root, name)
        run(root, `git init -q ${name}`)
        run(dir, 'mkdir -p deployments/core profiles/old profiles/new')
        writeFileSync(join(dir, 'deployments/core/releases.ts'), 'export {}\n')
        writeFileSync(join(dir, 'profiles/old/profile.json'), '{}\n')
        writeFileSync(join(dir, 'profiles/old/deployment.json'), '{"v":1}\n')
        writeFileSync(join(dir, 'profiles/new/profile.json'), '{}\n')
        run(dir, 'git add -A && git commit -qm init')
        return dir
      }
      const network = repo('network')
      writeFileSync(join(network, 'profiles/old/deployment.json'), '{"v":2}\n')
      writeFileSync(join(network, 'profiles/new/deployment.json'), '{"v":1}\n')
      writeFileSync(join(network, 'profiles/new/deployment.pending.json'), '{}\n')
      const patch = join(root, 'changes.patch')
      run(network, `${intentToAdd}\n${diff} > ${patch}`)
      const record = repo('record')
      run(record, `git apply ${patch}\n${stage}`)
      expect(() => run(record, check)).toThrow()
      expect(run(record, 'git diff --cached --name-only').trim().split('\n')).toEqual([
        'profiles/new/deployment.json',
        'profiles/old/deployment.json',
      ])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

describe('profiles --network', () => {
  test.each(Object.keys(hostedEnvironments))(
    'lists only the %s profiles',
    { timeout: 30_000 },
    (network) => {
      const listed = JSON.parse(profiles('--network', network)) as { path: string }[]
      expect(listed.length).toBeGreaterThan(0)
      for (const { path } of listed) {
        const { chainId } = JSON.parse(
          readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8'),
        ) as { chainId: number }
        expect(hostedEnvironment(chainId)?.id).toBe(network)
      }
    },
  )

  test('lists a profile whose record a release outdated', { timeout: 30_000 }, () => {
    const root = mkdtempSync(join(tmpdir(), 'profiles-network-'))
    try {
      const folder = join(root, 'profiles', 'e2e-moderato')
      cpSync(fileURLToPath(new URL('../../profiles/e2e-moderato/', import.meta.url)), folder, {
        recursive: true,
      })
      const recordPath = join(folder, 'deployment.json')
      const record = JSON.parse(readFileSync(recordPath, 'utf8')) as Record<string, unknown>
      writeFileSync(
        recordPath,
        JSON.stringify({ ...record, deploymentIntentHash: `0x${'00'.repeat(32)}` }),
      )
      expect(() => profiles('--profiles', join(root, 'profiles'))).toThrow()
      expect(
        JSON.parse(profiles('--profiles', join(root, 'profiles'), '--network', 'moderato')),
      ).toEqual([
        {
          id: 'e2e-moderato',
          path: 'profiles/e2e-moderato/profile.json',
          rpcUrl: hostedEnvironments.moderato.rpcUrl,
        },
      ])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  test('refuses an unknown network and --matrix with --network', { timeout: 30_000 }, () => {
    expect(() => profiles('--network', 'devnet')).toThrow('--network must be one of')
    expect(() => profiles('--matrix', '--network', 'moderato')).toThrow('separate modes')
  })
})
