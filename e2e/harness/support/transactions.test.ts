import {
  BaseError,
  ContractFunctionRevertedError,
  ExecutionRevertedError,
  HttpRequestError,
  RpcRequestError,
  TransactionReceiptNotFoundError,
  WaitForTransactionReceiptTimeoutError,
  createClient,
  createWalletClient,
  custom,
  encodeErrorResult,
  parseAbi,
  type Abi,
  type TransactionReceipt,
} from 'viem'
import { mainnet } from 'viem/chains'
import { Abis, Actions, ExecutionError, TempoExecutionError } from 'viem/tempo'
import { describe, expect, it } from 'vitest'

import type { E2eContext } from '../context.js'
import { expectContractRevert, expectRevertedReceipt, expectRevertedWrite } from './transactions.js'

const abi = parseAbi(['error NotOperator()', 'error Paused()', 'error AmountTooLow(uint256)'])
const expected = { abi, errorName: 'NotOperator' }
const message = 'expected contract revert'
const hash = `0x${'ab'.repeat(32)}` as const
const address = `0x${'12'.repeat(20)}` as const

const unrelatedErrors = [
  new Error('RPC unavailable'),
  new HttpRequestError({ status: 503, url: 'https://rpc.example.test' }),
  new TransactionReceiptNotFoundError({ hash }),
  new WaitForTransactionReceiptTimeoutError({ hash }),
  new Error('execution reverted: NotOperator'),
  new ExecutionRevertedError(),
  new ContractFunctionRevertedError({ abi, functionName: 'deposit' }),
  new ContractFunctionRevertedError({ abi, functionName: 'deposit', data: '0x' }),
  new ContractFunctionRevertedError({ abi, functionName: 'deposit', data: '0xabc' }),
  new ContractFunctionRevertedError({
    abi,
    functionName: 'deposit',
    message: 'execution reverted: NotOperator',
  }),
  new BaseError('RPC unavailable', { name: 'ContractFunctionRevertedError' }),
  new BaseError('RPC unavailable', { name: 'TransactionReceiptRevertedError' }),
  new BaseError('RPC unavailable', {
    cause: Object.assign(new Error('RPC unavailable'), { name: 'ExecutionRevertedError' }),
  }),
]

