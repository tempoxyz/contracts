import {
  BaseError,
  ContractFunctionRevertedError,
  ExecutionRevertedError,
  RpcRequestError,
  decodeErrorResult,
  type Abi,
  type ContractFunctionArgs,
  type ContractFunctionName,
  type Hash,
  type Hex,
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

/** Requires a mined revert or original preflight revert bytes, optionally with a decoded error name. */
export async function expectRevertedWrite(
  context: E2eContext,
  submit: () => Promise<Hash>,
  message: string,
  options?: ExpectedRevert,
) {
  try {
    const hash = await submit()
    const receipt = await context.l1Public.waitForTransactionReceipt({ hash, timeout: TIMEOUT_MS })
    // A receipt proves failure, not its reason; exact assertions need decoded preflight evidence.
    if (receipt.status === 'reverted' && !options) return
  } catch (error) {
    if (isExpectedContractRevert(error, options)) return
    throw error
  }
  throw new Error(message)
}

/** Requires a reverted receipt or original revert bytes, never a pending or transport failure. */
export async function expectRevertedReceipt(
  action: () => Promise<{ status: string }>,
  message: string,
) {
  try {
    const receipt = await action()
    if (receipt.status === 'reverted') return
  } catch (error) {
    if (isExpectedContractRevert(error)) return
    throw error
  }
  throw new Error(message)
}

/** Requires a contract revert, optionally proving its error name with ABI-decoded revert data. */
export async function expectContractRevert(
  action: () => Promise<unknown>,
  message: string,
  options?: ExpectedRevert,
) {
  try {
    await action()
  } catch (error) {
    if (isExpectedContractRevert(error, options)) return
    throw error
  }
  throw new Error(message)
}

type ExpectedRevert = {
  abi: Abi
  errorName: string
}

function isExpectedContractRevert(error: unknown, options?: ExpectedRevert) {
  if (!(error instanceof BaseError)) return false
  // Viem also wraps internal RPC failures as contract reverts; a class or message is not evidence.
  // Tempo wrappers may synthesize selectors, so require original revert bytes or a failed receipt.
  const reverted = error.walk(
    (cause) =>
      ((cause instanceof ContractFunctionRevertedError ||
        (cause instanceof RpcRequestError && cause.code === ExecutionRevertedError.code)) &&
        originalRevertData(cause) !== undefined) ||
      isRevertedReceiptError(cause),
  )
  if (!reverted) return false
  if (isRevertedReceiptError(reverted)) return !options
  const data = originalRevertData(reverted)
  if (!data) return false
  if (!options) return true

  try {
    return decodeErrorResult({ abi: options.abi, data }).errorName === options.errorName
  } catch {
    return false
  }
}

function originalRevertData(error: unknown): Hex | undefined {
  const data = (() => {
    if (error instanceof ContractFunctionRevertedError) {
      // The Zone serializes its inner execution RPC error, including revert bytes, in the outer message.
      // Require the complete code-3 envelope, not a reason name or an arbitrary hex substring.
      return (
        error.raw ??
        error.reason?.match(
          /^ErrorObject \{ code: ServerError\(3\), message: "execution reverted(?:: (?:[^"\\]|\\.)*)?", data: Some\(RawValue\("(0x(?:[\da-f]{2})+)"\)\) \}$/i,
        )?.[1]
      )
    }
    if (error instanceof RpcRequestError) {
      if (typeof error.data === 'object' && error.data !== null && 'data' in error.data)
        return error.data.data
      return error.data
    }
    return undefined
  })()
  return typeof data === 'string' && /^0x(?:[\da-f]{2})+$/i.test(data) ? (data as Hex) : undefined
}

function isRevertedReceiptError(error: unknown) {
  // Viem does not export this error class; require its attached receipt, not just its name.
  if (!(error instanceof BaseError) || error.name !== 'TransactionReceiptRevertedError')
    return false
  if (!('receipt' in error) || typeof error.receipt !== 'object' || error.receipt === null)
    return false
  return 'status' in error.receipt && error.receipt.status === 'reverted'
}
