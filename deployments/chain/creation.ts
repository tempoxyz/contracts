import {
  decodeEventLog,
  getAddress,
  type AbiEvent,
  type Address,
  type Hex,
  type TransactionReceipt,
} from 'viem'

/** Binds a recorded creation transaction to its output using a successful receipt, never a verifier echo. */
export function assertCreationReceipt(options: {
  address: Address
  transaction: Hex
  receipt: Pick<TransactionReceipt, 'status' | 'transactionHash' | 'contractAddress' | 'logs'>
  factory?: { address: Address; event: AbiEvent; argument: string } | undefined
}) {
  const { address, transaction, receipt, factory } = options
  if (
    receipt.status !== 'success' ||
    receipt.transactionHash.toLowerCase() !== transaction.toLowerCase()
  )
    throw new Error(`Creation receipt for ${address} is not the successful recorded transaction`)
  if (!factory) {
    if (receipt.contractAddress && getAddress(receipt.contractAddress) === getAddress(address))
      return
  } else {
    for (const log of receipt.logs) {
      if (log.removed || getAddress(log.address) !== getAddress(factory.address)) continue
      try {
        const decoded = decodeEventLog({
          abi: [factory.event],
          data: log.data,
          topics: log.topics,
          strict: true,
        })
        const value = (decoded.args as Record<string, unknown>)[factory.argument]
        if (typeof value === 'string' && getAddress(value) === getAddress(address)) return
      } catch {
        // Unrelated or malformed logs cannot establish creation.
      }
    }
  }
  throw new Error(`Recorded transaction ${transaction} does not prove creation of ${address}`)
}

/** Proves the declared constructor ran, not merely that a transaction returned matching runtime. */
export function assertDirectCreationTransaction(options: {
  address: Address
  transaction: Hex
  deployer: Address
  creationBytecode: Hex
  constructorArgs: Hex
  minedTransaction: {
    hash: Hex
    from: Address
    to?: Address | null | undefined
    input?: Hex | undefined
    type?: string | undefined
    typeHex?: Hex | null | undefined
    calls?:
      | readonly {
          to?: Address | null | undefined
          input?: Hex | undefined
          data?: Hex | undefined
        }[]
      | undefined
  }
}): void {
  const { address, transaction, creationBytecode, constructorArgs } = options
  const input = directCreationInput(options)
  if (
    !/^0x(?:[0-9a-fA-F]{2})+$/.test(creationBytecode) ||
    !/^0x(?:[0-9a-fA-F]{2})*$/.test(constructorArgs) ||
    typeof input !== 'string' ||
    !/^0x(?:[0-9a-fA-F]{2})+$/.test(input) ||
    input.toLowerCase() !== `${creationBytecode}${constructorArgs.slice(2)}`.toLowerCase()
  )
    throw new Error(
      `Recorded transaction ${transaction} has unexpected creation input for ${address}`,
    )
}

