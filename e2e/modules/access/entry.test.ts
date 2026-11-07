import { describe, expect, it, vi } from 'vitest'
import {
  BaseError,
  ContractFunctionRevertedError,
  encodeErrorResult,
  type Address,
  type Hash,
} from 'viem'
import { Abis, Actions, ExecutionError } from 'viem/tempo'

import type { E2eContext } from '../../harness/context.js'
import { accessEntryCases } from './entry.js'

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
vi.mock('../../harness/support/funding.js', () => ({
  mintVaultAsset: async () => {},
  tokenBalance: (
    context: { balance: (token: Address, holder: Address) => bigint },
    token: Address,
    holder: Address,
  ) => context.balance(token, holder),
}))
vi.mock('../../harness/support/slippage.js', () => ({
  minimumOutput: (amount: bigint) => amount,
  previewEarnDeposit: async () => 100n,
  previewEarnRedeem: async () => 100n,
}))
vi.mock('../../harness/support/public.js', () => ({
  depositIntoVenue: async () => ({ venueShares: 100n }),
  deposit: async () => ({ earnShares: 100n }),
  redeem: async (
    context: { redeem: (shares: bigint, actor?: string) => void },
    input: { earnShares: bigint; actor?: string },
  ) => context.redeem(input.earnShares, input.actor),
  expectUnchanged: async (_context: unknown, _label: string, reject: () => Promise<void>) =>
    reject(),
}))

const receiverPolicy = accessEntryCases.find(
  (testCase) => testCase.id === 'access-receiver-policy',
)!

describe('access-receiver-policy', () => {
  it('pairs each rejected operation with the identical operation after admission', async () => {
    const state = fixture()
    await receiverPolicy.run(state.context)
    expect(state.calls.map(({ actor, kind, eligible }) => [actor, kind, eligible])).toEqual([
      ['outsider', 'deposit', false],
      ['outsider', 'deposit', true],
      ['user', 'deposit', false],
      ['user', 'deposit', true],
      ['outsider', 'depositShares', false],
      ['outsider', 'depositShares', true],
    ])
    for (let index = 0; index < state.calls.length; index += 2) {
      expect(state.calls[index].input).toEqual(state.calls[index + 1].input)
    }
    expect(state.eligible).toBe(false)
    expect(state.shares).toBe(17n)
  })

  it('does not accept an unrelated contract error as receiver policy enforcement', async () => {
    const state = fixture()
    state.revert = new ContractFunctionRevertedError({
      abi: Abis.tip20,
      data: encodeErrorResult({ abi: Abis.tip20, errorName: 'InsufficientAllowance' }),
      functionName: 'deposit',
    })
    await expect(receiverPolicy.run(state.context)).rejects.toBe(state.revert)
    expect(state.calls).toHaveLength(1)
    expect(state.eligible).toBe(false)
  })

  it('does not accept a policy-labeled admission error without execution evidence', async () => {
    const state = fixture()
    state.revert = policyWrapper(new BaseError('transaction rejected by admission'))
    await expect(receiverPolicy.run(state.context)).rejects.toBe(state.revert)
    expect(state.calls).toHaveLength(1)
    expect(state.eligible).toBe(false)
  })

  it('accepts a policy wrapper backed by an actual contract revert', async () => {
    const state = fixture()
    state.revert = policyWrapper(state.revert as ContractFunctionRevertedError)
    await receiverPolicy.run(state.context)
    expect(state.calls).toHaveLength(6)
    expect(state.eligible).toBe(false)
  })

  it('does not accept a bare reverted receipt as receiver policy enforcement', async () => {
    const state = fixture()
    state.revert = undefined
    state.receiptStatus = 'reverted'
    await expect(receiverPolicy.run(state.context)).rejects.toThrow(
      'unexpectedly minted to an ineligible receiver',
    )
    expect(state.calls).toHaveLength(1)
  })

  it.each(['user', 'depositShares'])(
    'requires the admitted %s control to work',
    async (failure) => {
      const state = fixture()
      state.failPositive = failure
      await expect(receiverPolicy.run(state.context)).rejects.toThrow('positive operation failed')
      expect(state.eligible).toBe(false)
    },
  )

  it('requires nonzero credited output after admission', async () => {
    const state = fixture()
    state.minted = 0n
    await expect(receiverPolicy.run(state.context)).rejects.toThrow(
      'admitted receiver did not receive',
    )
    expect(state.eligible).toBe(false)
  })

  it('restores membership when the outsider was originally eligible', async () => {
    const state = fixture()
    state.eligible = true
    await receiverPolicy.run(state.context)
    expect(state.eligible).toBe(true)
  })
})

const user: Address = '0x0000000000000000000000000000000000000001'
const outsider: Address = '0x0000000000000000000000000000000000000002'
const administrator: Address = '0x0000000000000000000000000000000000000003'
const hash: Hash = `0x${'ab'.repeat(32)}`

function fixture() {
  const state = {
    eligible: false,
    shares: 17n,
    minted: 100n,
    receiptStatus: 'success',
    failPositive: '',
    revert: new ContractFunctionRevertedError({
      abi: Abis.tip20,
      data: encodeErrorResult({ abi: Abis.tip20, errorName: 'PolicyForbids' }),
      functionName: 'deposit',
    }) as Error | undefined,
    calls: [] as { actor: string; kind: string; eligible: boolean; input: unknown }[],
    context: undefined as unknown as E2eContext,
  }
  const earn = (actor: string) =>
    Object.fromEntries(
      ['deposit', 'depositShares'].map((kind) => [
        kind,
        async (input: unknown) => {
          state.calls.push({ actor, kind, input, eligible: state.eligible })
          if (!state.eligible) {
            if (state.revert) throw state.revert
            return hash
          }
          if (actor === state.failPositive || kind === state.failPositive)
            throw new Error('positive operation failed')
          state.shares += state.minted
          return hash
        },
      ]),
    )
  state.context = {
    user: { address: user },
    outsider: { address: outsider },
    accessAdministrator: { address: administrator },
    contracts: { earnShare: outsider, earnVault: user, venue: administrator },
    deployment: {
      access: { kind: 'tip403-whitelist', transferPolicyId: '3' },
      operations: { accessAdministrator: administrator },
      capabilities: { inKindDeposit: true },
    },
    actors: {
      outsider: { wallet: { earn: earn('outsider') } },
      user: { wallet: { earn: earn('user') } },
      accessAdministrator: { wallet: {} },
    },
    balance: () => state.shares,
    redeem: (shares: bigint, actor?: string) => {
      if (actor === 'outsider') state.shares -= shares
    },
    l1Public: {
      status: async () => ({ eligible: state.eligible }),
      set: async (allowed: boolean) => {
        state.eligible = allowed
        return { eligible: allowed, transactionHash: hash }
      },
      readContract: async () => 100n,
      waitForTransactionReceipt: async () => ({ status: state.receiptStatus }),
    },
  } as never
  return state
}

function policyWrapper(cause: BaseError) {
  const error = ExecutionError.from(
    encodeErrorResult({ abi: Abis.tip20, errorName: 'PolicyForbids' }),
  )
  if (error.errorName !== 'PolicyForbids') throw new Error('fixture policy error did not decode')
  return new Actions.token.TokenPolicyForbidsError({ cause, error, hints: [], token: outsider })
}
