import { beforeEach, describe, expect, test, vi } from 'vitest'
import { runE2e } from './runner.js'
import type { E2eContext } from './context.js'

const hooks = vi.hoisted(() => ({
  baseline: vi.fn(),
  integrity: vi.fn(),
  run: vi.fn(),
  cleanup: vi.fn(),
  write: vi.fn(),
}))
vi.mock('./integrity.js', () => ({
  captureCaseIntegrity: hooks.baseline,
  assertCaseIntegrity: hooks.integrity,
}))
vi.mock('./results.js', () => ({ writeResult: hooks.write }))
vi.mock('./modules.js', () => ({
  cases: ['first', 'second', 'third'].map((id) => ({
    id,
    group: 'public',
    default: true,
    launch: false,
    run: hooks.run,
    cleanup: hooks.cleanup,
  })),
  groups: ['public'],
  validateLaunchFeatureCoverage: vi.fn(),
  caseById: vi.fn(),
}))

function options() {
  return {
    context: {
      environmentId: 'local',
      provider: 'local',
      deploymentId: 'test',
      engineKind: 'erc4626',
      deployment: { capabilities: {}, access: { kind: 'open' } },
      contracts: {},
      operations: {},
      l1Public: { readContract: async () => false },
      timings: { mark: () => 0, since: async () => [] },
      progress: { withMuted: async (action: () => unknown) => action(), step: () => {} },
    } as unknown as E2eContext,
    manifest: { sha256: 'test', source: 'test' },
    source: { commit: 'test', dirty: false },
    selection: { mode: 'default' } as const,
  }
}

beforeEach(() => {
  vi.resetAllMocks()
  hooks.baseline.mockResolvedValue({})
  hooks.write.mockReturnValue('test-result.json')
})

describe('runE2e', () => {
  test('retains completed cases and records a failed baseline without running or cleaning that case', async () => {
    hooks.baseline
      .mockResolvedValueOnce({})
      .mockRejectedValueOnce(new Error('baseline unavailable'))
    await expect(runE2e(options())).resolves.toEqual({ failures: 1 })
    const result = hooks.write.mock.calls[0]![1]
    expect(result.selectedCases).toEqual(['first', 'second', 'third'])
    expect(result.completed).toBe(true)
    expect(result.cases.map((entry: { status: string }) => entry.status)).toEqual([
      'PASS',
      'FAIL',
      'PASS',
    ])
    expect(result.cases[1].failure).toContain('baseline unavailable')
    expect(hooks.run).toHaveBeenCalledTimes(2)
    expect(hooks.cleanup).toHaveBeenCalledTimes(2)
  })

  test('persists partial outcomes with the complete selection on unexpected interruption', async () => {
    const input = options()
    let marks = 0
    input.context.timings.mark = () => {
      if (++marks === 2) throw new Error('unexpected interruption')
      return 0
    }
    await expect(runE2e(input)).rejects.toThrow('unexpected interruption')
    expect(hooks.write.mock.calls[0]![1]).toMatchObject({
      completed: false,
      selectedCases: ['first', 'second', 'third'],
      cases: [{ id: 'first', status: 'PASS' }],
    })
  })

  test('turns timing RPC failure into a structured case failure instead of discarding the run', async () => {
    const input = options()
    input.context.timings.since = async () => {
      throw new Error('timing unavailable')
    }
    await expect(runE2e(input)).resolves.toEqual({ failures: 3 })
    expect(
      hooks.write.mock.calls[0]![1].cases.every(
        (entry: { status: string }) => entry.status === 'FAIL',
      ),
    ).toBe(true)
  })
})