describe('expectContractRevert', () => {
  it.each([
    ['direct', contractRevert()],
    ['wrapped', new BaseError('contract call failed', { cause: contractRevert() })],
    [
      'execution',
      new ExecutionRevertedError({
        cause: rpcError({
          code: 3,
          errorName: 'NotOperator',
          data: encodeErrorResult({ abi, errorName: 'NotOperator' }),
        }),
      }),
    ],
    ['Tempo policy', policyRevert()],
  ])('accepts a typed %s revert', async (_, error) => {
    await expect(
      expectContractRevert(async () => {
        throw error
      }, message),
    ).resolves.toBeUndefined()
  })

  it.each(unrelatedErrors)('rejects unrelated $name', async (error) => {
    await expect(
      expectContractRevert(async () => {
        throw error
      }, message),
    ).rejects.toBe(error)
  })

  it('rejects a successful call', async () => {
    await expect(expectContractRevert(async () => undefined, message)).rejects.toThrow(message)
  })

  it('matches the expected decoded error through viem wrapping', async () => {
    const error = new BaseError('contract call failed', { cause: contractRevert() })
    await expect(
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        expected,
      ),
    ).resolves.toBeUndefined()
  })

  it('decodes raw revert data missing from the original contract ABI', async () => {
    const error = contractRevert('NotOperator', [])
    expect(error.data).toBeUndefined()
    await expect(
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        expected,
      ),
    ).resolves.toBeUndefined()
  })

  it('requires the expected error to decode under the supplied ABI', async () => {
    const error = contractRevert()
    await expect(
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        { abi: [], errorName: 'NotOperator' },
      ),
    ).rejects.toBe(error)
  })

  it.each([
    ['different error', contractRevert('Paused')],
    [
      'unknown selector',
      new ContractFunctionRevertedError({ abi, data: '0xdeadbeef', functionName: 'deposit' }),
    ],
    ['missing revert data', new ContractFunctionRevertedError({ abi, functionName: 'deposit' })],
    [
      'message only',
      new ContractFunctionRevertedError({ abi, functionName: 'deposit', message: 'NotOperator' }),
    ],
    ['generic execution', new ExecutionRevertedError({ message: 'NotOperator' })],
    ['mined receipt', receiptRevert('reverted')],
  ])('does not mistake %s for the expected reason', async (_, error) => {
    await expect(
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        expected,
      ),
    ).rejects.toBe(error)
  })

  it('rejects a known selector with missing encoded arguments', async () => {
    const data = encodeErrorResult({ abi, errorName: 'AmountTooLow', args: [1n] })
    const error = new ContractFunctionRevertedError({
      abi,
      data: data.slice(0, 10) as `0x${string}`,
      functionName: 'deposit',
    })
    await expect(
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        { abi, errorName: 'AmountTooLow' },
      ),
    ).rejects.toBe(error)
  })

  it.each([false, true])('decodes execution revert RPC data (nested=%s)', async (nested) => {
    const data = encodeErrorResult({ abi, errorName: 'NotOperator' })
    const error = new ExecutionRevertedError({
      cause: new RpcRequestError({
        body: { method: 'eth_call' },
        error: { code: 3, data: nested ? { data } : data, message: 'execution reverted' },
        url: 'https://rpc.example.test',
      }),
    })
    await expect(
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        expected,
      ),
    ).resolves.toBeUndefined()
  })

  it('does not accept transport data that happens to contain an expected selector', async () => {
    const error = Object.assign(
      new HttpRequestError({ url: 'https://rpc.example.test', status: 503 }),
      {
        data: encodeErrorResult({ abi, errorName: 'NotOperator' }),
      },
    )
    await expect(
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        expected,
      ),
    ).rejects.toBe(error)
  })

  it('matches a wrapped Tempo token policy error by its encoded data', async () => {
    const error = new BaseError('deposit failed', { cause: policyRevert() })
    await expect(
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        { abi: Abis.tip20, errorName: 'PolicyForbids' },
      ),
    ).resolves.toBeUndefined()
  })

  it('rejects a different decoded Tempo error', async () => {
    const decoded = ExecutionError.from(
      encodeErrorResult({ abi: Abis.tip20, errorName: 'InsufficientBalance' }),
    )
    if (decoded.errorName === 'unknown') throw new Error('fixture error did not decode')
    const error = new TempoExecutionError({
      cause: new ContractFunctionRevertedError({
        abi: Abis.tip20,
        data: decoded.data,
        functionName: 'deposit',
      }),
      error: decoded,
      hints: [],
    })
    await expect(
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        { abi: Abis.tip20, errorName: 'PolicyForbids' },
      ),
    ).rejects.toBe(error)
  })
})

describe('expectRevertedReceipt', () => {
  it('accepts a mined reverted receipt', async () => {
    await expect(
      expectRevertedReceipt(async () => receipt('reverted'), message),
    ).resolves.toBeUndefined()
  })

  it.each([
    ['preflight', contractRevert()],
    ['wrapped preflight', new BaseError('contract call failed', { cause: contractRevert() })],
    ['receipt error', receiptRevert('reverted')],
    ['Tempo policy', policyRevert()],
  ])('accepts a typed %s revert', async (_, error) => {
    await expect(
      expectRevertedReceipt(async () => {
        throw error
      }, message),
    ).resolves.toBeUndefined()
  })

  it.each(['success', 'pending', 'unknown'])('rejects a %s receipt', async (status) => {
    await expect(expectRevertedReceipt(async () => ({ status }), message)).rejects.toThrow(message)
  })

  it.each(unrelatedErrors)('does not accept unrelated $name', async (error) => {
    await expect(
      expectRevertedReceipt(async () => {
        throw error
      }, message),
    ).rejects.toBe(error)
  })

  it('verifies the receipt even when wrapped in a receipt-reverted error', async () => {
    const error = receiptRevert('success')
    await expect(
      expectRevertedReceipt(async () => {
        throw error
      }, message),
    ).rejects.toBe(error)
  })
})

