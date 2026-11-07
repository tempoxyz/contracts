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
  const { address, transaction, deployer, creationBytecode, constructorArgs, minedTransaction } =
    options
  if (
    minedTransaction.hash.toLowerCase() !== transaction.toLowerCase() ||
    getAddress(minedTransaction.from) !== getAddress(deployer)
  )
    throw new Error(
      `Recorded transaction ${transaction} is not the expected direct creation of ${address}`,
    )
  const input = (() => {
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
