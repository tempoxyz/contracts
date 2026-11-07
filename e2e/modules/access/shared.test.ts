import { describe, expect, it, vi } from 'vitest'
import { decodeFunctionData, erc20Abi, type Address } from 'viem'

import type { E2eContext } from '../../harness/context.js'
import { requirePolicyZoneRead, withEarnShareAllowance, withOutsiderEligibility } from './shared.js'
import { E2ePrerequisiteError } from '../../harness/support/utils.js'
import { cases } from './module.js'

vi.mock('@tempoxyz/contracts/deployments/operations', () => ({
  requireProtectedAccess: (deployment: E2eContext['deployment']) => ({
    access: deployment.access,
    accessAdministrator: deployment.operations.accessAdministrator,
  }),
  readAccessStatus: (client: { status: () => unknown }) => client.status(),
  setAccessEligibility: ({
    client,
    allowed,
  }: {
    client: { set: (allowed: boolean) => unknown }
    allowed: boolean
  }) => client.set(allowed),
}))
vi.mock('../zone/readiness.js', () => ({
  authorizeZoneActor: (context: { authorize: () => unknown }) => context.authorize(),
}))

describe('requirePolicyZoneRead', () => {
  it.each([false, true])(
    'accepts readable policy state regardless of current membership %s',
    async (eligible) => {
      const state = fixture(eligible)
      state.authorize = () => {
        state.events.push('authorize')
      }
      const read = vi.fn(async () => eligible)
      state.context.policyZoneClient = { readContract: read } as never
      await requirePolicyZoneRead(state.context)
      expect(state.events).toEqual(['authorize'])
      expect(read).toHaveBeenCalledWith(
        expect.objectContaining({ functionName: 'isAuthorized', args: [3n, spender] }),
      )
    },
  )

  it('blocks the access case before writes when the configured lane rejects global policy reads', async () => {
    const state = fixture(false)
    const failure = new Error('OnlyPrecompiles')
    state.context.policyZoneClient = {
      readContract: async () => {
        throw failure
      },
    } as never
    const preflight = cases.find((item) => item.id === 'access-admin-guards')!.preflight!
    await expect(preflight(state.context)).rejects.toThrow(E2ePrerequisiteError)
    await expect(requirePolicyZoneRead(state.context)).rejects.toMatchObject({ cause: failure })
    expect(state.events).toEqual([])
  })

  it('does not require a Zone policy lane for a public-only stack', async () => {
    const state = fixture(false)
    await requirePolicyZoneRead(state.context)
    expect(state.events).toEqual([])
  })
})

describe('withOutsiderEligibility', () => {
  it.each([false, true])(
    'restores original membership %s after a successful case',
    async (original) => {
      const state = fixture(original)
      await withOutsiderEligibility(state.context, !original, async () => {
        expect(state.eligible).toBe(!original)
      })
      expect(state.eligible).toBe(original)
      expect(state.events.at(-1)).toBe(`read ${original}`)
    },
  )

  it('revokes and verifies L1 after the grant commits but Zone authorization fails', async () => {
    const state = fixture(false)
    state.context.policyZoneClient = {} as never
    const failure = new Error('Zone authorization denied')
    state.authorize = () => {
      throw failure
    }
    const run = vi.fn()
    await expect(withOutsiderEligibility(state.context, true, run)).rejects.toBe(failure)
    expect(run).not.toHaveBeenCalled()
    expect(state.eligible).toBe(false)
    expect(state.events).toEqual(['read false', 'set true', 'set false', 'read false'])
  })

  it('revokes and verifies L1 even when the Zone rejects both policy readbacks', async () => {
    const state = fixture(false)
    const failure = Object.assign(new Error('Zone policy read denied'), { status: 403 })
    const read = vi.fn(async () => {
      throw failure
    })
    state.context.policyZoneClient = { readContract: read } as never
    await expect(withOutsiderEligibility(state.context, true, async () => {})).rejects.toBe(failure)
    expect(read).toHaveBeenCalledTimes(2)
    expect(state.events).toEqual(['read false', 'set true', 'set false', 'read false'])
    expect(state.eligible).toBe(false)
  })

  it('restores even when L1 grant readback fails after committing', async () => {
    const state = fixture(false)
    const failure = new Error('L1 readback failed')
    state.afterSet = (allowed) => {
      if (allowed) throw failure
    }
    await expect(withOutsiderEligibility(state.context, true, async () => {})).rejects.toBe(failure)
    expect(state.eligible).toBe(false)
    expect(state.events.at(-1)).toBe('read false')
  })

  it('restores when a recovery regrant fails after committing', async () => {
    const state = fixture(false)
    const failure = new Error('Recovery readback failed')
    await expect(
      withOutsiderEligibility(state.context, true, async () => {
        state.eligible = false
        state.afterSet = (allowed) => {
          if (allowed) throw failure
        }
        // The nested restoration scope also guards its initial grant.
        await withOutsiderEligibility(state.context, true, async () => {})
      }),
    ).rejects.toBe(failure)
    expect(state.eligible).toBe(false)
    expect(state.events.at(-1)).toBe('read false')
  })

  it('fails when the final L1 membership is not restored', async () => {
    const state = fixture(false)
    state.afterSet = (allowed) => {
      if (!allowed) state.eligible = true
    }
    await expect(withOutsiderEligibility(state.context, true, async () => {})).rejects.toThrow(
      'Outsider L1 membership was not restored',
    )
  })
})