describe('expectRevertedWrite', () => {
  it('accepts a mined reverted receipt without an expected reason', async () => {
    const context = contextWithReceipt(async () => receipt('reverted'))
    await expect(expectRevertedWrite(context, async () => hash, message)).resolves.toBeUndefined()
  })

  it('accepts the exact decoded error from submission', async () => {
    const context = contextWithReceipt(async () => {
      throw new Error('must not wait for a receipt')
    })
    const error = policyRevert()
    await expect(
      expectRevertedWrite(
        context,
        async () => {
          throw error
        },
        message,
        { abi: Abis.tip20, errorName: 'PolicyForbids' },
      ),
    ).resolves.toBeUndefined()
  })

  it('rejects an incorrect decoded submission error', async () => {
    const context = contextWithReceipt(async () => receipt('reverted'))
    const error = contractRevert('Paused')
    await expect(
      expectRevertedWrite(
        context,
        async () => {
          throw error
        },
        message,
        expected,
      ),
    ).rejects.toBe(error)
  })

  it('does not accept a bare reverted receipt as proof of an exact reason', async () => {
    const context = contextWithReceipt(async () => receipt('reverted'))
    await expect(expectRevertedWrite(context, async () => hash, message, expected)).rejects.toThrow(
      message,
    )
  })

  it.each(['success', 'pending'])('rejects a %s receipt', async (status) => {
    const context = contextWithReceipt(async () => ({ status }))
    await expect(expectRevertedWrite(context, async () => hash, message)).rejects.toThrow(message)
  })

  it.each(unrelatedErrors)('propagates submission $name', async (error) => {
    const context = contextWithReceipt(async () => receipt('reverted'))
    await expect(
      expectRevertedWrite(
        context,
        async () => {
          throw error
        },
        message,
      ),
    ).rejects.toBe(error)
  })

  it.each(unrelatedErrors)('propagates receipt-wait $name', async (error) => {
    const context = contextWithReceipt(async () => {
      throw error
    })
    await expect(expectRevertedWrite(context, async () => hash, message)).rejects.toBe(error)
  })
})

const policyError = { abi: Abis.tip20, errorName: 'PolicyForbids' }
const feeError = { abi: Abis.coreErrors, errorName: 'InsufficientFeeTokenBalance' }
const admissionErrors = [
  {
    label: 'fee admission',
    code: -32003,
    errorName: 'InsufficientFeeTokenBalance',
    expected: feeError,
  },
  {
    label: 'name-only policy admission',
    code: -32003,
    errorName: 'PolicyForbids',
    expected: policyError,
  },
  {
    label: 'name-only policy RPC error',
    code: 3,
    errorName: 'PolicyForbids',
    expected: policyError,
  },
  {
    label: 'admission carrying policy bytes',
    code: -32003,
    errorName: 'PolicyForbids',
    expected: policyError,
    data: encodeErrorResult({ abi: Abis.tip20, errorName: 'PolicyForbids' }),
  },
] as const

const exactAssertions = [
  {
    name: 'expectContractRevert',
    run: (error: unknown, options?: { abi: Abi; errorName: string }) =>
      expectContractRevert(
        async () => {
          throw error
        },
        message,
        options,
      ),
  },
  {
    name: 'expectRevertedWrite',
    run: (error: unknown, options?: { abi: Abi; errorName: string }) =>
      expectRevertedWrite(
        contextWithReceipt(async () => {
          throw new Error('receipt wait must not run')
        }),
        async () => {
          throw error
        },
        message,
        options,
      ),
  },
]

// The pinned native Zone returns this serialized inner RPC error instead of top-level data.
const zoneDenial =
  'ErrorObject { code: ServerError(3), message: "execution reverted: Current committee error: Unauthorized(Unauthorized)", data: Some(RawValue("0x82b42900")) }'
const zoneError = { abi: parseAbi(['error Unauthorized()']), errorName: 'Unauthorized' }

const assertions = [
  ...exactAssertions,
  {
    name: 'expectRevertedReceipt',
    run: (error: unknown) =>
      expectRevertedReceipt(async () => {
        throw error
      }, message),
  },
]

