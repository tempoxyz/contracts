// Helpers the Zone E2E's flows share: the Zone outbox and router callback ABIs, waiting, checks,
// and reading call traces and outbox events.
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  BaseError,
  ContractFunctionRevertedError,
  encodePacked,
  isAddressEqual,
  keccak256,
  parseAbi,
  parseAbiParameters,
  parseEventLogs,
  type Abi,
  type Address,
  type Hex,
  type Log,
} from 'viem'

import * as Network from './network.js'
import { root } from './targets.js'

export const CALLBACK_GAS = 3_000_000n

export const pathUsd = Network.address.pathUsd
export const outbox = Network.address.zoneOutbox

export const outboxAbi = parseAbi([
  'function calculateWithdrawalFee(uint64 gasLimit) view returns (uint128)',
  'function requestWithdrawal(address token, address to, uint128 amount, bytes32 memo, uint64 gasLimit, address fallbackRecipient, bytes data, bytes revealTo)',
  'event WithdrawalRequested(uint64 indexed withdrawalIndex, address indexed sender, address token, address to, uint128 amount, uint128 fee, bytes32 memo, uint64 gasLimit, uint64 fallbackNonce, bytes data, bytes revealTo)',
])
export const portalEventsAbi = parseAbi([
  'event WithdrawalProcessed(address indexed to, bytes32 indexed senderTag, address token, uint128 amount, bool callbackSuccess)',
])
export const zoneTokenAbi = parseAbi([
  'function transfer(address to, uint256 amount) returns (bool)',
  'error Unauthorized()',
])
/** `CardSpend`: one card spend, the same for a public spend and a private one's spender data. */
export const cardSpendType = parseAbiParameters([
  'CardSpend spend',
  'struct CardSpend { address program; address token; uint256 amount; address destination; uint256 destinationHint; address vault; uint256 fromVault; uint256 maxShares; bytes32 ref; }',
])
/**
 * The CardSpender's public spend and its events: `CardSpent` for every spend, and `InputSpent`
 * for a private one, with the input accounting the router sees.
 */
export const programAbi = parseAbi([
  'struct CardSpend { address program; address token; uint256 amount; address destination; uint256 destinationHint; address vault; uint256 fromVault; uint256 maxShares; bytes32 ref; }',
  'function spend(CardSpend s)',
  'event CardSpent(bytes32 indexed ref, address indexed payer, address indexed destination, address token, uint256 amount, uint256 fromVault, uint256 sharesUsed, bool isPrivate)',
  'event InputSpent(bytes32 indexed ref, address inputToken, uint256 inputConsumed, uint256 inputReturned)',
])
/** The selector a public spend's access key is scoped to on the program. */
export const PROGRAM_SPEND_SELECTOR =
  'spend((address,address,uint256,address,uint256,address,uint256,uint256,bytes32))'
/** The "TS" handler's event, which the clone emits with the paying account (the program) as `from`. */
export const tempoSpendAbi = parseAbi([
  'event TempoSpendExecuted(bytes32 indexed ref, address indexed from, address indexed destination, address token, uint256 amount, uint256 fromStable, uint256 fromVault, uint256 sharesBurned)',
])
/** `ZoneRouter.SpendData`, the callback data of the router's Spend op. */
export const spendDataType = parseAbiParameters([
  'SpendData data',
  'struct SpendData { uint8 op; address spender; uint128 maxInput; bytes spenderData; SpendReturn zoneReturn; }',
  'struct SpendReturn { uint256 keyIndex; DepositPayload encrypted; address refundRecipient; uint128 maxDepositFee; }',
  'struct DepositPayload { bytes32 ephemeralPubkeyX; uint8 ephemeralPubkeyYParity; bytes ciphertext; bytes12 nonce; bytes16 tag; }',
])
/** `ZoneRouter.Op.Spend`. */
export const OP_SPEND = 2

export function artifact(name: string) {
  const json = JSON.parse(readFileSync(resolve(root, `out/${name}.sol/${name}.json`), 'utf8'))
  return { abi: json.abi as Abi, bytecode: json.bytecode.object as Hex }
}

export type CallFrame = {
  to?: string
  input?: string
  gas?: Hex
  gasUsed?: Hex
  calls?: CallFrame[]
}

/** The first call frame in `frame`'s tree to `to` with `selector`, depth first. */
export function findCall(frame: CallFrame, to: Address, selector: Hex): CallFrame | undefined {
  if (frame.to?.toLowerCase() === to.toLowerCase() && frame.input?.startsWith(selector))
    return frame
  for (const child of frame.calls ?? []) {
    const found = findCall(child, to, selector)
    if (found) return found
  }
  return undefined
}

