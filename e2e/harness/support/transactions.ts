import {
  BaseError,
  ContractFunctionRevertedError,
  ExecutionRevertedError,
  type Abi,
  type ContractFunctionArgs,
  type ContractFunctionName,
  type Hash,
  type WriteContractParameters,
} from 'viem'
import type { E2eContext, E2eWallet } from '../context.js'
import { TIMEOUT_MS } from './utils.js'

/** Sends a contract write and returns its receipt, throwing when the transaction reverts. */
export function write<
  const abi extends Abi | readonly unknown[],
  functionName extends ContractFunctionName<abi, 'nonpayable' | 'payable'>,
  const args extends ContractFunctionArgs<abi, 'nonpayable' | 'payable', functionName>,
>(
  wallet: E2eWallet,
  request: WriteContractParameters<
    abi,
    functionName,
    args,
    E2eWallet['chain'],
    E2eWallet['account']
  >,
) {
  // The request is already checked against its ABI above; the Tempo client's own overloads
  // cannot be named generically.
  return wallet.writeContractSync({
    ...request,
    throwOnReceiptRevert: true,
    timeout: TIMEOUT_MS,
  } as never)
}

/** Waits for a submitted transaction's receipt, throwing when it reverted. */
export async function waitForSuccessfulWrite(context: E2eContext, hash: Hash) {
  const receipt = await context.l1Public.waitForTransactionReceipt({ hash, timeout: TIMEOUT_MS })
  if (receipt.status !== 'success') throw new Error(`Transaction ${hash} reverted`)
  return receipt
}

export async function expectRevertedWrite(
  context: E2eContext,
  submit: () => Promise<Hash>,
  message: string,
) {
  try {
    const hash = await submit()
    const receipt = await context.l1Public.waitForTransactionReceipt({ hash, timeout: TIMEOUT_MS })
    if (receipt.status === 'reverted') return
  } catch (error) {
    if (isExpectedContractRevert(error)) return
    throw error
  }
  throw new Error(message)
}

export async function expectContractRevert(action: () => Promise<unknown>, message: string) {
  try {
    await action()
  } catch (error) {
    if (isExpectedContractRevert(error)) return
    throw error
  }
  throw new Error(message)
}

function isExpectedContractRevert(error: unknown) {
  if (!(error instanceof BaseError)) return false
  return (
    error.walk(
      (cause) =>
        cause instanceof ContractFunctionRevertedError ||
        cause instanceof ExecutionRevertedError ||
        (cause instanceof Error &&
          [
            'ContractFunctionRevertedError',
            'ExecutionRevertedError',
            'TransactionReceiptRevertedError',
          ].includes(cause.name)),
    ) !== null
  )
}