/** Checks an admitted Solidity recompilation, allowing only validated terminal IPFS metadata digest differences. */
export function assertVerifiedCreationTransaction(
  options: Parameters<typeof assertDirectCreationTransaction>[0] & {
    compiler: { name?: string | null; version?: string | null; language?: string | null }
    /** Verifier ranges never authorize masking; supplied ranges must exactly cover the derived trailers. */
    cborAuxdata?: unknown
  },
): void {
  const { creationBytecode, constructorArgs, compiler, cborAuxdata } = options
  const input = directCreationInput(options)
  const expected = `${creationBytecode}${constructorArgs.slice(2)}`.toLowerCase()
  if (input?.toLowerCase() === expected) return assertDirectCreationTransaction(options)

  // Factory output can end with a child's metadata followed by its own: solc's adjacent behind one INVALID
  // delimiter, solar's each behind its own. Each trailer names its compiler's version: solc's, or solar's own.
  // Read only this terminal chain from compiler output; never search executable bytes or trust verifier mask offsets.
  const solar = compiler.version?.match(
    /^\d+\.\d+\.\d+\+commit\.([0-9a-f]+)\.solar\.(\d+)\.(\d+)\.(\d+)(-[0-9a-z.]+)?$/i,
  )
  const solc = solar
    ? undefined
    : compiler.version?.match(/^(\d+)\.(\d+)\.(\d+)\+commit\.[0-9a-f]+$/i)
  const version = solar ?? solc
  // Each trailer starts at `start` (a hex index into the bytecode string) and names a compiler version.
  type Trailer = { start: number; value: string; versionMatches: boolean }
  const chain = ((): { index: number; trailers: Trailer[] } | undefined => {
    if (solc) {
      const pattern = '(a2646970667358221220[0-9a-f]{64}64736f6c6343([0-9a-f]{6})0033)'
      const tail = new RegExp(`fe((?:${pattern})+)$`, 'i').exec(creationBytecode)
      if (!tail) return undefined
      return {
        index: tail.index,
        trailers: [...tail[1]!.matchAll(new RegExp(pattern, 'gi'))].map((match) => ({
          // Skip solc's one shared delimiter.
          start: tail.index + 2 + match.index,
          value: `0x${match[1]}`.toLowerCase(),
          versionMatches: solc
            .slice(1)
            .every(
              (part, index) =>
                Number(part) === Number.parseInt(match[2]!.slice(index * 2, index * 2 + 2), 16),
            ),
        })),
      }
    }
    if (!solar) return undefined
    // Solar ends each trailer with its byte length, behind its own INVALID delimiter. Its version is a 3-byte
    // string in releases before 0.3.1 and a text string after; parse the chain backward from the end.
    const [, commit, major, minor, patch, prerelease] = solar
    const texts = [`${major}.${minor}.${patch}${prerelease ?? ''}`]
    texts.push(`${texts[0]}+commit.${commit}`.toLowerCase())
    const hex = creationBytecode.toLowerCase()
    const trailers: Trailer[] = []
    let end = hex.length
    for (;;) {
      if (end < 6) break
      const size = 2 * (2 + Number.parseInt(hex.slice(end - 4, end), 16))
      const start = end - size
      if (start < 4 || hex.slice(start - 2, start) !== 'fe') break
      const body = hex.slice(start, end - 4)
      const head = /^a2646970667358221220[0-9a-f]{64}65736f6c6172/.exec(body)
      if (!head) break
      const item = body.slice(head[0].length)
      const versionMatches = (() => {
        if (/^43[0-9a-f]{6}$/.test(item))
          return (
            prerelease === undefined &&
            [major, minor, patch].every(
              (part, index) =>
                Number(part) === Number.parseInt(item.slice(2 + index * 2, 4 + index * 2), 16),
            )
          )
        const text = /^(?:(6[0-9a-f]|7[0-7])|78([0-9a-f]{2}))((?:[0-9a-f]{2})*)$/.exec(item)
        if (!text) return undefined
        const length = text[1] ? Number.parseInt(text[1], 16) - 0x60 : Number.parseInt(text[2]!, 16)
        if (text[3]!.length !== 2 * length) return undefined
        return texts.includes(Buffer.from(text[3]!, 'hex').toString('latin1').toLowerCase())
      })()
      if (versionMatches === undefined) break
      trailers.unshift({ start, value: `0x${hex.slice(start, end)}`, versionMatches })
      end = start - 2
    }
    return trailers.length === 0 ? undefined : { index: end, trailers }
  })()
  const trailers = (chain?.trailers ?? []).map(({ start, value, versionMatches }) => ({
    offset: (start - 2) / 2,
    digestStart: start + 'a2646970667358221220'.length,
    value,
    versionMatches,
  }))
  const ranges = cborAuxdata == null ? [] : Object.values(Object(cborAuxdata))
  const seen = new Set<number>()
  const validRanges =
    cborAuxdata == null ||
    (typeof cborAuxdata === 'object' &&
      !Array.isArray(cborAuxdata) &&
      ranges.length === trailers.length &&
      ranges.every((range: unknown) => {
        if (!range || typeof range !== 'object' || Array.isArray(range)) return false
        const { offset: start, value } = range as { offset?: unknown; value?: unknown }
        if (typeof start !== 'number' || !Number.isSafeInteger(start) || seen.has(start))
          return false
        seen.add(start)
        return trailers.some(
          (trailer) =>
            trailer.offset === start &&
            typeof value === 'string' &&
            value.toLowerCase() === trailer.value,
        )
      }))
  const matchingBytes = (() => {
    if (typeof input !== 'string') return false
    let start = 0
    for (const { digestStart } of trailers) {
      if (input.slice(start, digestStart).toLowerCase() !== expected.slice(start, digestStart))
        return false
      start = digestStart + 64
    }
    return input.slice(start).toLowerCase() === expected.slice(start)
  })()
  if (
    compiler.name !== 'solc' ||
    compiler.language !== 'Solidity' ||
    !version ||
    !chain ||
    chain.index % 2 !== 0 ||
    trailers.some((trailer) => !trailer.versionMatches) ||
    !validRanges ||
    !/^0x(?:[0-9a-fA-F]{2})+$/.test(creationBytecode) ||
    !/^0x(?:[0-9a-fA-F]{2})*$/.test(constructorArgs) ||
    typeof input !== 'string' ||
    !/^0x(?:[0-9a-fA-F]{2})+$/.test(input) ||
    input.length !== expected.length ||
    !matchingBytes
  )
    throw new Error(
      `Recorded transaction ${options.transaction} has unexpected creation input for ${options.address}; only validated terminal Solidity IPFS metadata differences are supported`,
    )
}

function directCreationInput(options: Parameters<typeof assertDirectCreationTransaction>[0]) {
  const { address, transaction, deployer, minedTransaction } = options
  if (
    minedTransaction.hash.toLowerCase() !== transaction.toLowerCase() ||
    getAddress(minedTransaction.from) !== getAddress(deployer)
  )
    throw new Error(
      `Recorded transaction ${transaction} is not the expected direct creation of ${address}`,
    )
  return (() => {
    const { calls, input, to, type, typeHex } = minedTransaction
    const tempo = type === 'tempo' || type === '0x76' || typeHex === '0x76'
    if (tempo || calls !== undefined) {
      // Generic viem clients preserve RPC calls[].input; Tempo formatters rename it to data.
      // Only a single creation call is unambiguous; a batch can also mutate constructor state.
      const call = calls?.[0]
      if (!tempo || calls?.length !== 1 || !call || call.to != null || to != null)
        throw new Error(
          `Recorded transaction ${transaction} is not the expected direct creation of ${address}`,
        )
      const data = call.input ?? call.data
      if (
        (call.input !== undefined &&
          call.data !== undefined &&
          call.input.toLowerCase() !== call.data.toLowerCase()) ||
        (input !== undefined && input !== '0x' && input.toLowerCase() !== data?.toLowerCase())
      )
        throw new Error(
          `Recorded transaction ${transaction} has conflicting creation input for ${address}`,
        )
      return data
    }
    if (to !== null)
      throw new Error(
        `Recorded transaction ${transaction} is not the expected direct creation of ${address}`,
      )
    return input
  })()
}
