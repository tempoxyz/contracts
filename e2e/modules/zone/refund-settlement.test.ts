import { describe, expect, it } from 'vitest'
import {
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionData,
  encodePacked,
  getAbiItem,
  keccak256,
  zeroAddress,
  zeroHash,
  type Abi,
  type AbiEvent,
  type AbiParameterToPrimitiveType,
  type Address,
  type Hex,
  type Log,
} from 'viem'
import { Abis, Addresses } from 'viem/tempo'
import { recipientRefundAmount, recipientRefundBatch } from './refund-settlement.js'
import { zoneDepositAbi } from './delivery.js'

// These are ABI evidence fixtures, not a simulated chain or a claim of live settlement.
const portal: Address = '0x5ad0000000000000000000000000000000000001'
const token: Address = '0x20c0000000000000000000000000000000000001'
const sender: Address = '0x0000000000000000000000000000000000000002'
const recipient: Address = '0x0000000000000000000000000000000000000003'
const options = { depositHash: hash(1), token, sender, recipient, netAmount: 100n }
const process = getAbiItem({ abi: Abis.zonePortal, name: 'processWithdrawals' })
const parameter = { ...process.inputs[0], type: 'tuple' } as const
const withdrawal = {
  token,
  senderTag: keccak256(encodePacked(['address', 'bytes32'], [zeroAddress, zeroHash])),
  to: recipient,
  amount: 100n,
  memo: zeroHash,
  gasLimit: 0n,
  fallbackNonce: 0n,
  callbackData: '0x',
  encryptedSender: '0x',
} as const
const suffix = queueHash([withdrawal])
const root = queueHash([withdrawal, withdrawal])

describe('recipientRefundBatch', () => {
  it('identifies the exact deposit among identical bounces in one block', () => {
    const batch = recipientRefundBatch(zoneLogs(), options)
    expect(batch.index).toBe(1)
    expect(batch.finalized.args.withdrawalQueueHash).toBe(root)
  })

  it('correlates the legacy encrypted-prefixed failure through the same proof chain', () => {
    const logs = zoneLogs()
    logs[3] = log(
      zoneDepositAbi,
      'EncryptedDepositFailed',
      {
        depositHash: options.depositHash,
        sender,
        token,
        amount: options.netAmount,
      },
      logs[3],
    )
    const batch = recipientRefundBatch(logs, options)
    expect(batch.index).toBe(1)
    expect(recipientRefundAmount(batch, evidence())).toBe(80n)
    expect(() => recipientRefundBatch(logs, { ...options, depositHash: hash(99) })).toThrow(
      'exactly one',
    )
  })

  it('accepts a hash-correlated rejection only with the same adjacent bounce evidence', () => {
    const logs = zoneLogs()
    logs[3] = log(
      Abis.zoneInbox,
      'DepositRejected',
      {
        ...options,
        amount: options.netAmount,
        depositType: 0,
        tempoRefundRecipient: recipient,
      },
      { address: Addresses.zoneInbox, logIndex: 3 },
    )
    expect(recipientRefundBatch(logs, options).index).toBe(1)
  })

  it.each(['sender', 'token', 'recipient', 'netAmount'] as const)(
    'rejects a mismatch in %s',
    (field) => {
      expect(() =>
        recipientRefundBatch(zoneLogs(), {
          ...options,
          [field]: field === 'netAmount' ? 99n : zeroAddress,
        }),
      ).toThrow()
    },
  )

  it('rejects another deposit hash instead of using queue or balance progress', () => {
    expect(() => recipientRefundBatch(zoneLogs(), { ...options, depositHash: hash(99) })).toThrow(
      'exactly one deposit-specific',
    )
  })

  it('rejects nonadjacent, foreign-emitter, duplicated, or removed failure evidence', () => {
    const logs = zoneLogs()
    expect(() =>
      recipientRefundBatch(
        logs.map((entry, i) => (i === 3 ? { ...entry, logIndex: 20 } : entry)),
        options,
      ),
    ).toThrow('adjacent')
    expect(() =>
      recipientRefundBatch(
        logs.map((entry, i) => (i === 3 ? { ...entry, address: portal } : entry)),
        options,
      ),
    ).toThrow('exactly one')
    expect(() => recipientRefundBatch([...logs, logs[3]!], options)).toThrow('exactly one')
    expect(() =>
      recipientRefundBatch(
        logs.map((entry, i) => (i === 0 ? { ...entry, removed: true } : entry)),
        options,
      ),
    ).toThrow('canonical logs')
  })

  it('requires a single finalization after the withdrawals', () => {
    const logs = zoneLogs()
    expect(() => recipientRefundBatch(logs.slice(0, -1), options)).toThrow('exactly one finalized')
    expect(() => recipientRefundBatch([...logs, { ...logs[4]!, logIndex: 6 }], options)).toThrow(
      'exactly one finalized',
    )
  })
})