// Exercise viem's real write path: its revert class alone does not prove EVM execution.
describe.each(assertions)('$name viem write evidence', ({ run }) => {
  it.each([
    { code: -32603, message: 'internal error' },
    { code: 3, message: 'PolicyForbids(PolicyForbids)' },
    { code: 3, message: 'execution reverted' },
    { code: 3, message: 'execution reverted', data: '0x' },
    { code: 3, message: 'execution reverted', data: '0xabc' },
  ])('rejects RPC $code / $message without revert bytes ($data)', async (rpc) => {
    const error = await writeContractError(rpc)
    expect(error.walk((cause) => cause instanceof ContractFunctionRevertedError)).toBeInstanceOf(
      ContractFunctionRevertedError,
    )
    await expect(run(error)).rejects.toBe(error)
  })

  it.each([
    zoneDenial.replace('ServerError(3)', 'ServerError(-32603)'),
    zoneDenial.replace('0x82b42900', '0x'),
    zoneDenial.replace('0x82b42900', '0xabc'),
    zoneDenial.replace('Some(RawValue("0x82b42900"))', 'None'),
    zoneDenial.replace('execution reverted: ', ''),
    `RPC unavailable: ${zoneDenial}`,
    `${zoneDenial} trailing data`,
    'execution reverted: Unauthorized(Unauthorized) RawValue("0x82b42900")',
  ])('rejects an incomplete or non-execution Zone envelope: %s', async (message) => {
    const error = await writeContractError({ code: -32603, message })
    await expect(run(error)).rejects.toBe(error)
  })

  it('accepts original bytes inside the native Zone execution envelope', async () => {
    const error = await writeContractError({ code: -32603, message: zoneDenial })
    const reverted = error.walk((cause) => cause instanceof ContractFunctionRevertedError)
    expect(reverted).toMatchObject({ raw: undefined, reason: zoneDenial })
    await expect(run(error)).resolves.toBeUndefined()
  })

  it.each([3, -32603])('accepts original policy bytes through RPC %s', async (code) => {
    const error = await writeContractError({
      code,
      message: 'execution reverted',
      data: encodeErrorResult({ abi: Abis.tip20, errorName: 'PolicyForbids' }),
    })
    await expect(run(error)).resolves.toBeUndefined()
    await expect(run(await resolveTempoError(error))).resolves.toBeUndefined()
  })
})

// Use the real SDK resolver to distinguish message-derived selectors from original RPC bytes.
describe.each(assertions)('$name execution evidence', ({ run }) => {
  it.each(admissionErrors)('rejects $label resolved by the SDK', async (parameters) => {
    const cause = rpcError(parameters)
    const error = await resolveTempoError(cause)
    expect(error.cause).toBe(cause)
    expect(error.errorName).toBe(parameters.errorName)
    if (parameters.errorName === 'InsufficientFeeTokenBalance')
      expect(error.name).toBe('FeeInsufficientBalanceError')
    await expect(run(error)).rejects.toBe(error)
  })

  it('accepts a real RPC execution revert wrapped by the SDK', async () => {
    const cause = rpcError({
      code: 3,
      errorName: 'PolicyForbids',
      data: encodeErrorResult({ abi: Abis.tip20, errorName: 'PolicyForbids' }),
    })
    await expect(run(await resolveTempoError(cause))).resolves.toBeUndefined()
  })
})

describe.each(exactAssertions)('$name exact execution evidence', ({ run }) => {
  it('decodes the native Zone bytes rather than matching the message', async () => {
    const error = await writeContractError({
      code: -32603,
      message: zoneDenial.replaceAll('Unauthorized', 'NotOperator'),
    })
    await expect(run(error, zoneError)).resolves.toBeUndefined()
    await expect(run(error, expected)).rejects.toBe(error)
  })

  it.each(admissionErrors)(
    'rejects $label even when its synthesized name matches',
    async (parameters) => {
      const error = await resolveTempoError(rpcError(parameters))
      await expect(run(error, parameters.expected)).rejects.toBe(error)
    },
  )

  it('decodes original RPC bytes through the SDK wrapper', async () => {
    const error = await resolveTempoError(
      rpcError({
        code: 3,
        errorName: 'PolicyForbids',
        data: encodeErrorResult({ abi: Abis.tip20, errorName: 'PolicyForbids' }),
      }),
    )
    await expect(run(error, policyError)).resolves.toBeUndefined()
  })

  it('ignores a matching wrapper name when the original revert differs', async () => {
    const error = policyRevert(contractRevert('Paused'))
    await expect(run(error, policyError)).rejects.toBe(error)
  })
})

