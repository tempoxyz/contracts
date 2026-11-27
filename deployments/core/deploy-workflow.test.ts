import { execFileSync } from 'node:child_process'
import { cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, test } from 'vitest'

import { hostedEnvironment, hostedEnvironments } from '../chain/tempo.js'

const workflow = readFileSync(
  new URL('../../.github/workflows/deploy.yml', import.meta.url),
  'utf8',
)
const setupAction = readFileSync(
  new URL('../../.github/actions/setup/action.yml', import.meta.url),
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
    expect(workflow.match(/arguments\+=\(--resubmit-verification\)/g)).toHaveLength(1)
    expect(workflow).toContain('deploy+=(--resubmit-verification)')
    expect(workflow).toContain('ZONE_ADMIN_PRIVATE_KEY: ${{ secrets.ZONE_ADMIN_PRIVATE_KEY }}')
  })

  test('only simulates unless broadcast is chosen', () => {
    expect(/^ {6}broadcast:\n(?: {8}.*\n)*? {8}default: (\w+)$/m.exec(workflow)?.[1]).toBe('false')
  })

  test('gives the keys and RPC credentials only to the steps that send', () => {
    const deploySteps = ['Deploy the releases', 'Deploy the profiles']
    const readers = secretReaders(workflow)
    expect(readers.every(({ indent }) => indent === 10)).toBe(true)
    const stepsReading = (secret: string) =>
      readers.filter((reader) => reader.secret === secret).map(({ step }) => step)
    for (const secret of [
      'DEPLOYER_PRIVATE_KEY',
      'TEMPO_RPC_URL',
      'TEMPO_RPC_USERNAME',
      'TEMPO_RPC_PASSWORD',
    ])
      expect(stepsReading(secret), secret).toEqual(deploySteps)
    expect(stepsReading('ZONE_ADMIN_PRIVATE_KEY')).toEqual(['Deploy the profiles'])
    expect(new Set(readers.map(({ secret }) => secret)).size).toBe(5)
  })

  test('restores no dependency or build cache before the keys are used', () => {
    expect(workflow).toMatch(
      /uses: \.\/\.github\/actions\/setup\n(?: {8,}.*\n)* {10}caches: 'false'\n/,
    )
    expect(workflow).not.toMatch(/uses: \.\/\.github\/actions\/(?:solar|forge)-cache/)
    // Every cache the setup action restores or saves is off with caches: 'false'.
    const cacheSteps = setupAction
      .split('\n  steps:\n')[1]!
      .split(/\n(?= {4}- )/)
      .filter((step) =>
        /^ {6}uses: .*(?:actions\/cache|solar-cache|forge-cache)|^ {8}cache: /m.test(step),
      )
    expect(cacheSteps).toHaveLength(6)
    for (const step of cacheSteps) expect(step).toContain("inputs.caches == 'true'")
    // setup-foundry restores and saves ~/.foundry/cache unless its cache input is false.
    expect(cacheSteps.find((step) => step.includes('/setup-foundry@'))).toContain(
      "cache: ${{ inputs.caches == 'true' }}",
    )
  })

  test('runs only from main, in the release environment and hosted-contracts queue', () => {
    expect(workflow).not.toMatch(/^ {2}(?:pull_request|push|schedule|workflow_run)/m)
    expect(workflow.match(/^ {4}if: .*github\.ref == 'refs\/heads\/main'/gm)).toHaveLength(2)
    expect(workflow).toContain('environment: factory-release-${{ matrix.network }}')
    expect(workflow).toContain('group: hosted-contracts-${{ matrix.network }}')
  })

  test('runs the release, records its registry entry, then reconciles every profile', () => {
    const steps = [
      'pnpm release "${arguments[@]}"',
      'pnpm release registry "$RUNNER_TEMP/release.json"',
      'pnpm profiles --network "$NETWORK"',
      'pnpm earn "${deploy[@]}"',
    ].map((step) => workflow.indexOf(step))
    expect(steps.every((index) => index > 0)).toBe(true)
    expect([...steps].sort((a, b) => a - b)).toEqual(steps)
    expect(workflow).toContain('arguments=("$NETWORK" --output "$RUNNER_TEMP/release.json")')
    // The release result reaches the summary and the artifact.
    expect(workflow).toContain('if [[ -f "$RUNNER_TEMP/release.json" ]]; then')
    expect(workflow).toContain('${{ runner.temp }}/release.json')
    expect(workflow).not.toMatch(/factory-release\b(?!-\$)|zone-router-release|card-release/)
  })

  test('replaces the retired release workflows', () => {
    const workflows = readdirSync(new URL('../../.github/workflows/', import.meta.url))
    expect(workflows).not.toContain('bridge-release.yml')
    expect(workflows).not.toContain('zone-router-release.yml')
  })
})