describe('recipientRefundAmount', () => {
  it('returns the exact ordinal refund using its actual receipt fee', () => {
    expect(recipientRefundAmount(recipientRefundBatch(zoneLogs(), options), evidence())).toBe(80n)
  })

  it('authenticates split calldata against the remaining hash and carries the ordinal', () => {
    const first = execution([withdrawal], suffix, [90n], 31n)
    const second = execution([withdrawal], zeroHash, [80n], 32n)
    const batch = recipientRefundBatch(zoneLogs(), options)
    expect(
      recipientRefundAmount(batch, { ...evidence(), executions: [first], queueHead: 7n }),
    ).toBeUndefined()
    expect(recipientRefundAmount(batch, { ...evidence(), executions: [second, first] })).toBe(80n)
  })

  it('does not confuse an earlier identical batch with the target batch', () => {
    const prior = execution([withdrawal, withdrawal], zeroHash, [99n, 98n], 29n)
    expect(
      recipientRefundAmount(recipientRefundBatch(zoneLogs(), options), {
        ...evidence(),
        initialQueueHead: 6n,
        executions: [prior, ...evidence().executions],
      }),
    ).toBe(80n)
  })

  it('does not return before full batch evidence rules out a missing identical withdrawal', () => {
    // The target looks like ordinal zero if the preceding identical withdrawal is redacted.
    const batch = recipientRefundBatch(zoneLogs().slice(2), options)
    const partial = execution([withdrawal], suffix, [90n], 31n)
    expect(
      recipientRefundAmount(batch, { ...evidence(), executions: [partial], queueHead: 7n }),
    ).toBeUndefined()
    expect(() => recipientRefundAmount(batch, evidence())).toThrow('incomplete or redacted')
  })

  it('does not count a pending refund as delivery', () => {
    const data = evidence()
    const completed = data.executions[0]!
    const pending = log(
      Abis.zonePortal,
      'DepositBounceBackPending',
      {
        tempoRefundRecipient: recipient,
        token,
        amount: 80n,
        bouncebackFee: 20n,
      },
      completed.receipt.logs[1],
    )
    expect(() =>
      recipientRefundAmount(recipientRefundBatch(zoneLogs(), options), {
        ...data,
        executions: [
          {
            ...completed,
            receipt: {
              ...completed.receipt,
              logs: [completed.receipt.logs[0]!, pending],
            },
          },
        ],
      }),
    ).toThrow('pending, not delivered')
  })

  it('rejects changed calldata, a wrong batch root, and wrong receipt fees', () => {
    const data = evidence()
    const batch = recipientRefundBatch(zoneLogs(), options)
    const changed = execution(
      [{ ...withdrawal, amount: 99n }, withdrawal],
      zeroHash,
      [90n, 80n],
      31n,
    )
    expect(() => recipientRefundAmount(batch, { ...data, executions: [changed] })).toThrow(
      'authenticate the expected queue suffix',
    )
    expect(() => recipientRefundAmount(batch, { ...data, logs: [submission(hash(99))] })).toThrow(
      'does not authenticate',
    )
    const completed = data.executions[0]!
    const badFee = log(
      Abis.zonePortal,
      'DepositBounceBack',
      {
        tempoRefundRecipient: recipient,
        token,
        amount: 80n,
        bouncebackFee: 19n,
      },
      completed.receipt.logs[1],
    )
    expect(() =>
      recipientRefundAmount(batch, {
        ...data,
        executions: [
          {
            ...completed,
            receipt: {
              ...completed.receipt,
              logs: [completed.receipt.logs[0]!, badFee],
            },
          },
        ],
      }),
    ).toThrow('amount and actual fee')
  })

  it('rejects missing or duplicate processing evidence and reverts', () => {
    const data = evidence()
    const batch = recipientRefundBatch(zoneLogs(), options)
    expect(() => recipientRefundAmount(batch, { ...data, executions: [] })).toThrow('queue replay')
    expect(() =>
      recipientRefundAmount(batch, {
        ...data,
        executions: [...data.executions, ...data.executions],
      }),
    ).toThrow('Duplicate')
    expect(() =>
      recipientRefundAmount(batch, {
        ...data,
        executions: data.executions.map((entry) => ({
          ...entry,
          receipt: { ...entry.receipt, status: 'reverted' as const },
        })),
      }),
    ).toThrow('reverted')
  })

  it('rejects wrapped or multicall transactions rather than guessing internal call order', () => {
    const data = evidence()
    const batch = recipientRefundBatch(zoneLogs(), options)
    expect(() =>
      recipientRefundAmount(batch, {
        ...data,
        executions: data.executions.map((entry) => ({
          ...entry,
          transaction: { ...entry.transaction, to: sender },
        })),
      }),
    ).toThrow('direct, single-call')
    expect(() =>
      recipientRefundAmount(batch, {
        ...data,
        executions: data.executions.map((entry) => ({
          ...entry,
          transaction: {
            ...entry.transaction,
            calls: [
              { to: portal, data: entry.transaction.input },
              { to: portal, data: entry.transaction.input },
            ],
          },
        })),
      }),
    ).toThrow('direct, single-call')
  })

  it('accepts a single-call Tempo envelope and rejects incomplete outcome logs', () => {
    const data = evidence()
    const batch = recipientRefundBatch(zoneLogs(), options)
    expect(
      recipientRefundAmount(batch, {
        ...data,
        executions: data.executions.map((entry) => ({
          ...entry,
          transaction: {
            hash: entry.transaction.hash,
            calls: [{ to: portal, data: entry.transaction.input }],
          },
        })),
      }),
    ).toBe(80n)
    expect(() =>
      recipientRefundAmount(batch, {
        ...data,
        executions: data.executions.map((entry) => ({
          ...entry,
          receipt: { ...entry.receipt, logs: entry.receipt.logs.slice(0, 1) },
        })),
      }),
    ).toThrow('ambiguous or incomplete')
  })

  it('preserves the ordinal with a normal authenticated withdrawal in the same batch', () => {
    const transactionHash = hash(103)
    const regular = {
      ...withdrawal,
      senderTag: keccak256(
        encodePacked(['address', 'bytes32', 'uint64'], [sender, transactionHash, 9n]),
      ),
      fallbackNonce: 9n,
    }
    const fullRoot = queueHash([withdrawal, withdrawal, regular])
    const logs = zoneLogs().slice(0, 4)
    logs.push(
      log(
        Abis.zoneOutbox,
        'WithdrawalRequested',
        {
          withdrawalIndex: 92n,
          sender,
          token,
          to: recipient,
          amount: 100n,
          fee: 0n,
          memo: zeroHash,
          gasLimit: 0n,
          fallbackNonce: 9n,
          data: '0x',
          revealTo: '0x',
        },
        { address: Addresses.zoneOutbox, logIndex: 4, transactionHash, transactionIndex: 1 },
      ),
    )
    logs.push(
      log(
        Abis.zoneOutbox,
        'BatchFinalized',
        {
          withdrawalQueueHash: fullRoot,
          withdrawalBatchIndex: 20n,
        },
        {
          address: Addresses.zoneOutbox,
          logIndex: 5,
          transactionHash: hash(104),
          transactionIndex: 2,
        },
      ),
    )
    const completed = execution([withdrawal, withdrawal, regular], zeroHash, [90n, 80n], 31n)
    completed.receipt.logs.push(
      log(
        Abis.zonePortal,
        'WithdrawalProcessed',
        {
          to: recipient,
          senderTag: regular.senderTag,
          token,
          amount: 100n,
          callbackSuccess: true,
        },
        { ...completed.receipt.logs[1], logIndex: 2 },
      ),
    )
    expect(
      recipientRefundAmount(recipientRefundBatch(logs, options), {
        ...evidence(),
        logs: [submission(fullRoot)],
        executions: [completed],
      }),
    ).toBe(80n)
  })

  it('rejects a nonce-suffixed sender tag for a canonical zero-sender bounce', () => {
    const wrong = {
      ...withdrawal,
      senderTag: keccak256(
        encodePacked(['address', 'bytes32', 'uint64'], [zeroAddress, zeroHash, 0n]),
      ),
    }
    const wrongRoot = queueHash([wrong, wrong])
    const logs = zoneLogs()
    logs[4] = log(
      Abis.zoneOutbox,
      'BatchFinalized',
      {
        withdrawalQueueHash: wrongRoot,
        withdrawalBatchIndex: 20n,
      },
      logs[4],
    )
    expect(() =>
      recipientRefundAmount(recipientRefundBatch(logs, options), {
        ...evidence(),
        logs: [submission(wrongRoot)],
        executions: [execution([wrong, wrong], zeroHash, [90n, 80n], 31n)],
      }),
    ).toThrow('Authenticated withdrawal order')
  })

  it('rejects a different refund recipient or a foreign Portal emitter', () => {
    const data = evidence()
    const completed = data.executions[0]!
    const otherRecipient = log(
      Abis.zonePortal,
      'DepositBounceBack',
      {
        tempoRefundRecipient: sender,
        token,
        amount: 80n,
        bouncebackFee: 20n,
      },
      completed.receipt.logs[1],
    )
    const batch = recipientRefundBatch(zoneLogs(), options)
    expect(() =>
      recipientRefundAmount(batch, {
        ...data,
        executions: [
          {
            ...completed,
            receipt: {
              ...completed.receipt,
              logs: [completed.receipt.logs[0]!, otherRecipient],
            },
          },
        ],
      }),
    ).toThrow('amount and actual fee')
    expect(() =>
      recipientRefundAmount(batch, {
        ...data,
        executions: [
          {
            ...completed,
            receipt: {
              ...completed.receipt,
              logs: completed.receipt.logs.map((entry) => ({ ...entry, address: sender })),
            },
          },
        ],
      }),
    ).toThrow('ambiguous or incomplete')
  })

  it('waits for authenticated submission and rejects processing before it', () => {
    const batch = recipientRefundBatch(zoneLogs(), options)
    expect(recipientRefundAmount(batch, { ...evidence(), logs: [] })).toBeUndefined()
    expect(() =>
      recipientRefundAmount(batch, {
        ...evidence(),
        executions: [execution([withdrawal, withdrawal], zeroHash, [90n, 80n], 29n)],
      }),
    ).toThrow('precedes')
  })
})