export function step(n: number, text: string) {
  console.log(`[${n}] ${text}`)
}

export async function waitFor<T>(
  label: string,
  read: () => Promise<T>,
  done: (value: T) => boolean,
  intervalMs = 1000,
) {
  const deadline = Date.now() + 240_000
  for (;;) {
    const value = await read()
    if (done(value)) return value
    if (Date.now() > deadline)
      throw new Error(`timed out waiting for ${label} (last read ${String(value)})`)
    await new Promise((r) => setTimeout(r, intervalMs))
  }
}

/** Wall-clock milliseconds since `start`, from `performance.now()`. */
export function since(start: number) {
  return Math.round(performance.now() - start)
}

export function median(values: number[]) {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor(sorted.length / 2)]!
}

/** Whether any of `logs` carries `address` in its topics or data. */
export function names(logs: readonly Log[], address: Address) {
  const needle = address.slice(2).toLowerCase()
  return logs.some(
    (log) =>
      log.data.toLowerCase().includes(needle) ||
      log.topics.some((topic) => topic?.toLowerCase().includes(needle)),
  )
}

/**
 * Whether a transaction's calldata carries `address`, such as a settlement transaction's: the Portal's withdrawal
 * batch with each callback's data, which names a sender only through its `senderTag` commitment. A Tempo
 * transaction carries its calldata in `calls`, others in `input`; one with neither cannot be checked.
 */
export function inputNames(
  transaction: {
    input?: Hex | undefined
    calls?: readonly { data?: Hex | undefined }[] | undefined
  },
  address: Address,
) {
  const calldata = [
    transaction.input,
    ...(transaction.calls ?? []).map((call) => call.data),
  ].filter((data): data is Hex => data !== undefined && data !== '0x')
  if (calldata.length === 0) throw new Error('the settlement transaction has no calldata to check')
  const needle = address.slice(2).toLowerCase()
  return calldata.some((data) => data.toLowerCase().includes(needle))
}

export function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`check failed: ${message}`)
}

/**
 * The revert data of a failed call: as viem decoded it, or as the Zone RPC quotes it in the message
 * of the internal error it wraps reverts in.
 */
export function revertData(error: unknown): Hex | undefined {
  if (!(error instanceof BaseError)) return undefined
  const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError)
  if (reverted instanceof ContractFunctionRevertedError) {
    if (reverted.raw) return reverted.raw
    return reverted.reason?.match(/RawValue\("(0x[0-9a-fA-F]*)"\)/)?.[1] as Hex | undefined
  }
  return undefined
}

/**
 * The outbox's WithdrawalRequested in a Zone receipt, with the sender tag the portal's
 * WithdrawalProcessed for it carries, derived as viem's `requestWithdrawalSync` derives it.
 */
export function withdrawalRequested(receipt: { logs: Log[]; transactionHash: Hex }) {
  const logs = receipt.logs.filter((log) => isAddressEqual(log.address, outbox))
  const [event] = parseEventLogs({ abi: outboxAbi, eventName: 'WithdrawalRequested', logs })
  assert(event, 'the Zone receipt carries the outbox WithdrawalRequested event')
  const senderTag = keccak256(
    encodePacked(
      ['address', 'bytes32', 'uint64'],
      [event.args.sender, receipt.transactionHash, event.args.fallbackNonce],
    ),
  )
  return { ...event.args, senderTag }
}

/**
 * The CardSpender's `CardSpent` for `ref` in `logs` and the clone's `TempoSpendExecuted` for it,
 * exactly one each: the program pays through the clone, so the handler's `from` is the program.
 */
export function cardSpent(logs: readonly Log[], program: Address, ref: Hex) {
  const spent = parseEventLogs({
    abi: programAbi,
    eventName: 'CardSpent',
    args: { ref },
    logs: logs.filter((log) => isAddressEqual(log.address, program)),
  })
  assert(spent.length === 1, `one CardSpender CardSpent event for ref ${ref}`)
  const executed = parseEventLogs({
    abi: tempoSpendAbi,
    eventName: 'TempoSpendExecuted',
    args: { ref },
    logs: [...logs],
  })
  assert(executed.length === 1, `one TempoSpendExecuted event for ref ${ref}`)
  assert(
    isAddressEqual(executed[0]!.args.from, program),
    `the "TS" handler paid as the CardSpender (from ${executed[0]!.args.from})`,
  )
  return { ...spent[0]!.args, sharesBurned: executed[0]!.args.sharesBurned }
}
