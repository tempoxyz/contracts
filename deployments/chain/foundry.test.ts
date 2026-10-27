import { expect, test } from 'vitest'

import { solcWrapperVersion } from './foundry.js'

test('a solar solc wrapper names its exact build for source verification', () => {
  expect(
    solcWrapperVersion('solar the Solidity compiler\nVersion: 0.8.36+commit.d83529b.solar.0.2.0\n'),
  ).toBe('0.8.36+commit.d83529b.solar.0.2.0')
})

test('solc needs no compiler override', () => {
  expect(
    solcWrapperVersion(
      'solc, the solidity compiler commandline interface\nVersion: 0.8.36+commit.8a079791.Linux.g++\n',
    ),
  ).toBeNull()
  expect(solcWrapperVersion('solar Version: 0.2.0\nCommit SHA: d83529b\n')).toBeNull()
})
