import { describe, expect, test } from 'vitest'
import type { E2eContext } from '../../harness/context.js'
import { E2ePrerequisiteError } from '../../harness/support/utils.js'
import { cases } from './module.js'

describe('third-party case preflight', () => {
  test.each(['public-round-trip', 'public-withdraw-exact-third-party'])(
    '%s refuses aliased actors before funding',
    (id) => {
      const testCase = cases.find((entry) => entry.id === id)!
      const context = {
        user: { address: `0x${'ab'.repeat(20)}` },
        operator: { address: `0x${'AB'.repeat(20)}` },
      } as unknown as E2eContext
      expect(() => testCase.preflight!(context)).toThrow(E2ePrerequisiteError)
      expect(() =>
        testCase.preflight!({
          ...context,
          operator: { address: `0x${'cd'.repeat(20)}` },
        } as E2eContext),
      ).not.toThrow()
    },
  )
})
