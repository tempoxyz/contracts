import {
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeFunctionResult,
  zeroAddress,
  type Address,
  type Hex,
} from 'viem'
import { Abis } from 'viem/tempo'
import { describe, expect, it, vi } from 'vitest'

import { assertNoPublicFixtureAuthority, publicFixtureAddresses } from '../../../core/deploy.js'
import type { EarnDeploymentProfile } from '../../../core/profile.js'
import { accessPolicyModule } from './index.js'
import { PolicyStateMismatchError, validateWhitelistPolicy } from './policy.js'
import { validateAccess } from './steps.js'

const administrator = '0x0000000000000000000000000000000000000001' as const
const earnShare = '0x20c0000000000000000000000000000000000001' as const
const protectedProfile = {
  access: { kind: 'tip403-whitelist', policyId: '469' },
} as EarnDeploymentProfile

describe('live access administrator authority', () => {
  it('rejects a public fixture administrator in the hosted lifecycle guard', async () => {
    const fixtures = publicFixtureAddresses()
    const [fixture] = fixtures
    const profile = {
      ...protectedProfile,
      id: 'protected',
      owner: administrator,
      core: { fees: { fixed: [] } },
    } as unknown as EarnDeploymentProfile
    const principals = await accessPolicyModule.livePrivilegedPrincipals!(
      policyClient({ administrator: fixture! }),
      profile,
    )
    expect(() => assertNoPublicFixtureAuthority(profile, fixtures, principals)).toThrow(
      'access administrator is the public fixture identity',
    )
  })

  it('contributes the live whitelist administrator to the hosted fixture-authority guard', async () => {
    await expect(
      accessPolicyModule.livePrivilegedPrincipals!(policyClient(), protectedProfile),
    ).resolves.toEqual([['access administrator', administrator]])
  })

  it('contributes no authority and performs no RPC reads for open access', async () => {
    const client = policyClient({ failure: 'policyData' })
    await expect(
      accessPolicyModule.livePrivilegedPrincipals!(client, {
        access: { kind: 'open' },
      } as EarnDeploymentProfile),
    ).resolves.toEqual([])
    expect(client.rpcRequest).not.toHaveBeenCalled()
  })

  it('propagates failed administrator reads instead of omitting the authority', async () => {
    await expect(
      accessPolicyModule.livePrivilegedPrincipals!(
        policyClient({ failure: 'policyData' }),
        protectedProfile,
      ),
    ).rejects.toThrow('RPC unavailable for policyData')
  })
})

describe('validate-access satisfaction', () => {
  it('accepts a matching whitelist binding', async () => {
    await expect(
      validateAccess.satisfied(policyClient(), protectedProfile, { earnShare }),
    ).resolves.toBe(true)
  })

  it.each([{ tokenPolicyId: 470n }, { policyType: 1 }, { administrator: zeroAddress }])(
    'returns false for positively observed mismatches: %o',
    async (state) => {
      await expect(
        validateAccess.satisfied(policyClient(state), protectedProfile, { earnShare }),
      ).resolves.toBe(false)
    },
  )

  it('returns false when the EarnShare has not been deployed', async () => {
    await expect(validateAccess.satisfied(policyClient(), protectedProfile, {})).resolves.toBe(
      false,
    )
  })

  it.each(['transferPolicyId', 'policyData'])(
    'propagates transport failures reading %s',
    async (failure) => {
      await expect(
        validateAccess.satisfied(policyClient({ failure }), protectedProfile, { earnShare }),
      ).rejects.toThrow(`RPC unavailable for ${failure}`)
    },
  )

  it('does not read a policy for open access', async () => {
    const client = policyClient({ failure: 'transferPolicyId' })
    await expect(
      validateAccess.satisfied(client, { access: { kind: 'open' } } as EarnDeploymentProfile, {}),
    ).resolves.toBe(true)
    expect(client.rpcRequest).not.toHaveBeenCalled()
  })
})

describe('validateWhitelistPolicy', () => {
  it('keeps explicit local/demo policy reads compatible with public fixture administrators', async () => {
    const [fixture] = publicFixtureAddresses()
    expect(fixture).toBeDefined()
    await expect(
      validateWhitelistPolicy(policyClient({ administrator: fixture! }), {
        policyId: 469n,
        requiredMembers: [],
      }),
    ).resolves.toBe(fixture)
  })

  it('identifies an unauthorized member as a state mismatch', async () => {
    await expect(
      validateWhitelistPolicy(policyClient({ authorized: false }), {
        policyId: 469n,
        requiredMembers: [administrator],
      }),
    ).rejects.toBeInstanceOf(PolicyStateMismatchError)
  })

  it('preserves a member-read transport failure instead of calling the member unauthorized', async () => {
    await expect(
      validateWhitelistPolicy(policyClient({ failure: 'isAuthorized' }), {
        policyId: 469n,
        requiredMembers: [administrator],
      }),
    ).rejects.toThrow('RPC unavailable for isAuthorized')
  })
})

// Simulated RPC responses exercise decoding and error propagation, not live policy guarantees.
function policyClient(
  options: {
    administrator?: Address
    authorized?: boolean
    failure?: string
    policyType?: number
    tokenPolicyId?: bigint
  } = {},
) {
  const request = vi.fn(async ({ method, params }: { method: string; params?: unknown[] }) => {
    if (method !== 'eth_call') throw new Error(`Unexpected RPC method ${method}`)
    const { data } = params![0] as { data: Hex }
    const decoded = decodeFunctionData({ abi: [...Abis.tip20, ...Abis.tip403Registry], data })
    const { functionName } = decoded
    if (functionName === options.failure) throw new Error(`RPC unavailable for ${functionName}`)
    if (functionName === 'transferPolicyId')
      return encodeFunctionResult({
        abi: Abis.tip20,
        functionName,
        result: options.tokenPolicyId ?? 469n,
      })
    if (functionName === 'policyData')
      return encodeFunctionResult({
        abi: Abis.tip403Registry,
        functionName,
        result: [options.policyType ?? 0, options.administrator ?? administrator],
      })
    if (functionName === 'isAuthorized')
      return encodeFunctionResult({
        abi: Abis.tip403Registry,
        functionName,
        result: options.authorized ?? true,
      })
    throw new Error(`Unexpected contract read ${functionName}`)
  })
  return {
    ...createPublicClient({ transport: custom({ request }, { retryCount: 0 }) }),
    rpcRequest: request,
  }
}