describe('withEarnShareAllowance', () => {
  it.each([0n, 29n])('restores previous allowance %s after success', async (before) => {
    const state = fixture(false, before)
    await withEarnShareAllowance(state.context, spender, 100n, async () => {
      expect(state.allowance).toBe(100n)
    })
    expect(state.allowance).toBe(before)
  })

  it('restores a pre-existing allowance after a failed negative assertion', async () => {
    const state = fixture(false, 29n)
    const failure = new Error('Negative operation unexpectedly succeeded')
    await expect(
      withEarnShareAllowance(state.context, spender, 100n, async () => {
        throw failure
      }),
    ).rejects.toBe(failure)
    expect(state.allowance).toBe(29n)
  })

  it('restores after approval commits but receipt read fails', async () => {
    const state = fixture(false, 29n)
    const failure = new Error('Receipt unavailable')
    state.afterApprove = (amount) => {
      if (amount === 100n) throw failure
    }
    await expect(withEarnShareAllowance(state.context, spender, 100n, async () => {})).rejects.toBe(
      failure,
    )
    expect(state.allowance).toBe(29n)
  })

  it('rejects a restore that leaves a standing allowance', async () => {
    const state = fixture(false)
    state.afterApprove = (amount) => {
      if (amount === 0n) state.allowance = 100n
    }
    await expect(
      withEarnShareAllowance(state.context, spender, 100n, async () => {}),
    ).rejects.toThrow('EarnShare allowance was not restored')
  })
})

const user: Address = '0x0000000000000000000000000000000000000001'
const spender: Address = '0x0000000000000000000000000000000000000002'
const administrator: Address = '0x0000000000000000000000000000000000000003'
const hash = `0x${'ab'.repeat(32)}` as const

function fixture(eligible: boolean, allowance = 0n) {
  const state = {
    eligible,
    allowance,
    events: [] as string[],
    authorize: (): void => {},
    afterSet: (_allowed: boolean): void => {},
    afterApprove: (_amount: bigint): void => {},
    context: undefined as unknown as E2eContext,
  }
  state.context = {
    user: { address: user },
    outsider: { address: spender },
    accessAdministrator: { address: administrator },
    contracts: { earnShare: spender },
    deployment: {
      access: { kind: 'tip403-whitelist', transferPolicyId: '3' },
      operations: { accessAdministrator: administrator },
      network: { pathUsd: spender },
    },
    authorize: () => state.authorize(),
    actors: {
      accessAdministrator: { wallet: {} },
      user: {
        account: { address: user },
        wallet: {
          sendTransaction: async ({ calls }: { calls: { data: `0x${string}` }[] }) => {
            const decoded = decodeFunctionData({ abi: erc20Abi, data: calls[0].data })
            if (decoded.functionName !== 'approve') throw new Error('unexpected call')
            state.allowance = decoded.args[1]
            state.afterApprove(state.allowance)
            return hash
          },
        },
      },
    },
    l1Public: {
      status: async () => {
        state.events.push(`read ${state.eligible}`)
        return { eligible: state.eligible }
      },
      set: async (allowed: boolean) => {
        state.events.push(`set ${allowed}`)
        state.eligible = allowed
        state.afterSet(allowed)
        return { eligible: allowed, transactionHash: hash }
      },
      readContract: async () => state.allowance,
      waitForTransactionReceipt: async () => ({ status: 'success' }),
    },
  } as never
  return state
}