type Withdrawal = AbiParameterToPrimitiveType<typeof parameter>

function hash(byte: number): Hex {
  return `0x${byte.toString(16).padStart(2, '0').repeat(32)}`
}

function queueHash(withdrawals: readonly Withdrawal[]) {
  return [...withdrawals]
    .reverse()
    .reduce<Hex>(
      (tail, entry) =>
        keccak256(encodeAbiParameters([parameter, { type: 'bytes32' }], [entry, tail])),
      zeroHash,
    )
}

function log(
  abi: Abi,
  eventName: string,
  args: Record<string, unknown>,
  overrides: Partial<Log<bigint, number, false>> = {},
): Log<bigint, number, false> {
  const event = [...abi]
    .reverse()
    .find((item): item is AbiEvent => item.type === 'event' && item.name === eventName)!
  return {
    address: portal,
    blockHash: hash(100),
    blockNumber: 20n,
    transactionHash: hash(101),
    transactionIndex: 0,
    logIndex: 0,
    removed: false,
    ...overrides,
    data: encodeAbiParameters(
      event.inputs.filter((input) => !input.indexed),
      event.inputs.filter((input) => !input.indexed).map((input) => args[input.name!]),
    ),
    topics: encodeEventTopics({ abi: [event], eventName, args: args as never }) as [Hex, ...Hex[]],
  }
}

