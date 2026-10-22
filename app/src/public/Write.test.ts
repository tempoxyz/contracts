import { decodeFunctionData, erc20Abi, getAddress } from 'viem'
import { Abis } from 'viem/tempo'
import { beforeEach, describe, expect, test, vi } from 'vitest'

import { hosted } from '../test/HostedCatalog.js'

const dependency = vi.hoisted(() => ({
  readDepositEligibility: vi.fn(),
  readPublicPreview: vi.fn(),
  readPublicWriteState: vi.fn(),
  simulateCalls: vi.fn(),
}))

vi.mock('../earn/AccessVerification.js', () => ({
  readDepositEligibility: dependency.readDepositEligibility,
}))
vi.mock('../earn/Verification.js', () => ({
  readPublicWriteState: dependency.readPublicWriteState,
}))
vi.mock('@tempoxyz/earn/deployments', async (importOriginal) => ({
  ...(await importOriginal()),
  quoteEarnDeposit: dependency.readPublicPreview,
}))
vi.mock('viem/actions', async (importOriginal) => ({
  ...(await importOriginal()),
  simulateCalls: dependency.simulateCalls,
}))

import { actions } from '../earn/Actions.js'
import * as Write from './Write.js'

const environment = hosted.environments.find(
  (candidate) => candidate.id === hosted.defaultEnvironmentId,
)!
const registeredDeployment = environment.stacks.find(
  (candidate) => candidate.id === environment.defaultStackId,
)!
const deployment = {
  ...registeredDeployment,
  capabilities: { ...registeredDeployment.capabilities, deposit: true },
}
const account = getAddress('0x0000000000000000000000000000000000000009')

describe('public Earn writes', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    dependency.readDepositEligibility.mockResolvedValue(true)
    dependency.readPublicPreview.mockResolvedValue(1_000_000n)
  })

  test('batches an exact approval before deposit', () => {
    const calls = actions.deposit.calls({
      account,
      amount: 1_000_000n,
      deployment,
      bound: 995_000n,
    })
    expect(calls).toHaveLength(2)
    expect(decodeFunctionData({ abi: erc20Abi, data: calls[0]!.data! })).toMatchObject({
      functionName: 'approve',
      args: [deployment.contracts.earnVault, 1_000_000n],
    })
    expect(decodeFunctionData({ abi: Abis.earnVault, data: calls[1]!.data! })).toMatchObject({
      functionName: 'deposit',
      args: [1_000_000n, account, 995_000n],
    })
  })

  test('uses the share token approval for redeem', () => {
    const [approval, redeem] = actions.redeem.calls({
      account,
      amount: 500_000n,
      deployment,
      bound: 497_500n,
    })
    expect(approval?.to).toBe(deployment.contracts.earnShare)
    expect(decodeFunctionData({ abi: Abis.earnVault, data: redeem!.data! })).toMatchObject({
      functionName: 'redeem',
      args: [500_000n, account, 497_500n],
    })
  })

  test('rejects a deployment whose accounting changed', async () => {
    dependency.readPublicWriteState.mockResolvedValue({
      engineMatches: true,
      isAccountingAligned: false,
    })

    await expect(
      Write.prepare({
        account,
        action: 'deposit',
        amount: 1_000_000n,
        deployment,
        publicClient: {} as never,
        reviewedQuote: 1_000_000n,
      }),
    ).rejects.toThrow('EarnVault accounting is not aligned.')
    expect(dependency.simulateCalls).not.toHaveBeenCalled()
  })

  test('signs the reviewed bound and refuses a live quote that misses it', async () => {
    dependency.readPublicWriteState.mockResolvedValue({
      engineMatches: true,
      isAccountingAligned: true,
    })
    dependency.simulateCalls.mockResolvedValue({ results: [] })
    const options = {
      account,
      action: 'deposit' as const,
      amount: 1_000_000n,
      deployment,
      publicClient: {} as never,
      reviewedQuote: 1_000_000n,
    }

    // Within tolerance: the bound stays the reviewed one, not one derived from the live quote.
    dependency.readPublicPreview.mockResolvedValue(996_000n)
    const [, deposit] = await Write.prepare(options)
    expect(decodeFunctionData({ abi: Abis.earnVault, data: deposit!.data! })).toMatchObject({
      args: [1_000_000n, account, 995_000n],
    })

    dependency.readPublicPreview.mockResolvedValue(994_999n)
    await expect(Write.prepare(options)).rejects.toThrow(Write.QuoteChangedError)
  })
})
