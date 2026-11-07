import { describe, expect, test } from 'vitest'
import {
  createPublicClient,
  custom,
  encodeAbiParameters,
  encodeEventTopics,
  parseAbiItem,
  type TransactionReceipt,
} from 'viem'

import { assertCreationReceipt, assertDirectCreationTransaction } from './creation.js'

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

describe('assertDirectCreationTransaction', () => {
  const creationBytecode = '0x6001600055' as const
  const constructorArgs = encodeAbiParameters([{ type: 'address' }], [other])
  const input = `${creationBytecode}${constructorArgs.slice(2)}` as const
  const minedTransaction = { hash: transaction, from: other, to: null, input }
  const options = {
    address,
    transaction,
    deployer: other,
    creationBytecode,
    constructorArgs,
    minedTransaction,
  }

  test('accepts canonical creation bytes and arguments, case-insensitively', () => {
    expect(() => assertDirectCreationTransaction(options)).not.toThrow()
    expect(() =>
      assertDirectCreationTransaction({
        ...options,
        minedTransaction: { ...minedTransaction, input: `0x${input.slice(2).toUpperCase()}` },
      }),
    ).not.toThrow()
  })

  test('accepts a single Tempo creation through the actual generic viem RPC formatter', async () => {
    // Pinned viem 2.57.14 preserves raw Tempo calls and identifies them through typeHex.
    const client = createPublicClient({
      transport: custom({
        request: async () => ({
          hash: transaction,
          from: other,
          type: '0x76',
          calls: [{ input }],
        }),
      }),
    })
    const minedTransaction = await client.getTransaction({ hash: transaction })
    expect(minedTransaction).toMatchObject({ typeHex: '0x76', to: null, calls: [{ input }] })
    expect(() => assertDirectCreationTransaction({ ...options, minedTransaction })).not.toThrow()
    expect(() =>
      assertDirectCreationTransaction({
        ...options,
        minedTransaction: {
          hash: transaction,
          from: other,
          type: 'tempo',
          calls: [{ data: input }],
        },
      }),
    ).not.toThrow()
  })

  test('rejects Tempo batches, ordinary calls, missing calls and conflicting input', () => {
    const tempo = { hash: transaction, from: other, typeHex: '0x76' as const }
    for (const changed of [
      { ...tempo, input },
      { ...tempo, calls: [] },
      { ...tempo, calls: [{ input }, { input }] },
      { ...tempo, calls: [{ to: address, input }] },
      { ...tempo, calls: [{ input: '0x60006000f3' as const }] },
      { ...tempo, calls: [{ input, data: '0x00' as const }] },
      { ...tempo, input: '0x00' as const, calls: [{ input }] },
      { ...tempo, typeHex: '0x2' as const, to: null, input, calls: [{ input }] },
    ])
      expect(() =>
        assertDirectCreationTransaction({ ...options, minedTransaction: changed }),
      ).toThrow()
  })

  test('rejects a different transaction, deployer, or ordinary call envelope', () => {
    for (const changed of [
      { ...minedTransaction, hash: `0x${'34'.repeat(32)}` as const },
      { ...minedTransaction, from: address },
      { ...minedTransaction, to: address },
    ])
      expect(() =>
        assertDirectCreationTransaction({ ...options, minedTransaction: changed }),
      ).toThrow('expected direct creation')
  })

  test('rejects custom initcode, incorrect arguments, missing arguments and appended data', () => {
    for (const input of [
      '0x60006000f3',
      creationBytecode,
      `${creationBytecode}${encodeAbiParameters([{ type: 'address' }], [address]).slice(2)}`,
      `${minedTransaction.input}00`,
    ] as const)
      expect(() =>
        assertDirectCreationTransaction({
          ...options,
          minedTransaction: { ...minedTransaction, input },
        }),
      ).toThrow('creation input')
  })

  test('fails closed on empty, malformed, odd-length or unlinked compiler bytes', () => {
    for (const creationBytecode of ['0x', '0x0', '0x__$library$__', '0xzz'] as const)
      expect(() =>
        assertDirectCreationTransaction({
          ...options,
          creationBytecode,
          constructorArgs: '0x',
          minedTransaction: { ...minedTransaction, input: creationBytecode },
        }),
      ).toThrow('creation input')
  })
})
