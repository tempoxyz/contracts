import { describe, expect, test } from 'vitest'

import { chainMs, createTimings, formatTiming } from './timings.js'

describe('timings', () => {
  test('since returns only the entries recorded after a mark', async () => {
    const timings = createTimings()
    timings.record({ action: 'before', phases: [] })
    const mark = timings.mark()
    timings.record({
      action: 'public-deposit',
      phases: [{ phase: 'submit-to-receipt', ms: 512, clock: 'wall' }],
    })
    timings.record(Promise.resolve({ action: 'zone-redeem', phases: [] }))
    expect((await timings.since(mark)).map((entry) => entry.action)).toEqual([
      'public-deposit',
      'zone-redeem',
    ])
  })

  test('chainMs reads formatted and hex timestampMillis', () => {
    expect(chainMs({ timestampMillis: 1_000n }, { timestampMillis: '0x7d0' })).toBe(1_000)
    expect(chainMs({ timestampMillis: 1_000n }, { timestamp: 2n })).toBeUndefined()
  })

  test('formatTiming marks chain phases', () => {
    expect(
      formatTiming({
        action: 'zone-redeem',
        phases: [
          { phase: 'zone-submit-to-receipt', ms: 581.4, clock: 'wall' },
          { phase: 'zone-receipt-to-l1-callback', ms: 1483, clock: 'chain' },
        ],
      }),
    ).toBe(
      'TIMING   zone-redeem: zone-submit-to-receipt 581ms · zone-receipt-to-l1-callback 1483ms (chain)',
    )
  })
})
