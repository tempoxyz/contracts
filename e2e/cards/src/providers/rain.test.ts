import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import {
  BaseError,
  ContractFunctionRevertedError,
  encodeErrorResult,
  getAddress,
  parseAbi,
  zeroAddress,
  type Hex,
} from 'viem'
import { describe, expect, test } from 'vitest'

import { expectUnauthorizedWithdrawal, parseRainDeployment, withRainReport } from './rain.js'

const withdrawalAbi = parseAbi([
  'function withdrawAsset(address asset, address recipient, uint256 amount)',
])
const errorAbi = parseAbi(['error Error(string)', 'error Panic(uint256)', 'error Unauthorized()'])

describe('expectUnauthorizedWithdrawal', () => {
  test('accepts only the exact Rain Error(Unauthorized) revert through the viem error chain', async () => {
    const error = reverted(
      encodeErrorResult({ abi: errorAbi, errorName: 'Error', args: ['Unauthorized'] }),
    )
    await expect(expectUnauthorizedWithdrawal(Promise.reject(error))).resolves.toBeUndefined()
  })

  test('rejects a successful direct withdrawal', async () => {
    await expect(
      expectUnauthorizedWithdrawal(Promise.resolve({ result: undefined })),
    ).rejects.toThrow('exactly Unauthorized')
  })

  test.each([
    ['transport failure', new BaseError('RPC connection refused')],
    ['malformed response', new SyntaxError('Unexpected end of JSON input')],
    ['unverified error text', new Error('Unauthorized')],
    ['empty revert', reverted('0x')],
    ['malformed revert', reverted('0x1234')],
    [
      'other reason',
      reverted(
        encodeErrorResult({ abi: errorAbi, errorName: 'Error', args: ['Invalid signature'] }),
      ),
    ],
    [
      'reason containing Unauthorized',
      reverted(
        encodeErrorResult({ abi: errorAbi, errorName: 'Error', args: ['Unauthorized token'] }),
      ),
    ],
    [
      'different error with the same name',
      reverted(encodeErrorResult({ abi: errorAbi, errorName: 'Unauthorized' })),
    ],
    ['panic', reverted(encodeErrorResult({ abi: errorAbi, errorName: 'Panic', args: [0x11n] }))],
  ])('rejects %s instead of recording authorization success', async (_, error) => {
    await expect(expectUnauthorizedWithdrawal(Promise.reject(error))).rejects.toThrow(
      'exactly Unauthorized',
    )
  })
})

describe('parseRainDeployment', () => {
  test('accepts the current run and normalizes address comparison', () => {
    const { expected, report } = fixture()
    expect(
      parseRainDeployment(
        JSON.stringify({ ...report, rainAdmin: getAddress(report.rainAdmin) }),
        expected,
      ),
    ).toMatchObject({ ...expected, rainAdmin: getAddress(report.rainAdmin) })
  })

  test.each([
    'runId',
    'chainId',
    'zoneId',
    'deployer',
    'rainAdmin',
    'rainTreasury',
    'cardholder',
    'partner',
    'earn',
  ] as const)("rejects another run's %s", (field) => {
    const { expected, report } = fixture()
    const foreign = {
      runId: 'other-run',
      chainId: expected.chainId + 1,
      zoneId: expected.zoneId + 1,
      deployer: address('f1'),
      rainAdmin: address('f2'),
      rainTreasury: address('f3'),
      cardholder: address('f4'),
      partner: address('f5'),
      earn: !expected.earn,
    }
    expect(() =>
      parseRainDeployment(JSON.stringify({ ...report, [field]: foreign[field] }), expected),
    ).toThrow(`Rain report ${field} matches this run`)
  })

  test.each([
    'runId',
    'chainId',
    'zoneId',
    'deployer',
    'rainAdmin',
    'rainTreasury',
    'cardholder',
    'partner',
    'earn',
  ] as const)('rejects a legacy report missing %s', (field) => {
    const { expected, report } = fixture()
    expect(() =>
      parseRainDeployment(JSON.stringify({ ...report, [field]: undefined }), expected),
    ).toThrow(`Rain report ${field}`)
  })

  test.each([
    'rainFactory',
    'rainController',
    'cardholderCollateral',
    'programCollateral',
    'cardFactory',
    'provider',
    'program',
    'routerFactory',
    'router',
    'zoneToken',
  ] as const)('rejects a missing, malformed or zero %s before adopting the report', (field) => {
    const { expected, report } = fixture()
    for (const invalid of [undefined, 'invalid-address', zeroAddress])
      expect(() =>
        parseRainDeployment(JSON.stringify({ ...report, [field]: invalid }), expected),
      ).toThrow(`Rain report ${field} is a nonzero address`)
  })

  test('rejects a missing or unexpected Earn deployment', () => {
    const { expected, report } = fixture()
    const earn = { earnVault: address('20'), earnShare: address('21') }
    expect(() => parseRainDeployment(JSON.stringify({ ...report, ...earn }), expected)).toThrow(
      'no unrequested Earn deployment',
    )
    expect(() =>
      parseRainDeployment(JSON.stringify({ ...report, earn: true }), { ...expected, earn: true }),
    ).toThrow('earnVault')
    expect(() =>
      parseRainDeployment(JSON.stringify({ ...report, earn: true, earnVault: earn.earnVault }), {
        ...expected,
        earn: true,
      }),
    ).toThrow('earnShare')
    expect(
      parseRainDeployment(JSON.stringify({ ...report, earn: true, ...earn }), {
        ...expected,
        earn: true,
      }),
    ).toMatchObject(earn)
  })

  test.each([
    { cardholderCollateralIndex: 1 },
    { programCollateralIndex: 0 },
    { cardholderCollateralIndex: '0' },
  ])('rejects foreign collateral indexes %o', (indexes) => {
    const { expected, report } = fixture()
    expect(() => parseRainDeployment(JSON.stringify({ ...report, ...indexes }), expected)).toThrow(
      'collateral indexes',
    )
  })

  test.each(['null', '[]', 'false', '"deployment"', '{'])(
    'rejects a malformed report %s',
    (json) => {
      expect(() => parseRainDeployment(json, fixture().expected)).toThrow()
    },
  )
})