describe('deploy record', () => {
  // The collect and apply commands, as the workflow runs them.
  const line = (pattern: RegExp) => {
    const match = pattern.exec(workflow)?.[0]
    if (!match) throw new Error(`No line matching ${pattern}`)
    return match.trim()
  }
  const intentToAdd = line(/^ +git ls-files -z --others .*$/m)
  const diff = line(/^ +git diff --binary .*$/m).replace(/ > .*$/, ' > "$PATCH"')
  const stage = line(/^ +git add --all -- deployments.*$/m)
  const check = line(/^ +if git diff --cached --quiet .*; then$/m).replace(/^if (.*); then$/, '$1')

  // Fixture repositories ignore the caller's Git config and repository.
  const environment = Object.fromEntries(
    Object.entries(process.env).filter(([name]) => !name.startsWith('GIT_')),
  )
  const run = (cwd: string, script: string, variables: Record<string, string> = {}) =>
    execFileSync('bash', ['-euo', 'pipefail', '-c', script], {
      cwd,
      encoding: 'utf8',
      env: {
        ...environment,
        ...variables,
        GIT_AUTHOR_EMAIL: 'test@example.com',
        GIT_AUTHOR_NAME: 'test',
        GIT_COMMITTER_EMAIL: 'test@example.com',
        GIT_COMMITTER_NAME: 'test',
        GIT_CONFIG_GLOBAL: '/dev/null',
        GIT_CONFIG_NOSYSTEM: '1',
      },
    })
  const status = (cwd: string, script: string) => {
    try {
      run(cwd, script)
      return 0
    } catch (error) {
      return (error as { status: number }).status
    }
  }

  const withRepos = (body: (repo: (name: string) => string, root: string) => void) => {
    const root = mkdtempSync(join(tmpdir(), 'deploy record '))
    try {
      body((name) => {
        const dir = join(root, name)
        run(root, 'git init -q "$NAME"', { NAME: name })
        run(dir, 'mkdir -p deployments/core profiles/old profiles/new')
        writeFileSync(join(dir, '.gitignore'), '**/deployment.pending.json\n')
        writeFileSync(join(dir, 'deployments/core/releases.ts'), 'export {}\n')
        writeFileSync(join(dir, 'profiles/old/profile.json'), '{}\n')
        writeFileSync(join(dir, 'profiles/old/deployment.json'), '{"v":1}\n')
        writeFileSync(join(dir, 'profiles/new/profile.json'), '{}\n')
        run(dir, 'git add -A && git commit -qm init')
        return dir
      }, root)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  }

  const collect = (network: string, patch: string) =>
    run(network, `${intentToAdd}\n${diff}`, { PATCH: patch })
  const apply = (record: string, patch: string) =>
    run(record, `git apply "$PATCH"\n${stage}`, { PATCH: patch })

  test("carries a new profile's first record to the record job", () => {
    withRepos((repo, root) => {
      const network = repo('network')
      writeFileSync(join(network, 'profiles/new/deployment.json'), '{"v":1}\n')
      writeFileSync(join(network, 'profiles/new/deployment.pending.json'), '{}\n')
      const patch = join(root, 'changes.patch')
      collect(network, patch)
      const record = repo('record')
      apply(record, patch)
      expect(status(record, check)).toBe(1)
      expect(run(record, 'git diff --cached --name-only').trim()).toBe(
        'profiles/new/deployment.json',
      )
    })
  })

  test('carries a release change when no record changed, and reports nothing on an unchanged tree', () => {
    withRepos((repo, root) => {
      const network = repo('network')
      run(network, 'git rm -q profiles/old/deployment.json && git commit -qm "no records"')
      writeFileSync(join(network, 'deployments/core/releases.ts'), 'export const changed = 1\n')
      const patch = join(root, 'changes.patch')
      collect(network, patch)
      const record = repo('record')
      apply(record, patch)
      expect(status(record, check)).toBe(1)
      expect(run(record, 'git diff --cached --name-only').trim()).toBe(
        'deployments/core/releases.ts',
      )
      const unchanged = repo('unchanged')
      expect(status(unchanged, `${stage}\n${check}`)).toBe(0)
    })
  })
})

describe('profiles --network', () => {
  test.each(Object.keys(hostedEnvironments))(
    'lists exactly the %s profiles',
    { timeout: 30_000 },
    (network) => {
      // A network may have no committed profile; its listing is then empty, not an error.
      const committed = readdirSync(new URL('../../profiles/', import.meta.url), {
        withFileTypes: true,
      })
        .filter((entry) => entry.isDirectory())
        .map((entry) => `profiles/${entry.name}/profile.json`)
        .filter((path) => {
          const { chainId } = JSON.parse(
            readFileSync(new URL(`../../${path}`, import.meta.url), 'utf8'),
          ) as { chainId: number }
          return hostedEnvironment(chainId)?.id === network
        })
      const listed = JSON.parse(profiles('--network', network)) as { path: string }[]
      expect(listed.map(({ path }) => path).sort()).toEqual(committed.sort())
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

/** Every secret the workflow reads, with its line's indent and the step whose env holds it. */
function secretReaders(text: string) {
  const lines = text.split('\n')
  return lines.flatMap((line, index) => {
    const match = /^( *)[A-Z_]+: .*\bsecrets\.([A-Z_]+)/.exec(line)
    if (!match) return []
    const step = lines
      .slice(0, index)
      .reverse()
      .find((previous) => /^ {6}- name: /.test(previous))
    return [
      { indent: match[1]!.length, secret: match[2]!, step: step?.trim().slice('- name: '.length) },
    ]
  })
}
