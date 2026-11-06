import {
  decodeAbiParameters,
  decodeFunctionData,
  encodeAbiParameters,
  encodePacked,
  erc20Abi,
  getAbiItem,
  isAddressEqual,
  keccak256,
  parseEventLogs,
  parseAbiParameters,
  type Address,
  type Hex,
  type Log,
} from 'viem'
import { Abis, Addresses } from 'viem/tempo'
import type { E2eZoneContext } from '../../harness/context.js'
import { assert, waitFor } from '../../harness/support/utils.js'

// Earlier Zone runtimes use encrypted-prefixed event names with the same field layouts.
const made = getAbiItem({ abi: Abis.zonePortal, name: 'DepositMade' })
/** Portal deposit events across the current and encrypted-prefixed runtimes. */
export const portalDepositAbi = [made, { ...made, name: 'EncryptedDepositMade' }] as const
/** Inbox outcomes across the current and encrypted-prefixed runtimes. */
export const zoneDepositAbi = [
  ...Abis.zoneInbox,
  {
    ...getAbiItem({ abi: Abis.zoneInbox, name: 'DepositProcessed' }),
    name: 'EncryptedDepositProcessed',
  },
  { ...getAbiItem({ abi: Abis.zoneInbox, name: 'DepositFailed' }), name: 'EncryptedDepositFailed' },
] as const

/** The exact queued deposit and its fee from the transaction that created it. */
export function portalDeposit(
  logs: readonly Log[],
  options: { portal: Address; sender: Address; token: Address; gross: bigint; hash?: Hex },
) {
  const deposits = parseEventLogs({
    abi: portalDepositAbi,
    logs: [...logs],
    eventName: ['DepositMade', 'EncryptedDepositMade'],
    strict: true,
  }).filter(
    (log) =>
      isAddressEqual(log.address, options.portal) &&
      isAddressEqual(log.args.sender, options.sender) &&
      isAddressEqual(log.args.token, options.token) &&
      (options.hash === undefined || log.args.newCurrentDepositQueueHash === options.hash),
  )
  assert(deposits.length === 1, 'Expected one attributable Portal deposit in the operation receipt')
  const { netAmount, fee, newCurrentDepositQueueHash: hash } = deposits[0].args
  assert(
    netAmount > 0n && netAmount + fee === options.gross,
    'Portal net credit and fee do not account for the gross output',
  )
  return { hash, netAmount, fee }
}

/** A settled source receipt must identify exactly the submitted withdrawal, never a wildcard tag. */
export function sourceWithdrawal(
  receipt: { status: string; transactionHash: Hex; logs: readonly Log[] },
  options: {
    sender: Address
    to: Address
    token: Address
    amount: bigint
    data: Hex
    gasLimit: bigint
  },
) {
  assert(receipt.status === 'success', 'Zone withdrawal has no successful source receipt')
  const requests = parseEventLogs({
    abi: Abis.zoneOutbox,
    logs: [...receipt.logs],
    eventName: 'WithdrawalRequested',
    strict: true,
  }).filter(
    (log) =>
      isAddressEqual(log.address, Addresses.zoneOutbox) &&
      isAddressEqual(log.args.sender, options.sender) &&
      isAddressEqual(log.args.to, options.to) &&
      isAddressEqual(log.args.token, options.token) &&
      log.args.amount === options.amount &&
      log.args.data === options.data &&
      log.args.gasLimit === options.gasLimit,
  )
  assert(
    requests.length === 1,
    'Zone source receipt does not identify exactly one requested withdrawal',
  )
  const request = requests[0].args
  assert(request.fallbackNonce > 0n, 'Zone source withdrawal has no fallback nonce')
  const senderTag = keccak256(
    encodePacked(
      ['address', 'bytes32', 'uint64'],
      [request.sender, receipt.transactionHash, request.fallbackNonce],
    ),
  )
  return { ...request, senderTag }
}

