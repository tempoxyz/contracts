import { describe, expect, it } from 'vitest'
import {
  BaseError,
  ContractFunctionRevertedError,
  RpcRequestError,
  encodeAbiParameters,
  encodeErrorResult,
  encodeEventTopics,
  parseAbi,
  parseAbiParameters,
  toFunctionSelector,
  type Address,
  type Hex,
  type Log,
} from 'viem'
import { ExecutionError, TempoExecutionError } from 'viem/tempo'

import * as Support from './support.js'

const portal = '0x1111111111111111111111111111111111111111'
const router = '0x2222222222222222222222222222222222222222'
const program = '0x3333333333333333333333333333333333333333'
const clone = '0x4444444444444444444444444444444444444444'
const foreign = '0x5555555555555555555555555555555555555555'
const cardholder = '0x6666666666666666666666666666666666666666'
const ref = `0x${'11'.repeat(32)}` as Hex
const tag1 = `0x${'22'.repeat(32)}` as Hex
const tag2 = `0x${'33'.repeat(32)}` as Hex
const request = {
  to: router,
  token: Support.pathUsd,
  amount: 21n,
  senderTag: tag1,
} satisfies Parameters<typeof Support.withdrawalLogs>[2]
const spentAbi = parseAbi([
  'event Spent(address indexed spender, address indexed token, uint256 used, uint256 change, bytes32 zoneDepositHash)',
])

describe('withdrawalRequested', () => {
  const source = log(
    Support.outbox,
    0,
    encodeEventTopics({
      abi: Support.outboxAbi,
      eventName: 'WithdrawalRequested',
      args: { withdrawalIndex: 1n, sender: cardholder },
    }),
    encodeAbiParameters(
      parseAbiParameters('address,address,uint128,uint128,bytes32,uint64,uint64,bytes,bytes'),
      [Support.pathUsd, router, 21n, 2n, ref, 3_000_000n, 1n, '0x1234', '0x'],
    ),
  )
  it('binds the correlation tag to the source transaction, not the reused application ref', () => {
    const first = Support.withdrawalRequested({ logs: [source], transactionHash: tag1 })
    const second = Support.withdrawalRequested({ logs: [source], transactionHash: tag2 })
    expect(first.senderTag).not.toBe(second.senderTag)
    expect(first.to).toBe(router)
    expect(first.amount).toBe(21n)
    expect(first.fee).toBe(2n)
  })
  it('rejects foreign or ambiguous outbox source evidence', () => {
    expect(() =>
      Support.withdrawalRequested({
        logs: [{ ...source, address: foreign }],
        transactionHash: tag1,
      }),
    ).toThrow('exactly one outbox')
    expect(() =>
      Support.withdrawalRequested({
        logs: [source, { ...source, logIndex: 1 }],
        transactionHash: tag1,
      }),
    ).toThrow('exactly one outbox')
  })
})

describe('withdrawalLogs', () => {
  it('attributes two same-router settlements with a reused ref to their source tags', () => {
    const logs = [
      card(0),
      executed(1),
      spent(2),
      processed(3, tag1),
      card(4),
      executed(5),
      spent(6),
      processed(7, tag2),
    ]
    const first = Support.withdrawalLogs(logs, portal, request, true)
    const second = Support.withdrawalLogs(logs, portal, { ...request, senderTag: tag2 }, true)
    expect(first.map((log) => log.logIndex)).toEqual([0, 1, 2])
    expect(second.map((log) => log.logIndex)).toEqual([4, 5, 6])
    expect(Support.cardSpent(first, program, ref, clone).amount).toBe(20n)
    expect(Support.cardSpent(second, program, ref, clone).amount).toBe(20n)
  })
  it('does not accept another withdrawal merely because it has the same application ref', () => {
    expect(() =>
      Support.withdrawalLogs([card(0), executed(1), processed(2, tag2)], portal, request, true),
    ).toThrow('one canonical Portal event')
  })
  it('does not accept a forged Portal emitter', () => {
    expect(() =>
      Support.withdrawalLogs([{ ...processed(0, tag1), address: foreign }], portal, request, true),
    ).toThrow('one canonical Portal event')
  })
  it.each([
    { ...request, token: foreign },
    { ...request, to: foreign },
    { ...request, amount: 22n },
  ] satisfies Parameters<typeof Support.withdrawalLogs>[2][])(
    'rejects a mismatched withdrawal body',
    (different) => {
      expect(() => Support.withdrawalLogs([processed(0, tag1)], portal, different, true)).toThrow(
        'expected withdrawal',
      )
    },
  )
  it('does not turn a failed callback into a successful spend', () => {
    const logs = [processed(0, tag1, false)]
    expect(() => Support.withdrawalLogs(logs, portal, request, true)).toThrow('expected withdrawal')
    expect(Support.withdrawalLogs(logs, portal, request, false)).toEqual([])
  })
  it('rejects ambiguous duplicate Portal events', () => {
    expect(() =>
      Support.withdrawalLogs([processed(0, tag1), processed(1, tag1)], portal, request, true),
    ).toThrow('one canonical Portal event')
  })
})

