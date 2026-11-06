import { isAddressEqual, type Address } from 'viem'
import { E2ePrerequisiteError } from '../../harness/support/utils.js'

/** Refuses ambiguous control-test identities before any funding or authority mutation. */
export function requireControlActors(input: {
  user: Address
  operator: Address
  outsider: Address
  vaultOperator: Address
  guardian: Address
}) {
  if (!isAddressEqual(input.operator, input.vaultOperator))
    throw new E2ePrerequisiteError(
      'Controls require the configured operator to be the EarnVault operator',
    )
  if (isAddressEqual(input.user, input.vaultOperator) || isAddressEqual(input.user, input.guardian))
    throw new E2ePrerequisiteError(
      'Controls require a distinct end user who is neither the EarnVault operator nor emergency guardian; configure END_USER_PRIVATE_KEY',
    )
  if (
    isAddressEqual(input.outsider, input.vaultOperator) ||
    isAddressEqual(input.outsider, input.user)
  )
    throw new E2ePrerequisiteError(
      'Controls require distinct user, operator, and temporary guardian actors',
    )
}
