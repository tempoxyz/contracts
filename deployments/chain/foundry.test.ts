import { expect, test } from 'vitest'

import { solarVerificationArguments, solcWrapperVersion } from './foundry.js'

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

test('a solar build is passed to the verifier by its exact version', () => {
  expect(
    solarVerificationArguments(
      './solar-solc',
      'solar the Solidity compiler\nVersion: 0.8.36+commit.d83529b.solar.0.2.0\n',
    ),
  ).toEqual([
    '--compiler-version',
    '0.8.36+commit.d83529b.solar.0.2.0',
    '--compilation-profile',
    'default',
  ])
})

test('a solar build that does not name its version is refused before broadcast', () => {
  expect(() =>
    solarVerificationArguments(
      '/repo/.solar/abc/bin/solar',
      'solar Version: 0.2.0\nCommit SHA: abc\n',
    ),
  ).toThrow('does not report a source-verifiable build')
  expect(() =>
    solarVerificationArguments(
      './solar-solc',
      'Version: 0.8.36+commit.d83529b.solar.0.3.0-beta.1\n',
    ),
  ).toThrow('does not report a source-verifiable build')
})

test('solc needs no verification arguments', () => {
  expect(
    solarVerificationArguments(
      '/svm/0.8.36/solc-0.8.36',
      'Version: 0.8.36+commit.8a079791.Linux.g++\n',
    ),
  ).toEqual([])
})