function contractRevert(
  errorName: 'NotOperator' | 'Paused' = 'NotOperator',
  decoderAbi: Abi = abi,
) {
  return new ContractFunctionRevertedError({
    abi: decoderAbi,
    data: encodeErrorResult({ abi, errorName }),
    functionName: 'deposit',
  })
}

function policyRevert(
  cause: BaseError = new ContractFunctionRevertedError({
    abi: Abis.tip20,
    data: encodeErrorResult({ abi: Abis.tip20, errorName: 'PolicyForbids' }),
    functionName: 'deposit',
  }),
) {
  const decoded = ExecutionError.from(
    encodeErrorResult({ abi: Abis.tip20, errorName: 'PolicyForbids' }),
  )
  if (decoded.errorName !== 'PolicyForbids') throw new Error('fixture error did not decode')
  return new Actions.token.TokenPolicyForbidsError({
    cause,
    error: decoded,
    hints: [],
    token: address,
  })
}

function contextWithReceipt(action: () => Promise<{ status: string }>) {
  return { l1Public: { waitForTransactionReceipt: action } } as unknown as E2eContext
}

function receipt(status: TransactionReceipt['status']): TransactionReceipt {
  return {
    blockHash: hash,
    blockNumber: 1n,
    contractAddress: null,
    cumulativeGasUsed: 1n,
    effectiveGasPrice: 1n,
    from: address,
    gasUsed: 1n,
    logs: [],
    logsBloom: `0x${'00'.repeat(256)}`,
    status,
    to: address,
    transactionHash: hash,
    transactionIndex: 0,
    type: 'eip1559',
  }
}

function receiptRevert(status: TransactionReceipt['status']) {
  // The pinned viem version keeps this class private, so exercise its public BaseError shape.
  return Object.assign(
    new BaseError('transaction reverted', { name: 'TransactionReceiptRevertedError' }),
    {
      receipt: receipt(status),
    },
  )
}

function rpcError(parameters: { code: number; errorName: string; data?: `0x${string}` }) {
  return new RpcRequestError({
    body: { method: 'eth_sendRawTransaction' },
    error: {
      code: parameters.code,
      data: parameters.data,
      message: `${parameters.errorName}(${parameters.errorName})`,
    },
    url: 'https://rpc.example.test',
  })
}

async function resolveTempoError(cause: BaseError) {
  let requests = 0
  const client = createClient({
    transport: custom({
      request: async () => {
        requests += 1
        throw new Error('resolver must not call RPC')
      },
    }),
  })
  try {
    // The SDK action's write boundary invokes viem's real resolver without submitting a transaction.
    await Actions.fee.setUserToken.inner(
      async () => {
        throw cause
      },
      client,
      {
        token: '0x20c0000000000000000000000000000000000001',
      } as never,
    )
  } catch (error) {
    expect(requests).toBe(0)
    if (error instanceof TempoExecutionError) return error
    throw error
  }
  throw new Error('SDK action unexpectedly succeeded')
}

async function writeContractError(error: { code: number; message: string; data?: string }) {
  const requests: string[] = []
  const client = createWalletClient({
    account: address,
    chain: mainnet,
    transport: custom(
      {
        request: async (body) => {
          requests.push(body.method)
          if (body.method === 'eth_chainId') return '0x1'
          throw new RpcRequestError({ body, error, url: 'https://rpc.example.test' })
        },
      },
      { retryCount: 0 },
    ),
  })
  try {
    await client.writeContract({
      address,
      abi: parseAbi(['function transfer(address to, uint256 amount) returns (bool)']),
      functionName: 'transfer',
      args: [address, 1n],
    })
  } catch (error) {
    expect(requests).toEqual(['eth_chainId', 'eth_sendTransaction'])
    if (error instanceof BaseError) return error
    throw error
  }
  throw new Error('write unexpectedly succeeded')
}
