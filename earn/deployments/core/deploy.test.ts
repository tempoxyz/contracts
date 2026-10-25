import { readdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, test } from 'vitest'

import { loadEarnProfileBundle } from './bundle.js'
import { assertNoPublicFixtureAuthority, publicFixtureAddresses } from './deploy.js'
import type { EarnDeploymentProfile } from './profile.js'

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)))
const fixtures = publicFixtureAddresses(root)
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