describe('cardSpent', () => {
  it('requires the Bridge clone emitter, not just a matching ref and from', () => {
    expect(() => Support.cardSpent([card(0), executed(1, foreign)], program, ref, clone)).toThrow(
      'one TempoSpendExecuted',
    )
  })
  it('ignores a foreign event beside the authentic clone event', () => {
    expect(
      Support.cardSpent([card(0), executed(1), executed(2, foreign)], program, ref, clone)
        .sharesBurned,
    ).toBe(0n)
  })
})

describe('zoneTransactionFee', () => {
  const receipt = {
    gasUsed: 21_001n,
    effectiveGasPrice: 1_000_000_000n,
    feeToken: Support.pathUsd,
    feePayer: cardholder,
  } satisfies Parameters<typeof Support.zoneTransactionFee>[0]
  it('rounds independently measured attodollar gas fees up to token units', () => {
    expect(Support.zoneTransactionFee(receipt, cardholder)).toBe(22n)
    expect(Support.zoneTransactionFee({ ...receipt, effectiveGasPrice: 0n }, cardholder)).toBe(0n)
  })
  it('fails closed when fee currency or payer evidence is absent or different', () => {
    expect(() =>
      Support.zoneTransactionFee({ ...receipt, feeToken: undefined }, cardholder),
    ).toThrow('fee token')
    expect(() => Support.zoneTransactionFee({ ...receipt, feeToken: foreign }, cardholder)).toThrow(
      'fee token',
    )
    expect(() => Support.zoneTransactionFee({ ...receipt, feePayer: foreign }, cardholder)).toThrow(
      'fee payer',
    )
  })
  it('does not classify an extra request-block debit as fees', () => {
    const fee = Support.zoneTransactionFee(receipt, cardholder)
    expect(() =>
      Support.assertWithdrawalDebit(100n, 100n - 21n - 2n - fee, 21n, 2n, fee),
    ).not.toThrow()
    expect(() =>
      Support.assertWithdrawalDebit(100n, 100n - 21n - 2n - fee - 1n, 21n, 2n, fee),
    ).toThrow('debited exactly')
  })
})

describe('inputNames', () => {
  it('catches a calldata-only leak on both Tempo and ordinary settlement transactions', () => {
    const data = encodeAbiParameters(parseAbiParameters('address'), [cardholder])
    expect(Support.names([], cardholder)).toBe(false)
    expect(Support.inputNames({ input: data }, cardholder)).toBe(true)
    expect(Support.inputNames({ calls: [{ data }] }, cardholder)).toBe(true)
    expect(Support.inputNames({ calls: [{ data: ref }] }, cardholder)).toBe(false)
  })
  it('does not certify privacy without transaction input', () => {
    expect(() => Support.inputNames({ calls: [] }, cardholder)).toThrow('no calldata')
  })
})

