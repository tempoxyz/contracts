import { describe, expect, test } from 'vitest'
import { unsupportedReason, type E2eTarget } from '../../harness/case.js'
import type { E2eContext } from '../../harness/context.js'
import { E2ePrerequisiteError } from '../../harness/support/utils.js'
import { cases } from './module.js'
import { assertPendingGrowth, requirePendingFeeGrowth } from './pending.js'

const asset = `0x${'ab'.repeat(20)}` as const
const venue = `0x${'cd'.repeat(20)}` as const
const funder = `0x${'ef'.repeat(20)}` as const

// No clients or signers: readiness must be decided before any RPC or funding.
const fixture = {
  provider: 'local',
  environmentId: 'local',
  engineKind: 'erc4626',
  assets: { base: asset },
  contracts: { asset, venue },
  funding: { baseAsset: asset, venue, funder },
} as E2eContext

const before = {
  assets: 1_000_000n,
  engineShares: 1_000_000n,
  supply: 1_000_000n,
  feeBalance: 0n,
  claimable: 0n,
  pending: { positiveAccrualAssets: 0n, totalFeeAssets: 0n, totalFeeEarnShares: 0n },
}
const pending = {
  ...before,
  assets: 1_100_000n,
  pending: { positiveAccrualAssets: 100_000n, totalFeeAssets: 10_000n, totalFeeEarnShares: 9_174n },
}

describe('requirePendingFeeGrowth', () => {
  test('admits the validated disposable ERC-4626 venue', () => {
    expect(requirePendingFeeGrowth(fixture)).toBeTypeOf('function')
  })

  test.each([
    { provider: 'hosted', environmentId: 'mainnet' },
    { environmentId: 'devnet' },
    { engineKind: 'veda' },
    { engineKind: 'propamm' },
    { funding: undefined },
    { funding: { ...fixture.funding, funder: null } },
    { funding: { ...fixture.funding, venue: asset } },
    { funding: { ...fixture.funding, baseAsset: venue } },
    { contracts: { ...fixture.contracts, asset: venue } },
  ])('refuses unsupported or mismatched fixture %j', (change) => {
    expect(() => requirePendingFeeGrowth({ ...fixture, ...change } as E2eContext)).toThrow(
      E2ePrerequisiteError,
    )
  })
})

describe('assertPendingGrowth', () => {
  test('requires growth without a supply, custody, or claim-ledger change', () => {
    expect(() => assertPendingGrowth(before, pending)).not.toThrow()
  })

  test.each([
    { assets: before.assets },
    { engineShares: before.engineShares + 1n },
    { supply: before.supply + pending.pending.totalFeeEarnShares },
    { feeBalance: pending.pending.totalFeeEarnShares },
    { claimable: pending.pending.totalFeeEarnShares },
    { pending: { ...pending.pending, positiveAccrualAssets: 0n } },
    { pending: { ...pending.pending, totalFeeAssets: 0n } },
    { pending: { ...pending.pending, totalFeeEarnShares: 0n } },
  ])('rejects a vacuous or checkpointed transition %#', (change) => {
    expect(() => assertPendingGrowth(before, { ...pending, ...change })).toThrow()
  })
})

describe('fees-pending-preview-transition', () => {
  const testCase = cases.find(({ id }) => id === 'fees-pending-preview-transition')!
  const target = {
    environment: 'local',
    engineKind: 'erc4626',
    feesActive: true,
    capabilities: { redeem: true, exactWithdraw: true },
  } as E2eTarget

  test('is a launch case for a compatible local fixture', () => {
    expect(testCase.launch).toBe(true)
    expect(unsupportedReason(testCase, target)).toBeUndefined()
    expect(() => testCase.preflight!(fixture)).not.toThrow()
  })

  test.each([
    { environment: 'mainnet' },
    { engineKind: 'veda' },
    { engineKind: 'propamm' },
    { feesActive: false },
    { capabilities: { redeem: true, exactWithdraw: false } },
  ])('cannot select an unsupported target %j', (change) => {
    expect(unsupportedReason(testCase, { ...target, ...change } as E2eTarget)).toBeDefined()
  })
})