function zoneLogs() {
  const logs = [hash(2), options.depositHash].flatMap((depositHash, index) => [
    log(
      Abis.zoneOutbox,
      'WithdrawalRequested',
      {
        withdrawalIndex: 90n + BigInt(index),
        sender: zeroAddress,
        token,
        to: recipient,
        amount: 100n,
        fee: 0n,
        memo: zeroHash,
        gasLimit: 0n,
        fallbackNonce: 0n,
        data: '0x',
        revealTo: '0x',
      },
      { address: Addresses.zoneOutbox, logIndex: index * 2 },
    ),
    log(
      Abis.zoneInbox,
      'DepositFailed',
      { depositHash, sender, token, amount: 100n },
      { address: Addresses.zoneInbox, logIndex: index * 2 + 1 },
    ),
  ])
  logs.push(
    log(
      Abis.zoneOutbox,
      'BatchFinalized',
      {
        withdrawalQueueHash: root,
        withdrawalBatchIndex: 20n,
      },
      {
        address: Addresses.zoneOutbox,
        logIndex: 4,
        transactionHash: hash(102),
        transactionIndex: 1,
      },
    ),
  )
  return logs
}

function submission(withdrawalQueueHash: Hex = root) {
  return log(
    Abis.zonePortal,
    'BatchSubmitted',
    {
      withdrawalBatchIndex: 20n,
      withdrawalQueueIndex: 7n,
      nextProcessedDepositQueueHash: hash(1),
      nextBlockHash: hash(100),
      withdrawalQueueHash,
      lastProcessedDepositNumber: 3n,
      lastProcessedEnabledTokenCount: 1n,
    },
    { blockHash: hash(30), blockNumber: 30n, transactionHash: hash(130) },
  )
}

function execution(
  withdrawals: readonly Withdrawal[],
  remainingQueue: Hex,
  amounts: readonly bigint[],
  blockNumber: bigint,
) {
  const transactionHash = hash(Number(blockNumber) + 100)
  const blockHash = hash(Number(blockNumber))
  return {
    transaction: {
      hash: transactionHash,
      to: portal,
      input: encodeFunctionData({
        abi: Abis.zonePortal,
        functionName: 'processWithdrawals',
        args: [withdrawals, remainingQueue],
      }),
    },
    receipt: {
      transactionHash,
      blockHash,
      blockNumber,
      transactionIndex: 0,
      status: 'success' as const,
      logs: amounts.map((amount, i) =>
        log(
          Abis.zonePortal,
          'DepositBounceBack',
          {
            tempoRefundRecipient: recipient,
            token,
            amount,
            bouncebackFee: 100n - amount,
          },
          { blockHash, blockNumber, transactionHash, logIndex: i },
        ),
      ),
    },
  }
}

function evidence() {
  return {
    portal,
    initialQueueHead: 7n,
    queueHead: 8n,
    logs: [submission()],
    executions: [execution([withdrawal, withdrawal], zeroHash, [90n, 80n], 31n)],
  }
}
