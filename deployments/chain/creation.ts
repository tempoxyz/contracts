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
