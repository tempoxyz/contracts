import { readdirSync, readFileSync } from 'node:fs'
import { engineKinds } from '@tempoxyz/earn/deployments'
import { deploymentAddressKeysForProfile } from '@tempoxyz/earn/deployments/node'
import {
  optionalPeriphery,
  parseEarnDeploymentProfile,
  profileCapabilities,
  type EarnDeploymentProfile,
} from '@tempoxyz/earn/deployments/operations'
import { Deployment } from 'localnet'
import { getAddress } from 'viem'
import { describe, expect, it } from 'vitest'

import type { E2eTarget } from './case.js'
import { hostedEnvironmentId } from './environments.js'
import { cases, validateLaunchFeatureCoverage } from './modules.js'
import { profileFeesActive } from './profile.js'
import { selectCases } from './runner.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`)

function profileTarget(
  profile: EarnDeploymentProfile,
  periphery: E2eTarget['periphery'],
  environment: E2eTarget['environment'],
): E2eTarget {
  return {
    engineKind: profile.engine.kind,
    environment,
    capabilities: profileCapabilities(profile),
    accessKind: profile.access.kind,
    periphery,
    feesActive: profileFeesActive(profile),
  }
}

describe('launch feature coverage', () => {
  it('lets every committed profile pass --launch with the cases it can select', () => {
    const profiles = readdirSync(new URL('../../earn/profiles/', import.meta.url), {
      withFileTypes: true,
    }).filter((entry) => entry.isDirectory())
    for (const { name } of profiles) {
      const read = (file: string) =>
        JSON.parse(
          readFileSync(new URL(`../../earn/profiles/${name}/${file}`, import.meta.url), 'utf8'),
        )
      const profile = parseEarnDeploymentProfile(read('profile.json'))
      const target = profileTarget(
        profile,
        optionalPeriphery(read('deployment.json').addresses),
        hostedEnvironmentId(profile.chainId),
      )
      expect(
        () => validateLaunchFeatureCoverage(selectCases({ mode: 'launch' }, target), target),
        name,
      ).not.toThrow()
    }
  })
})

describe('local E2E CI', () => {
  it('runs a shard set for every engine kind', () => {
    const workflow = readFileSync(
      new URL('../../.github/workflows/local-zone.yml', import.meta.url),
      'utf8',
    )
    const variants = /^\s+variant: \[([^\]]*)\]$/m.exec(workflow)?.[1]?.split(/,\s*/)
    expect([...(variants ?? [])].sort()).toEqual([...engineKinds].sort())
  })

  it('lets some local variant select every case that can run locally, and pass --launch', () => {
    const deployer = address('d')
    // CI runs `--all` once per engine kind against the profile that variant deploys by default.
    const selectable = new Set(
      engineKinds.flatMap((engineKind) => {
        const profile = Deployment.localizeProfile(
          Deployment.variantProfile({
            access: Deployment.variantAccess,
            customerId: Deployment.routerCustomerId,
            deployer,
            engineKind,
            now: 0,
            revenueShareRecipient: address('5'),
          }),
          {
            chainId: 1337,
            deployer,
            factories: { earn: address('f1'), erc4626Engine: address('f2') },
            venueOrEngine: address('7e'),
            policyId: Deployment.variantAccess === 'tip403-whitelist' ? 2n : undefined,
            zoneId: 1,
            conversion: { privateAsset: address('a1'), pool: address('9001') },
            vaultAsset: address('ba5e'),
          },
        )
        const target = profileTarget(
          profile,
          // The periphery this profile's lifecycle records; any address marks it deployed.
          optionalPeriphery(
            Object.fromEntries(
              deploymentAddressKeysForProfile(profile).map((key) => [key, deployer]),
            ),
          ),
          'local',
        )
        validateLaunchFeatureCoverage(selectCases({ mode: 'launch' }, target), target)
        return selectCases({ mode: 'all' }, target).map(({ id }) => id)
      }),
    )
    const unselectable = cases
      .filter((testCase) => !testCase.environments || testCase.environments.includes('local'))
      .filter((testCase) => !selectable.has(testCase.id))
      .map((testCase) => testCase.id)
    expect(unselectable).toEqual([])
  })
})