describe('revertData', () => {
  it('does not certify an authorization refusal from an outage or arbitrary error', () => {
    expect(Support.revertData(new BaseError('gateway timeout'))).toBeUndefined()
    expect(Support.revertData(new Error('CallNotAllowed()'))).toBeUndefined()
    expect(Support.revertData(undefined)).toBeUndefined()
  })
  it('retains the exact native eth_fillTransaction execution-revert bytes', () => {
    const data = toFunctionSelector('CallNotAllowed()')
    const rpc = new RpcRequestError({
      body: { method: 'eth_fillTransaction', params: [] },
      error: {
        code: 3,
        data,
        message: 'execution reverted: Account keychain error: CallNotAllowed(CallNotAllowed)',
      },
      url: 'http://127.0.0.1:8545',
    })
    const wrapped = new BaseError('transaction preparation failed', { cause: rpc })
    expect(Support.revertData(wrapped)).toBe(data)
    expect(Support.revertDiagnostic(wrapped)).toBe(`BaseError; RPC code 3; revert selector ${data}`)
  })
  it.each([
    { code: -32000, data: toFunctionSelector('CallNotAllowed()') },
    { code: 3, data: undefined },
    { code: -32003, data: undefined },
    { code: 3, data: '0x576b38b' },
    { code: 3, data: 'not hex' },
  ])('does not accept an RPC message or malformed revert as authorization proof', (error) => {
    const rpc = new RpcRequestError({
      body: { method: 'eth_fillTransaction', params: [] },
      error: {
        ...error,
        message: 'execution reverted: Account keychain error: CallNotAllowed(CallNotAllowed)',
      },
      url: 'http://127.0.0.1:8545',
    })
    expect(Support.revertData(new BaseError('wrapped', { cause: rpc }))).toBeUndefined()
  })
  it('keeps diagnostics free of request bodies and encoded addresses', () => {
    const rpc = new RpcRequestError({
      body: { method: 'eth_fillTransaction', params: [{ from: cardholder }] },
      error: {
        code: 3,
        data: encodeErrorResult({
          abi: parseAbi(['error DestinationNotAuthorized(address destination)']),
          errorName: 'DestinationNotAuthorized',
          args: [cardholder],
        }),
        message: 'execution reverted',
      },
      url: 'https://user:secret@example.com/private',
    })
    const diagnostic = Support.revertDiagnostic(rpc)
    expect(diagnostic).not.toContain(cardholder.slice(2))
    expect(diagnostic).not.toContain('secret')
    expect(diagnostic).not.toContain('eth_fillTransaction')
    expect(Support.revertDiagnostic(undefined)).toBe(
      'no error; RPC code none; revert selector none',
    )
  })
  it('rejects a decoded Tempo wrapper without original revert bytes', () => {
    const data = toFunctionSelector('CallNotAllowed()')
    const decoded = ExecutionError.from(data)
    if (decoded.errorName === 'unknown') throw new Error('missing Tempo scope error')
    const error = new TempoExecutionError({
      cause: new BaseError('reverted'),
      error: decoded,
      hints: [],
    })
    expect(Support.revertData(error)).toBeUndefined()
  })
  it('reads original RPC bytes through a decoded Tempo wrapper', () => {
    const data = toFunctionSelector('CallNotAllowed()')
    const decoded = ExecutionError.from(data)
    if (decoded.errorName === 'unknown') throw new Error('missing Tempo scope error')
    const error = new TempoExecutionError({
      cause: new RpcRequestError({
        body: { method: 'eth_fillTransaction', params: [] },
        error: { code: 3, data, message: 'execution reverted' },
        url: 'http://127.0.0.1:8545',
      }),
      error: decoded,
      hints: [],
    })
    expect(Support.revertData(error)).toBe(data)
  })
  it('distinguishes destination authorization from an allowance failure', () => {
    const abi = parseAbi([
      'error DestinationNotAuthorized(address destination)',
      'error InsufficientAllowance()',
    ])
    const refusal = encodeErrorResult({
      abi,
      errorName: 'DestinationNotAuthorized',
      args: [foreign],
    })
    expect(
      Support.revertData(
        new ContractFunctionRevertedError({ abi, data: refusal, functionName: 'spend' }),
      ),
    ).toBe(refusal)
    const unrelated = encodeErrorResult({ abi, errorName: 'InsufficientAllowance' })
    expect(
      Support.revertData(
        new ContractFunctionRevertedError({ abi, data: unrelated, functionName: 'spend' }),
      ),
    ).not.toBe(refusal)
  })
})

function log(
  address: Address,
  logIndex: number,
  topics: ReturnType<typeof encodeEventTopics>,
  data: Hex,
): Log {
  if (!topics.every((topic) => typeof topic === 'string'))
    throw new Error('fixture topics must be concrete')
  return {
    address,
    blockHash: ref,
    blockNumber: 1n,
    data,
    logIndex,
    removed: false,
    topics: [...topics] as Log['topics'],
    transactionHash: ref,
    transactionIndex: 0,
  }
}
function processed(index: number, senderTag: Hex, callbackSuccess = true) {
  return log(
    portal,
    index,
    encodeEventTopics({
      abi: Support.portalEventsAbi,
      eventName: 'WithdrawalProcessed',
      args: { to: router, senderTag },
    }),
    encodeAbiParameters(parseAbiParameters('address,uint128,bool'), [
      Support.pathUsd,
      21n,
      callbackSuccess,
    ]),
  )
}
function card(index: number) {
  return log(
    program,
    index,
    encodeEventTopics({
      abi: Support.programAbi,
      eventName: 'CardSpent',
      args: { ref, payer: router, destination: foreign },
    }),
    encodeAbiParameters(parseAbiParameters('address,uint256,uint256,uint256,bool'), [
      Support.pathUsd,
      20n,
      0n,
      0n,
      true,
    ]),
  )
}
function executed(index: number, emitter: Address = clone) {
  return log(
    emitter,
    index,
    encodeEventTopics({
      abi: Support.tempoSpendAbi,
      eventName: 'TempoSpendExecuted',
      args: { ref, from: program, destination: foreign },
    }),
    encodeAbiParameters(parseAbiParameters('address,uint256,uint256,uint256,uint256'), [
      Support.pathUsd,
      20n,
      20n,
      0n,
      0n,
    ]),
  )
}
function spent(index: number) {
  return log(
    router,
    index,
    encodeEventTopics({
      abi: spentAbi,
      eventName: 'Spent',
      args: { spender: program, token: Support.pathUsd },
    }),
    encodeAbiParameters(parseAbiParameters('uint256,uint256,bytes32'), [20n, 1n, ref]),
  )
}