/** Token movements recorded in this transaction, including actual gas and withdrawal fees. */
export function receiptBalanceChange(logs: readonly Log[], token: Address, actor: Address) {
  return parseEventLogs({ abi: erc20Abi, logs: [...logs], eventName: 'Transfer', strict: true })
    .filter((log) => isAddressEqual(log.address, token))
    .reduce(
      (change, { args }) =>
        change +
        (isAddressEqual(args.to, actor) ? args.value : 0n) -
        (isAddressEqual(args.from, actor) ? args.value : 0n),
      0n,
    )
}

/** Checks custody in the operation receipt so outside donations cannot mask its deficit or residue. */
export function assertRouterReceipt(
  logs: readonly Log[],
  tokens: readonly Address[],
  router: Address,
) {
  for (const token of tokens)
    assert(
      receiptBalanceChange(logs, token, router) === 0n,
      'Router operation did not restore its token custody',
    )
}

/** Waits for this deposit's processing event, rejecting failed or mismatched outcomes. */
export async function waitForDepositDelivery(
  context: E2eZoneContext,
  options: {
    hash: Hex
    token: Address
    sender: Address
    recipient: Address
    amount: bigint
    fromBlock: bigint
  },
) {
  const client = context.zoneProofClient
  const events = [
    getAbiItem({ abi: zoneDepositAbi, name: 'DepositProcessed' }),
    getAbiItem({ abi: zoneDepositAbi, name: 'DepositFailed' }),
    getAbiItem({ abi: zoneDepositAbi, name: 'DepositRejected' }),
    getAbiItem({ abi: zoneDepositAbi, name: 'EncryptedDepositProcessed' }),
    getAbiItem({ abi: zoneDepositAbi, name: 'EncryptedDepositFailed' }),
  ] as const
  const logs = await waitFor(
    'this deposit to be processed in the Zone',
    async () => {
      const logs = await client.getLogs({
        address: Addresses.zoneInbox,
        events,
        fromBlock: options.fromBlock,
        toBlock: 'latest',
        strict: true,
      })
      const matching = logs.filter(
        (log) =>
          !log.removed &&
          isAddressEqual(log.address, Addresses.zoneInbox) &&
          log.args.depositHash === options.hash,
      )
      return matching.length > 0 ? matching : undefined
    },
    { intervalMs: context.pollingInterval },
  )
  assert(logs.length === 1, 'Zone returned ambiguous deposit processing evidence')
  const log = logs[0]
  assert(
    log.eventName === 'DepositProcessed' || log.eventName === 'EncryptedDepositProcessed',
    'The operation deposit failed or was rejected in the Zone',
  )
  assert(
    isAddressEqual(log.args.sender, options.sender) &&
      isAddressEqual(log.args.to, options.recipient) &&
      isAddressEqual(log.args.token, options.token) &&
      log.args.amount === options.amount,
    'Zone deposit processing does not match the queued return',
  )
  return log
}

/** Identifies the failed callback's queued return by its source receipt nonce. */
export function callbackBounce(
  logs: readonly Log[],
  options: {
    portal: Address
    fallbackNonce: bigint
    token: Address
    amount: bigint
  },
) {
  const matches = parseEventLogs({
    abi: Abis.zonePortal,
    logs: [...logs],
    eventName: 'WithdrawalBounceBack',
    strict: true,
  }).filter(
    (log) =>
      isAddressEqual(log.address, options.portal) &&
      log.args.fallbackNonce === options.fallbackNonce,
  )
  assert(matches.length === 1, 'Failed callback has no unique queued bounce-back')
  const log = matches[0]
  assert(
    isAddressEqual(log.args.token, options.token) && log.args.amount === options.amount,
    'Callback bounce does not return the withdrawn input',
  )
  return log.args.newCurrentDepositQueueHash
}