describe('withRainReport', () => {
  test('isolates overlapping reports for the same Zone and rejects a swapped invocation', () => {
    const paths: string[] = []
    withRainReport((first, firstId) => {
      paths.push(first)
      const { expected, report } = fixture()
      writeFileSync(first, JSON.stringify({ ...report, runId: firstId }))
      withRainReport((second, secondId) => {
        paths.push(second)
        expect(dirname(second)).not.toBe(dirname(first))
        expect(secondId).not.toBe(firstId)
        expect(existsSync(second)).toBe(false)
        writeFileSync(
          second,
          JSON.stringify({ ...report, runId: secondId, program: address('99') }),
        )
        expect(
          parseRainDeployment(readFileSync(first, 'utf8'), { ...expected, runId: firstId }).program,
        ).toBe(report.program)
        expect(
          parseRainDeployment(readFileSync(second, 'utf8'), { ...expected, runId: secondId })
            .program,
        ).toBe(address('99'))
        expect(() =>
          parseRainDeployment(readFileSync(second, 'utf8'), { ...expected, runId: firstId }),
        ).toThrow('runId matches this run')
      })
      expect(existsSync(dirname(paths[1]!))).toBe(false)
      expect(existsSync(first)).toBe(true)
    })
    for (const path of paths) expect(existsSync(dirname(path))).toBe(false)
  })

  test('cleans its directory after a child or validation failure', () => {
    let out = ''
    expect(() =>
      withRainReport((path) => {
        out = path
        writeFileSync(path, 'incomplete output')
        throw new Error('deployment failed')
      }),
    ).toThrow('deployment failed')
    expect(existsSync(dirname(out))).toBe(false)
  })

  test('does not reuse a prior report when the child produces no output', () => {
    withRainReport((out) => writeFileSync(out, JSON.stringify(fixture().report)))
    expect(() => withRainReport((out) => readFileSync(out, 'utf8'))).toThrow('ENOENT')
  })
})

function reverted(data: Hex) {
  return new BaseError('Simulation failed', {
    cause: new ContractFunctionRevertedError({
      abi: withdrawalAbi,
      data,
      functionName: 'withdrawAsset',
    }),
  })
}

function address(byte: string): `0x${string}` {
  return `0x${byte.repeat(20)}`
}

function fixture() {
  const expected = {
    runId: 'rain-current-run',
    chainId: 1337,
    zoneId: 1,
    deployer: address('a1'),
    rainAdmin: address('a2'),
    rainTreasury: address('a3'),
    cardholder: address('a4'),
    partner: address('a5'),
    earn: false,
  }
  return {
    expected,
    report: {
      ...expected,
      rainFactory: address('01'),
      rainController: address('02'),
      cardholderCollateral: address('03'),
      cardholderCollateralIndex: 0,
      programCollateral: address('04'),
      programCollateralIndex: 1,
      cardFactory: address('05'),
      provider: address('06'),
      program: address('07'),
      routerFactory: address('08'),
      router: address('09'),
      zoneToken: address('10'),
    },
  }
}
