import { isAddressEqual, type Address } from 'viem'
import { E2ePrerequisiteError } from '../../harness/support/utils.js'

/** Requires the owner for recovery and a genuinely unauthorized user before reward mutations. */
export function requireRewardActors(input: { user: Address; operator: Address; owner: Address }) {
  if (!isAddressEqual(input.operator, input.owner))
    throw new E2ePrerequisiteError(
      'Rewards require the configured operator to own EarnContributionController',
    )
  if (isAddressEqual(input.user, input.owner))
    throw new E2ePrerequisiteError(
      'Rewards require an end user distinct from the controller owner; configure END_USER_PRIVATE_KEY',
    )
}