/** Locates a callback bounce in the authenticated Inbox input, not an unrelated balance increase. */
export function processedCallbackBounce(options: {
  input: Hex
  previousHash: Hex
  logs: readonly Log[]
  hash: Hex
  fallbackNonce: bigint
  token: Address
  amount: bigint
  recipient: Address
}) {
  const call = decodeFunctionData({ abi: Abis.zoneInbox, data: options.input })
  assert(call.functionName === 'advanceTempo', 'Bounce receipt is not an Inbox deposit transaction')
  const outcomes = parseEventLogs({
    abi: zoneDepositAbi,
    logs: [...options.logs],
    eventName: [
      'DepositProcessed',
      'EncryptedDepositProcessed',
      'DepositFailed',
      'EncryptedDepositFailed',
      'DepositRejected',
      'WithdrawalBounceBackProcessed',
      'WithdrawalBounceBackPending',
    ],
    strict: true,
  }).filter((log) => isAddressEqual(log.address, Addresses.zoneInbox))
  const deposits = call.args[1]
  assert(outcomes.length === deposits.length, 'Inbox outcomes do not match its deposit batch')
  let hash = options.previousHash
  for (const [index, deposit] of deposits.entries()) {
    // Dynamic deposit tuples must be re-encoded with their outer offsets, not concatenated.
    const payload =
      deposit.depositType === 0
        ? parseAbiParameters('(address token, address to, uint128 amount)')
        : parseAbiParameters(
            '(address token, address sender, uint128 amount, address tempoRefundRecipient, uint256 keyIndex, (bytes32 ephemeralPubkeyX, uint8 ephemeralPubkeyYParity, bytes ciphertext, bytes12 nonce, bytes16 tag) encrypted)',
          )
    const [value] = decodeAbiParameters(payload, deposit.depositData)
    hash = keccak256(
      encodeAbiParameters(
        [{ type: 'uint8' }, payload[0], { type: 'bytes32' }],
        [deposit.depositType, value, hash],
      ),
    )
    if (hash !== options.hash) continue
    assert(deposit.depositType === 0 && 'to' in value, 'Callback return is not a withdrawal bounce')
    assert(
      isAddressEqual(value.token, options.token) &&
        BigInt(value.to) === options.fallbackNonce &&
        value.amount === options.amount,
      'Inbox bounce payload does not match the failed callback',
    )
    const outcome = outcomes[index]
    assert(
      outcome.eventName === 'WithdrawalBounceBackProcessed',
      'Callback bounce remains pending instead of delivered',
    )
    assert(
      isAddressEqual(outcome.args.zoneFallbackRecipient, options.recipient) &&
        isAddressEqual(outcome.args.token, options.token) &&
        outcome.args.amount === options.amount,
      'Inbox bounced to a different recipient or amount',
    )
    return true
  }
  return false
}

/** Proves the exact callback return was minted, then leaves balance accounting to the caller. */
export async function waitForCallbackBounce(
  context: E2eZoneContext,
  options: {
    hash: Hex
    fallbackNonce: bigint
    token: Address
    amount: bigint
    recipient: Address
    fromBlock: bigint
  },
) {
  const client = context.zoneProofClient
  await waitFor(
    'the failed callback input to return privately',
    async () => {
      const logs = await client.getLogs({
        address: Addresses.zoneInbox,
        events: [
          getAbiItem({ abi: Abis.zoneInbox, name: 'WithdrawalBounceBackProcessed' }),
          getAbiItem({ abi: Abis.zoneInbox, name: 'WithdrawalBounceBackPending' }),
        ],
        fromBlock: options.fromBlock,
        toBlock: 'latest',
        strict: true,
      })
      for (const log of logs) {
        if (
          !isAddressEqual(log.args.zoneFallbackRecipient, options.recipient) ||
          !isAddressEqual(log.args.token, options.token) ||
          log.args.amount !== options.amount
        )
          continue
        const [transaction, receipt, previousHash] = await Promise.all([
          client.getTransaction({ hash: log.transactionHash }),
          client.getTransactionReceipt({ hash: log.transactionHash }),
          client.readContract({
            address: Addresses.zoneInbox,
            abi: Abis.zoneInbox,
            functionName: 'processedDepositQueueHash',
            blockNumber: log.blockNumber - 1n,
          }),
        ])
        assert(receipt.status === 'success', 'Inbox return receipt did not succeed')
        assert(transaction.input !== undefined, 'Inbox return transaction calldata is unavailable')
        if (
          processedCallbackBounce({
            ...options,
            input: transaction.input,
            previousHash,
            logs: [...receipt.logs],
          })
        )
          return true
      }
      return undefined
    },
    { intervalMs: context.pollingInterval },
  )
}
