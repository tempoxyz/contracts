import { getAddress, zeroAddress } from 'viem'

import {
  readAccessStatus,
  resolveAccessAddress,
  setAccessEligibility,
} from '@tempoxyz/earn/deployments/operations'
import type { E2eBenchmark, E2eCase, LaunchFeature } from '../../harness/case.js'
import { expectContractRevert } from '../../harness/support/transactions.js'
import { assert } from '../../harness/support/utils.js'
import { accessEntryCases } from './entry.js'
import { protectedAccessConfiguration, setOutsiderEligibility } from './shared.js'
import { accessTransferCases } from './transfers.js'

export const launchFeatures: Record<string, LaunchFeature> = {
  'access-policy': {
    dimensions: ['positive', 'negative', 'rollback', 'authorization', 'recovery', 'third-party'],
    applies: ({ accessKind }) => accessKind === 'tip403-whitelist',
  },
}

const accessAdministrationCases: readonly E2eCase[] = [
  {
    id: 'access-admin-guards',
    description:
      'A non-administrator cannot change allowlist membership, the zero address cannot be allowlisted, and policy state is unchanged.',
    default: false,
    launch: true,
    coverage: { 'access-policy': ['negative', 'authorization'] },
    preflight(context) {
      const { accessAdministrator } = protectedAccessConfiguration(context)
      assert(
        getAddress(accessAdministrator) !== getAddress(context.user.address),
        'unauthorized-admin case requires a dedicated administrator',
      )
    },
    async run(context) {
      await setOutsiderEligibility(context, false)
      await expectContractRevert(
        () =>
          setAccessEligibility({
            client: context.l1Public,
            deployment: context.deployment,
            target: context.outsider.address,
            allowed: true,
            wallet: context.actors.user.wallet,
          }),
        'non-administrator unexpectedly changed membership',
      )
      const after = await readAccessStatus(
        context.l1Public,
        context.deployment,
        context.outsider.address,
      )
      assert(!after.eligible, 'failed admin call changed eligibility')
      await expectErrorMessage(
        () => resolveAccessAddress(context.l1Public, zeroAddress),
        'Zero address cannot be allowlisted',
        'zero address unexpectedly resolved for allowlisting',
      )
    },
  },
]

/** Passes only when `action` fails with exactly `expectedMessage`; any other failure propagates. */
async function expectErrorMessage(
  action: () => Promise<unknown>,
  expectedMessage: string,
  message: string,
) {
  try {
    await action()
  } catch (error) {
    if (error instanceof Error && error.message === expectedMessage) return
    throw error
  }
  throw new Error(message)
}

export const cases: readonly E2eCase[] = [
  ...accessAdministrationCases,
  ...accessEntryCases,
  ...accessTransferCases,
].map((testCase) => ({ ...testCase, requiresProtectedAccess: true }))

export const benchmark: E2eBenchmark = {
  async preflight(context) {
    if (context.deployment.access.kind !== 'tip403-whitelist') return
    const access = await readAccessStatus(
      context.l1Public,
      context.deployment,
      context.user.address,
    )
    assert(access.eligible, 'Benchmark user is not eligible for the selected Earn deployment')
  },
}
