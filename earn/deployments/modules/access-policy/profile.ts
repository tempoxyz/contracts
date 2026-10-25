import { tip403PolicyId } from '../../core/parse.js'
import type { ProfileSlice, SliceProfile } from '../module.js'

/** Who may hold and move EarnShare: anyone, or members of one reusable TIP-403 whitelist. */
export type AccessIntent = { kind: 'open' } | { kind: 'tip403-whitelist'; policyId: string }

/** The profile field the access slice owns. */
export type AccessFields = { access: AccessIntent }

type AccessProfile = SliceProfile<AccessFields>

/**
 * The `access` profile slice, authored as `tip403PolicyId`. EarnFactory binds the policy when it
 * deploys EarnShare, so access is hashed into the `core` intent component.
 */
export const accessPolicyProfile = {
  authoredKeys: ['tip403PolicyId'],
  parse: (root: Record<string, unknown>): AccessFields => ({
    access:
      root.tip403PolicyId === undefined
        ? { kind: 'open' }
        : {
            kind: 'tip403-whitelist',
            policyId: tip403PolicyId(root.tip403PolicyId, 'profile.json.tip403PolicyId'),
          },
  }),
  authored: (profile: AccessProfile) =>
    profile.access.kind === 'tip403-whitelist' ? { tip403PolicyId: profile.access.policyId } : {},
  deploymentIntent: (profile: AccessProfile) => ({ access: profile.access }),
  coreIntent: (profile: AccessProfile) => ({ access: profile.access }),
  // Zero leaves an open EarnShare on the always-allow builtin policy.
  coreDeployParams: (profile: AccessProfile) => ({ transferPolicyId: transferPolicyId(profile) }),
} as const satisfies ProfileSlice<AccessFields>

/** The EarnShare transfer policy a protected profile binds, or `undefined` when access is open. */
export function transferPolicyId(profile: AccessFields) {
  return profile.access.kind === 'open' ? undefined : BigInt(profile.access.policyId)
}
