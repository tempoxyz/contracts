import { describe, expect, it, vi } from 'vitest'
import { ContractFunctionRevertedError, encodeErrorResult, type Address, type Hash } from 'viem'
import { Abis } from 'viem/tempo'

import type { E2eContext } from '../../harness/context.js'
import { unsupportedReason, type E2eTarget } from '../../harness/case.js'
import { accessTransferCases } from './transfers.js'

vi.mock('../../engines/index.js', () => ({ e2eEngines: { erc4626: {} } }))

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
  tokenBalance: (context: { balance: (token: Address) => bigint }, token: Address) =>
    context.balance(token),
}))
vi.mock('../../harness/support/slippage.js', () => ({
  minimumOutput: (amount: bigint) => amount,
  previewEarnDeposit: async () => 90n,
  previewEarnRedeem: async () => 90n,
}))
vi.mock('../rewards/actions.js', () => ({ contributeDirectly: async () => {} }))
vi.mock('../../harness/support/public.js', () => ({
  deposit: async (context: { deposit: () => unknown }) => context.deposit(),
  redeem: async (context: { redeem: (shares: bigint) => unknown }, input: { earnShares: bigint }) =>
    context.redeem(input.earnShares),
  withdrawExact: async (context: { withdraw: (input: Withdrawal) => unknown }, input: Withdrawal) =>
    context.withdraw(input),
}))

type Withdrawal = { assets: bigint; maxEarnShares: bigint; receiver: Address; actor: string }
const removedHolder = accessTransferCases.find(
  (testCase) => testCase.id === 'access-removed-holder',
)!

describe('access-removed-holder', () => {
  it('executes bounded exact withdrawal after re-admission before redeeming the remainder', async () => {
    const state = fixture()
    await removedHolder.run(state.context)
    expect(state.withdrawals).toEqual([
      { actor: 'outsider', assets: 30n, maxEarnShares: 90n, receiver: user },
    ])
    expect(state.redeemed).toEqual([60n])
    expect(state.shares).toBe(17n)
    expect(state.assets).toBe(90n)
    expect(state.eligible).toBe(false)
  })

  it('selects and proves immediate recovery without exact-withdraw capability', async () => {
    const state = fixture()
    state.context.deployment.capabilities.exactWithdraw = false
    const target = {
      engineKind: 'erc4626',
      capabilities: { redeem: true, exactWithdraw: false },
    } as E2eTarget
    expect(unsupportedReason(removedHolder, target)).toBeUndefined()
    expect(
      unsupportedReason(removedHolder, {
        ...target,
        capabilities: { ...target.capabilities, redeem: false },
      }),
    ).toBe('needs the redeem capability')
    await removedHolder.run(state.context)
    expect(state.withdrawals).toHaveLength(0)
    expect(state.negativeExact).toBe(0)
    expect(state.redeemed).toEqual([90n])
    expect(state.shares).toBe(17n)
  })

  it('fails recovery when redeem works but exact withdrawal remains blocked', async () => {
    const state = fixture()
    state.withdrawFailure = new Error('exact withdrawal still blocked')
    await expect(removedHolder.run(state.context)).rejects.toThrow('exact withdrawal still blocked')
    expect(state.withdrawals).toHaveLength(1)
    expect(state.redeemed).toEqual([90n])
    expect(state.shares).toBe(17n)
    expect(state.eligible).toBe(false)
  })

  it('rejects a successful receipt without the requested receiver credit', async () => {
    const state = fixture()
    state.credit = 0n
    await expect(removedHolder.run(state.context)).rejects.toThrow('delivered the wrong assets')
    expect(state.eligible).toBe(false)
  })

  it.each([0n, 91n])('rejects a share burn outside the nonzero bound (%s)', async (burn) => {
    const state = fixture()
    state.burn = burn
    await expect(removedHolder.run(state.context)).rejects.toThrow('violated its share bound')
    expect(state.eligible).toBe(false)
  })

  it('rejects an event that disagrees with the actual share burn', async () => {
    const state = fixture()
    state.reportedBurn = 29n
    await expect(removedHolder.run(state.context)).rejects.toThrow('burn differs from its event')
  })

  it('preserves pre-existing holder shares and originally granted membership', async () => {
    const state = fixture()
    state.eligible = true
    await removedHolder.run(state.context)
    expect(state.shares).toBe(17n)
    expect(state.eligible).toBe(true)
  })

  it('revokes even when the recovery regrant commits then fails its readback', async () => {
    const state = fixture()
    state.failRecoveryReadback = true
    await expect(removedHolder.run(state.context)).rejects.toThrow('regrant readback failed')
    expect(state.eligible).toBe(false)
    expect(state.finalRead).toBe(false)
    expect(state.withdrawals).toHaveLength(0)
  })
})

const user: Address = '0x0000000000000000000000000000000000000001'
const outsider: Address = '0x0000000000000000000000000000000000000002'
const administrator: Address = '0x0000000000000000000000000000000000000003'
const asset: Address = '0x0000000000000000000000000000000000000004'
const hash: Hash = `0x${'ab'.repeat(32)}`

function fixture() {
  const state = {
    eligible: false,
    shares: 17n,
    assets: 0n,
    burn: 30n,
    credit: 30n,
    reportedBurn: 30n,
    withdrawFailure: undefined as Error | undefined,
    failRecoveryReadback: false,
    grants: 0,
    finalRead: false,
    withdrawals: [] as Withdrawal[],
    negativeExact: 0,
    redeemed: [] as bigint[],
    context: undefined as unknown as E2eContext,
  }
  const policyFailure = async () => {
    throw new ContractFunctionRevertedError({
      abi: Abis.tip20,
      data: encodeErrorResult({ abi: Abis.tip20, errorName: 'PolicyForbids' }),
      functionName: 'transfer',
    })
  }
  state.context = {
    user: { address: user },
    outsider: { address: outsider },
    accessAdministrator: { address: administrator },
    contracts: { earnShare: outsider, earnVault: user },
    assets: { base: asset },
    deployment: {
      access: { kind: 'tip403-whitelist', transferPolicyId: '3' },
      operations: { accessAdministrator: administrator },
      capabilities: { redeem: true, exactWithdraw: true },
      network: { pathUsd: asset },
    },
    actors: {
      outsider: {
        account: { address: outsider },
        wallet: {
          sendTransaction: policyFailure,
          earn: {
            deposit: policyFailure,
            withdrawExact: () => {
              state.negativeExact++
              return policyFailure()
            },
            redeem: policyFailure,
          },
        },
      },
      accessAdministrator: { wallet: {} },
    },
    balance: (token: Address) => (token === asset ? state.assets : state.shares),
    deposit: () => {
      state.shares += 90n
      return { earnShares: 90n }
    },
    redeem: (shares: bigint) => {
      state.redeemed.push(shares)
      state.shares -= shares
      state.assets += shares
      return { assets: shares }
    },
    withdraw: (input: Withdrawal) => {
      expect(state.eligible).toBe(true)
      state.withdrawals.push(input)
      if (state.withdrawFailure) throw state.withdrawFailure
      state.shares -= state.burn
      state.assets += state.credit
      return { earnSharesBurned: state.reportedBurn }
    },
    l1Public: {
      status: async () => {
        state.finalRead = state.eligible
        return { eligible: state.eligible }
      },
      set: async (allowed: boolean) => {
        state.eligible = allowed
        if (allowed && ++state.grants >= 2 && state.failRecoveryReadback)
          throw new Error('regrant readback failed')
        return { eligible: allowed, transactionHash: hash }
      },
    },
  } as never
  return state
}
