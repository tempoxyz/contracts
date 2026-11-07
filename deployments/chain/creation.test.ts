import { readFileSync } from 'node:fs'
import { describe, expect, test } from 'vitest'
import {
  createPublicClient,
  custom,
  encodeAbiParameters,
  encodeEventTopics,
  parseAbiItem,
  type TransactionReceipt,
  type Hex,
} from 'viem'

import {
  assertCreationReceipt,
  assertDirectCreationTransaction,
  assertVerifiedCreationTransaction,
} from './creation.js'

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

describe('assertVerifiedCreationTransaction', () => {
  // Captured terminal CBOR from Tempo verifier testnet match 29712, whose cborAuxdata is null.
  const metadata =
    'a26469706673582212204c899a1ea253fbc50fb0b72b2713033892383111d799842d3d02bb6dc73c1f8c64736f6c63430008240033'
  const creationBytecode = `0x6001600055fe${metadata}` as const
  const constructorArgs = encodeAbiParameters([{ type: 'address' }], [other])
  const original = creationBytecode.replace(
    '4c899a1ea253fbc50fb0b72b2713033892383111d799842d3d02bb6dc73c1f8c',
    '11'.repeat(32),
  ) as Hex
  const input = `${original}${constructorArgs.slice(2)}` as Hex
  const compiler = { name: 'solc', language: 'Solidity', version: '0.8.36+commit.8a079791' }
  const range = { offset: 6, value: `0x${metadata}` }
  const options = {
    address,
    transaction,
    deployer: other,
    creationBytecode,
    constructorArgs,
    compiler,
    minedTransaction: { hash: transaction, from: other, to: null, input },
  }

  test('accepts only the metadata digest difference and keeps canonical proof exact', () => {
    for (const cborAuxdata of [undefined, null, { '1': range }])
      expect(() => assertVerifiedCreationTransaction({ ...options, cborAuxdata })).not.toThrow()
    expect(() => assertDirectCreationTransaction(options)).toThrow('creation input')
    expect(() =>
      assertVerifiedCreationTransaction({
        ...options,
        minedTransaction: {
          ...options.minedTransaction,
          input: `0x${input.slice(2).toUpperCase()}`,
        },
      }),
    ).not.toThrow()
  })

  test('accepts both adjacent metadata digests in the compiled ZoneRouterFactory', ({ skip }) => {
    let artifact: { bytecode: { object: Hex }; metadata: { compiler: { version: string } } }
    try {
      artifact = JSON.parse(
        readFileSync(
          new URL(
            '../../zone-router/out/ZoneRouterFactory.sol/ZoneRouterFactory.json',
            import.meta.url,
          ),
          'utf8',
        ),
      )
    } catch (error) {
      // Full verification builds this artifact; TypeScript-only checkouts may not have compiled Solidity.
      if (error instanceof Error && 'code' in error && error.code === 'ENOENT')
        skip('Run forge build src in zone-router for the compiled factory regression')
      throw error
    }
    const creationBytecode = artifact.bytecode.object
    const trailers = [
      ...creationBytecode.matchAll(/a2646970667358221220[0-9a-f]{64}64736f6c6343[0-9a-f]{6}0033/gi),
    ]
    expect(trailers).toHaveLength(2)
    expect(trailers[0]!.index + trailers[0]![0].length).toBe(trailers[1]!.index)
    expect(trailers[1]!.index + trailers[1]![0].length).toBe(creationBytecode.length)
    const cborAuxdata = Object.fromEntries(
      trailers.map((trailer, index) => [
        String(index + 1),
        {
          offset: (trailer.index - 2) / 2,
          value: `0x${trailer[0]}`,
        },
      ]),
    )
    const changed = creationBytecode.replace(/(?<=a2646970667358221220)[0-9a-f]{64}/gi, (digest) =>
      digest === '11'.repeat(32) ? '22'.repeat(32) : '11'.repeat(32),
    ) as Hex
    const fixture = {
      ...options,
      creationBytecode,
      constructorArgs: '0x' as const,
      compiler: { ...compiler, version: artifact.metadata.compiler.version },
      minedTransaction: { ...options.minedTransaction, input: changed },
    }
    for (const ranges of [undefined, null, cborAuxdata])
      expect(() =>
        assertVerifiedCreationTransaction({ ...fixture, cborAuxdata: ranges }),
      ).not.toThrow()
    expect(() => assertDirectCreationTransaction(fixture)).toThrow('creation input')
    expect(() =>
      assertDirectCreationTransaction({
        ...fixture,
        minedTransaction: { ...fixture.minedTransaction, input: creationBytecode },
      }),
    ).not.toThrow()
  })

  describe('adjacent factory metadata', () => {
    const bytecode = `${creationBytecode}${metadata}` as Hex
    const input =
      `${original}${metadata.replace('4c899a', '4c899b')}${constructorArgs.slice(2)}` as Hex
    const second = { ...range, offset: range.offset + metadata.length / 2 }
    const cborAuxdata = { '1': range, '2': second }
    const fixture = {
      ...options,
      creationBytecode: bytecode,
      cborAuxdata,
      minedTransaction: { ...options.minedTransaction, input },
    }

    test('derives every digest with absent, null or independently ordered verifier ranges', () => {
      for (const cborAuxdata of [undefined, null, fixture.cborAuxdata, { '1': second, '2': range }])
        expect(() => assertVerifiedCreationTransaction({ ...fixture, cborAuxdata })).not.toThrow()
      // Each trailer can differ independently; fresh checkout proof still permits neither difference.
      for (const input of [
        `${original}${metadata}${constructorArgs.slice(2)}`,
        `${creationBytecode}${metadata.replace('4c899a', '4c899b')}${constructorArgs.slice(2)}`,
      ] as const) {
        expect(() =>
          assertVerifiedCreationTransaction({
            ...fixture,
            minedTransaction: { ...fixture.minedTransaction, input },
          }),
        ).not.toThrow()
        expect(() =>
          assertDirectCreationTransaction({
            ...fixture,
            minedTransaction: { ...fixture.minedTransaction, input },
          }),
        ).toThrow('creation input')
      }
    })

    test('rejects missing, duplicate, overlapping, outside or injected auxiliary ranges', () => {
      for (const cborAuxdata of [
        { '1': range },
        { '1': range, '2': range },
        { '1': range, '2': { ...second, offset: second.offset - 1 } },
        { '1': { ...range, value: `0x${metadata}${metadata}` }, '2': second },
        { '1': range, '2': { ...second, value: `${second.value}${constructorArgs.slice(2)}` } },
        { '1': range, '2': { offset: bytecode.length / 2 - 1, value: constructorArgs } },
        { '1': range, '2': { offset: 0, value: '0x6001600055' } },
        { ...fixture.cborAuxdata, '3': { offset: 0, value: '0x6001600055' } },
      ])
        expect(() => assertVerifiedCreationTransaction({ ...fixture, cborAuxdata })).toThrow(
          'creation input',
        )
    })

    test('keeps opcodes, arguments, every trailer structure and surrounding bytes exact', () => {
      for (const changed of [
        input.replace('6001600055', '6002600055'),
        `${input.slice(0, -2)}ff`,
        input.replace('55fea2', '5500a2'),
        input.replace('1220', '1221'),
        input.replace('0033a2', '0034a2'),
        input.replace('0033a2', '003300a2'),
        input.replace('0033a2', '0033a3'),
        input.replace('000824', '000825'),
        input.replace(
          '0008240033' + constructorArgs.slice(2),
          '0008250033' + constructorArgs.slice(2),
        ),
        `${input}00`,
      ])
        expect(() =>
          assertVerifiedCreationTransaction({
            ...fixture,
            minedTransaction: { ...fixture.minedTransaction, input: changed as Hex },
          }),
        ).toThrow('creation input')
    })

    test('validates grammar, delimiter, alignment and compiler version from compiler output too', () => {
      for (const creationBytecode of [
        bytecode.replace('55fea2', '5500a2'),
        bytecode.replace('1220', '1221'),
        bytecode.replace('0033a2', '0034a2'),
        bytecode.replace('000824', '000825'),
        `${bytecode.slice(0, -10)}0008250033`,
        // Metadata must start on a byte boundary, never at a half-byte offset.
        bytecode.replace('55fe', '55ffe'),
      ])
        expect(() =>
          assertVerifiedCreationTransaction({
            ...fixture,
            creationBytecode: creationBytecode as Hex,
            cborAuxdata: null,
            minedTransaction: {
              ...fixture.minedTransaction,
              input:
                `${creationBytecode.replace('4c899a', '4c899b')}${constructorArgs.slice(2)}` as Hex,
            },
          }),
        ).toThrow('creation input')
    })
  })

  test('never ignores constructor bytes, opcodes, metadata structure, compiler version or appended data', () => {
    for (const changed of [
      input.replace('6001600055', '6002600055'),
      `${input.slice(0, -2)}ff`,
      input.slice(0, -2),
      `${input}00`,
      input.replace('64736f6c63430008240033', '64736f6c63430008250033'),
      input.replace('64736f6c63430008240033', '64736f6c63430008240034'),
      input.replace('a2646970667358221220', 'a2646970667358221221'),
      '0x60006000f3',
    ] as const)
      expect(() =>
        assertVerifiedCreationTransaction({
          ...options,
          minedTransaction: { ...options.minedTransaction, input: changed as `0x${string}` },
        }),
      ).toThrow('creation input')
  })

  test('rejects malformed or attacker-selected auxiliary ranges rather than masking them', () => {
    for (const cborAuxdata of [
      {},
      [],
      'range',
      6,
      { '1': null },
      { '1': {} },
      { '1': { ...range, offset: -1 } },
      { '1': { ...range, offset: 6.5 } },
      { '1': { ...range, offset: 7 } },
      { '1': { ...range, offset: Number.MAX_SAFE_INTEGER } },
      { '1': { offset: 0, value: creationBytecode } },
      { '1': { ...range, value: '0x00' } },
      { '1': range, '2': range },
    ])
      expect(() => assertVerifiedCreationTransaction({ ...options, cborAuxdata })).toThrow(
        'creation input',
      )
    // An otherwise valid metadata range never excuses a custom constructor opcode.
    expect(() =>
      assertVerifiedCreationTransaction({
        ...options,
        cborAuxdata: { '1': range },
        minedTransaction: {
          ...options.minedTransaction,
          input: input.replace('6001600055', '6002600055') as `0x${string}`,
        },
      }),
    ).toThrow('creation input')
  })

  test('requires an admitted Solidity compiler version matching the actual trailer', () => {
    for (const changed of [
      {},
      { ...compiler, name: 'vyper' },
      { ...compiler, language: 'Yul' },
      { ...compiler, version: '0.8.35+commit.8a079791' },
      { ...compiler, version: '0.8.36-nightly' },
    ])
      expect(() => assertVerifiedCreationTransaction({ ...options, compiler: changed })).toThrow(
        'creation input',
      )
  })

  test('does not strip separated embedded CBOR, arbitrary initcode or unsupported metadata formats', () => {
    const embedded = `0x6001fe${metadata}6002fe${metadata}` as const
    expect(() =>
      assertVerifiedCreationTransaction({
        ...options,
        creationBytecode: embedded,
        minedTransaction: {
          ...options.minedTransaction,
          input: `${embedded.replace('4c899a', '4c899b')}${constructorArgs.slice(2)}` as Hex,
        },
      }),
    ).toThrow('creation input')
    for (const creationBytecode of [
      '0x6001600055',
      `0x600160005500${metadata}`,
      '0x',
      '0x0',
      '0xzz',
    ] as const)
      expect(() => assertVerifiedCreationTransaction({ ...options, creationBytecode })).toThrow(
        'creation input',
      )
  })

  test('checks the sender, transaction and Tempo envelope before metadata compatibility', () => {
    for (const minedTransaction of [
      { ...options.minedTransaction, from: address },
      { ...options.minedTransaction, hash: `0x${'34'.repeat(32)}` as const },
      { ...options.minedTransaction, to: address },
      { ...options.minedTransaction, typeHex: '0x76' as const, calls: [{ input }, { input }] },
    ])
      expect(() => assertVerifiedCreationTransaction({ ...options, minedTransaction })).toThrow(
        'expected direct creation',
      )
    expect(() =>
      assertVerifiedCreationTransaction({
        ...options,
        minedTransaction: { hash: transaction, from: other, typeHex: '0x76', calls: [{ input }] },
      }),
    ).not.toThrow()
  })
})
