import { describe, expect, test } from 'vitest'
import { encodeAbiParameters, encodeEventTopics, parseAbiItem, type TransactionReceipt } from 'viem'

import { assertCreationReceipt } from './creation.js'

const address = `0x${'ab'.repeat(20)}` as const
const other = `0x${'cd'.repeat(20)}` as const
const transaction = `0x${'12'.repeat(32)}` as const
const event = parseAbiItem('event Created(address indexed child, uint256 nonce)')
const factory = { address: other, event, argument: 'child' }
const log = {
  address: other,
  topics: encodeEventTopics({ abi: [event], eventName: 'Created', args: { child: address } }),
  data: encodeAbiParameters([{ type: 'uint256' }], [1n]),
  removed: false,
} as TransactionReceipt['logs'][number]
const receipt = {
  status: 'success' as const,
  transactionHash: transaction,
  contractAddress: null,
  logs: [log],
}

describe('assertCreationReceipt', () => {
  test('accepts a successful direct creation or the expected factory event', () => {
    expect(() =>
      assertCreationReceipt({
        address,
        transaction,
        receipt: { ...receipt, contractAddress: address, logs: [] },
      }),
    ).not.toThrow()
    expect(() => assertCreationReceipt({ address, transaction, receipt, factory })).not.toThrow()
  })

  test('rejects reverted or unrelated transaction receipts even with a matching event', () => {
    for (const changed of [
      { ...receipt, status: 'reverted' as const },
      { ...receipt, transactionHash: `0x${'34'.repeat(32)}` as const },
    ])
      expect(() =>
        assertCreationReceipt({ address, transaction, receipt: changed, factory }),
      ).toThrow('not the successful recorded transaction')
  })

  test('never treats an ordinary call or another direct creation as proof', () => {
    for (const contractAddress of [null, other])
      expect(() =>
        assertCreationReceipt({ address, transaction, receipt: { ...receipt, contractAddress } }),
      ).toThrow('does not prove creation')
  })

  test('requires the configured factory, event, output and complete log data', () => {
    for (const changed of [
      { ...log, address },
      { ...log, removed: true },
      {
        ...log,
        topics: encodeEventTopics({ abi: [event], eventName: 'Created', args: { child: other } }),
      },
      { ...log, topics: [`0x${'ff'.repeat(32)}`] },
      { ...log, data: '0x' },
    ])
      expect(() =>
        assertCreationReceipt({
          address,
          transaction,
          receipt: { ...receipt, logs: [changed as TransactionReceipt['logs'][number]] },
          factory,
        }),
      ).toThrow('does not prove creation')
    expect(() =>
      assertCreationReceipt({
        address,
        transaction,
        receipt,
        factory: { ...factory, argument: 'missing' },
      }),
    ).toThrow('does not prove creation')
  })

  test('does not let a direct address or another log bypass required factory evidence', () => {
    expect(() =>
      assertCreationReceipt({
        address,
        transaction,
        receipt: { ...receipt, contractAddress: address, logs: [] },
        factory,
      }),
    ).toThrow('does not prove creation')
    expect(() =>
      assertCreationReceipt({
        address,
        transaction,
        receipt: { ...receipt, logs: [{ ...log, address }, log] },
        factory,
      }),
    ).not.toThrow()
  })
})
