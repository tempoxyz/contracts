import { getAddress, isAddressEqual, keccak256, numberToHex, type Address, type Hex } from 'viem'
import { Transaction } from 'viem/tempo'
import type { PublicClient } from './targets.js'
import * as Network from './network.js'

/** Resolve an unsponsored pathUSD fee identity from the mined, signed Tempo envelope. */
export async function resolve(
  client: Pick<PublicClient, 'request'>,
  receipt: {
    transactionHash: Hex
    blockHash: Hex
    blockNumber: bigint
    feeToken?: Address | undefined
    feePayer?: Address | undefined
  },
  payer: Address,
): Promise<{ feeToken: Address; feePayer: Address }> {
  const expectedToken = Network.address.pathUsd
  assertAddress(payer, 'expected payer')
  assertHash(receipt.transactionHash, 'receipt transaction hash')
  assertHash(receipt.blockHash, 'receipt block hash')
  if (typeof receipt.blockNumber !== 'bigint' || receipt.blockNumber < 0n)
    throw new Error('Fee evidence requires a mined receipt block number')
  assertOptionalAddress(receipt.feeToken, expectedToken, 'receipt fee token')
  assertOptionalAddress(receipt.feePayer, payer, 'receipt fee payer')

  const [transactionValue, rawValue, blockValue] = await Promise.all([
    client.request({ method: 'eth_getTransactionByHash', params: [receipt.transactionHash] }),
    client.request({ method: 'eth_getRawTransactionByHash', params: [receipt.transactionHash] }),
    client.request({
      method: 'eth_getBlockByNumber',
      params: [numberToHex(receipt.blockNumber), false],
    }),
  ])
  const transaction = record(transactionValue, 'mined transaction')
  const block = record(blockValue, 'canonical block')
  assertEqualHash(transaction.hash, receipt.transactionHash, 'transaction hash')
  assertEqualHash(transaction.blockHash, receipt.blockHash, 'transaction block hash')
  assertBlockNumber(transaction.blockNumber, receipt.blockNumber, 'transaction block number')
  assertEqualHash(block.hash, receipt.blockHash, 'canonical block hash')
  assertBlockNumber(block.number, receipt.blockNumber, 'canonical block number')
  if (
    !Array.isArray(block.transactions) ||
    !block.transactions.some(
      (hash: unknown) =>
        typeof hash === 'string' && hash.toLowerCase() === receipt.transactionHash.toLowerCase(),
    )
  )
    throw new Error('Fee evidence transaction is absent from the canonical block')

  if (typeof rawValue !== 'string' || !/^0x76(?:[0-9a-fA-F]{2})+$/.test(rawValue))
    throw new Error('Fee evidence requires a signed Tempo transaction envelope')
  const raw = rawValue as `0x76${string}`
  assertEqualHash(keccak256(raw), receipt.transactionHash, 'signed transaction hash')
  const decoded = Transaction.deserialize(raw)
  // An absent JSON-RPC payer is not proof: the signed envelope must have an empty sponsor slot.
  if (decoded.feePayerSignature !== undefined)
    throw new Error('Fee evidence cannot attribute a sponsored or sponsor-pending transaction')
  if (!decoded.signature || !decoded.from)
    throw new Error('Fee evidence cannot recover the signed root sender')
  assertOptionalAddress(decoded.feeToken, expectedToken, 'signed fee token')
  if (!decoded.feeToken)
    throw new Error('Fee evidence requires an explicit signed pathUSD fee token')
  assertOptionalAddress(decoded.from, payer, 'signed root sender')
  assertAddress(transaction.from, 'transaction sender')
  assertOptionalAddress(transaction.from, payer, 'transaction sender')
  assertOptionalAddress(transaction.feeToken, expectedToken, 'transaction fee token')
  assertOptionalAddress(transaction.feePayer, payer, 'transaction fee payer')
  if (transaction.feePayerSignature !== undefined && transaction.feePayerSignature !== null)
    throw new Error('Fee evidence transaction contradicts the unsponsored signed envelope')

  return { feeToken: expectedToken, feePayer: getAddress(decoded.from) }
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    throw new Error(`Fee evidence is missing the ${label}`)
  return value as Record<string, unknown>
}

function assertHash(value: unknown, label: string): asserts value is Hex {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value))
    throw new Error(`Fee evidence has an invalid ${label}`)
}

function assertEqualHash(value: unknown, expected: Hex, label: string) {
  assertHash(value, label)
  if (value.toLowerCase() !== expected.toLowerCase())
    throw new Error(`Fee evidence has a conflicting ${label}`)
}

function assertBlockNumber(value: unknown, expected: bigint, label: string) {
  if (typeof value !== 'string' || !/^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/.test(value))
    throw new Error(`Fee evidence has an invalid ${label}`)
  if (BigInt(value) !== expected) throw new Error(`Fee evidence has a conflicting ${label}`)
}

function assertAddress(value: unknown, label: string): asserts value is Address {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value))
    throw new Error(`Fee evidence has an invalid ${label}`)
}

function assertOptionalAddress(value: unknown, expected: Address, label: string) {
  if (value === undefined) return
  assertAddress(value, label)
  if (!isAddressEqual(value, expected)) throw new Error(`Fee evidence has a conflicting ${label}`)
}
