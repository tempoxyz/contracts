import { expect, test } from 'vitest'

import { isSourceVerifiableCompiler } from './foundry.js'

test('a solar compiler cannot be source verified on hosted chains', () => {
  expect(isSourceVerifiableCompiler('./solar-solc')).toBe(false)
  expect(isSourceVerifiableCompiler('/repo/earn/solar-solc')).toBe(false)
  expect(isSourceVerifiableCompiler('/home/u/.solar/abc/bin/solar')).toBe(false)
  expect(isSourceVerifiableCompiler(null)).toBe(true)
  expect(isSourceVerifiableCompiler(undefined)).toBe(true)
  expect(isSourceVerifiableCompiler('/home/u/.svm/0.8.36/solc-0.8.36')).toBe(true)
})
