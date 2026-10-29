import { capabilityKeys, type DeploymentCapabilities } from '@tempoxyz/contracts/deployments'
import { describe, expect, test } from 'vitest'

import type { E2eTarget } from './case.js'
import { cases, validateLaunchFeatureCoverage } from './modules.js'
import { selectCases } from './runner.js'

const target: E2eTarget = {
  engineKind: 'erc4626',
  environment: 'moderato',
  capabilities: Object.fromEntries(
    capabilityKeys.map((key) => [key, true]),
  ) as DeploymentCapabilities,
  accessKind: 'open',
  periphery: {},
  feesActive: true,
}
const ids = (selection: Parameters<typeof selectCases>[0], selected = target) =>
  selectCases(selection, selected).map(({ id }) => id)

describe('E2E selection', () => {
  test('deterministically partitions the complete suite into disjoint balanced shards', () => {
    const veda = { ...target, engineKind: 'veda', environment: 'local' } as const
    const all = ids({ mode: 'all' }, veda)
    const first = ids({ mode: 'all', shard: '1/2' }, veda)
    const second = ids({ mode: 'all', shard: '2/2' }, veda)

    expect(first.filter((id) => second.includes(id))).toEqual([])
    expect([...first, ...second].sort()).toEqual([...all].sort())
    const weight = (selected: readonly string[]) =>
      selected.reduce(
        (total, id) => total + (cases.find((testCase) => testCase.id === id)?.weight ?? 1),
        0,
      )
    expect(Math.abs(weight(first) - weight(second))).toBeLessThanOrEqual(
      Math.max(...cases.map((testCase) => testCase.weight ?? 1)),
    )
  })

  test('selects exit cases and requires their launch coverage only where the engine declares the exit', () => {
    const exitCases = ['public-round-trip', 'public-withdraw-exact-third-party']
    expect(ids({ mode: 'all' })).toEqual(expect.arrayContaining(exitCases))
    const capabilities = { ...target.capabilities, exactWithdraw: false }
    const withoutExactWithdraw = { ...target, capabilities }
    const launch = selectCases({ mode: 'launch' }, withoutExactWithdraw)
    expect(launch.map(({ id }) => id)).not.toContain('public-withdraw-exact-third-party')
    expect(() => validateLaunchFeatureCoverage(launch, withoutExactWithdraw)).not.toThrow()
    expect(() => validateLaunchFeatureCoverage(launch, target)).toThrow('exact-withdraw')
    expect(
      ids({ mode: 'all' }, { ...target, capabilities: { ...capabilities, redeem: false } }),
    ).not.toContain('public-round-trip')
  })

  test('refuses a named case the target cannot run instead of skipping it', () => {
    expect(() => ids({ mode: 'case', value: 'access-transfer-policy' })).toThrow(
      'needs protected TIP-403 access',
    )
    expect(() => ids({ mode: 'group', value: 'missing' })).toThrow('Unknown group')
  })
})
