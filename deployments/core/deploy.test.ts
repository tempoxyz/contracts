import { readdirSync, mkdtempSync, chmodSync, writeFileSync, rmSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { tmpdir } from 'node:os'
import { describe, expect, test, vi } from 'vitest'

import { loadEarnProfileBundle } from './bundle.js'
import {
  assertNoPublicFixtureAuthority,
  publicFixtureAddresses,
  formatCommitReadyOutput,
} from './deploy.js'
import type { EarnDeploymentProfile } from './profile.js'

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)))
const fixtures = publicFixtureAddresses()
const profiles = readdirSync(resolve(root, 'profiles'), { withFileTypes: true })
  .filter((entry) => entry.isDirectory())
  .map(
    (entry) => loadEarnProfileBundle(resolve(root, 'profiles', entry.name, 'profile.json')).profile,
  )

describe('public fixture authority', () => {
  test('reads the .env.example identities', () => {
    expect(fixtures.size).toBeGreaterThan(0)
  })

  test.each(profiles.map((profile) => [profile.id, profile] as const))(
    '%s holds no privileged role with a public fixture identity',
    (_, profile) => {
      expect(() => assertNoPublicFixtureAuthority(profile, fixtures)).not.toThrow()
    },
  )

  test('refuses a privileged role held by a public fixture identity', () => {
    const [fixture] = fixtures
    const profile = profiles[0]!
    expect(() =>
      assertNoPublicFixtureAuthority(
        { ...profile, core: { ...profile.core, emergencyGuardian: fixture! } },
        fixtures,
      ),
    ).toThrow(/emergency guardian is the public fixture identity/)
  })

  test('refuses a live external policy administrator held by a public fixture identity', () => {
    const [fixture] = fixtures
    expect(() =>
      assertNoPublicFixtureAuthority(profiles[0]!, fixtures, [
        ['live policy administrator', fixture!],
      ]),
    ).toThrow('live policy administrator is the public fixture identity')
  })

  test("refuses a slice's privileged role held by a public fixture identity", () => {
    const [fixture] = fixtures
    const profile = profiles[0]!
    const boostRewards = { treasury: fixture! } as NonNullable<
      EarnDeploymentProfile['boostRewards']
    >
    expect(() => assertNoPublicFixtureAuthority({ ...profile, boostRewards }, fixtures)).toThrow(
      /reward treasury is the public fixture identity/,
    )
  })
})

describe('formatCommitReadyOutput', () => {
  test('does not pass authority keys or arbitrary loader hooks to the formatter subprocess', () => {
    const directory = mkdtempSync(join(tmpdir(), 'earn-formatter-'))
    try {
      const executable = join(directory, 'pnpm')
      writeFileSync(
        executable,
        `#!/bin/sh
[ -z "\${DEPLOYER_PRIVATE_KEY+x}" ] || exit 11
[ -z "\${ZONE_ADMIN_PRIVATE_KEY+x}" ] || exit 12
[ -z "\${NODE_OPTIONS+x}" ] || exit 13
exit 0
`,
      )
      chmodSync(executable, 0o700)
      vi.stubEnv('PATH', directory)
      vi.stubEnv('DEPLOYER_PRIVATE_KEY', 'fixture-deployer')
      vi.stubEnv('ZONE_ADMIN_PRIVATE_KEY', 'fixture-authority')
      vi.stubEnv('NODE_OPTIONS', '--trace-warnings')
      expect(() =>
        formatCommitReadyOutput(directory, join(directory, 'deployment.json')),
      ).not.toThrow()
    } finally {
      vi.unstubAllEnvs()
      rmSync(directory, { recursive: true, force: true })
    }
  })
})
