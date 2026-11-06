import { describe, expect, it, vi } from 'vitest'
import {
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionData,
  getAbiItem,
  keccak256,
  parseAbiParameters,
  parseEventLogs,
  zeroHash,
  type Abi,
  type Address,
  type Hex,
  type Log,
} from 'viem'
import { Abis, Addresses } from 'viem/tempo'
import {
  assertRouterReceipt,
  callbackBounce,
  portalDeposit,
  portalDepositAbi,
  zoneDepositAbi,
  processedCallbackBounce,
  receiptBalanceChange,
  sourceWithdrawal,
  waitForDepositDelivery,
} from './delivery.js'

const token: Address = '0x20c0000000000000000000000000000000000001'
const sender: Address = '0x0000000000000000000000000000000000000001'
const recipient: Address = '0x0000000000000000000000000000000000000002'
const portal: Address = '0x0000000000000000000000000000000000000003'
const hash: Hex = `0x${'ab'.repeat(32)}`

function event(abi: Abi, name: string, address: Address, args: Record<string, unknown>): Log {
  const item = getAbiItem({ abi, name })
  if (!item || item.type !== 'event') throw new Error('Expected event ABI')
  const inputs = item.inputs.filter((input) => !input.indexed)
  return {
    address,
    topics: encodeEventTopics({ abi, eventName: name, args }) as [Hex, ...Hex[]],
    data: encodeAbiParameters(
      inputs,
      inputs.map((input) => args[input.name!]),
    ),
    blockHash: hash,
    blockNumber: 1n,
    transactionHash: hash,
    transactionIndex: 0,
    logIndex: 0,
    removed: false,
  }
}

function deposit(fee = 7n, name = 'DepositMade') {
  return event(portalDepositAbi, name, portal, {
    newCurrentDepositQueueHash: hash,
    sender,
    token,
    netAmount: 100n - fee,
    fee,
    keyIndex: 0n,
    ephemeralPubkeyX: zeroHash,
    ephemeralPubkeyYParity: 0,
    ciphertext: '0x',
    nonce: `0x${'00'.repeat(12)}`,
    tag: `0x${'00'.repeat(16)}`,
    tempoRefundRecipient: sender,
    depositNumber: 1n,
  })
}

describe('portalDeposit', () => {
  it('uses the actual nonzero receipt fee, not gross output or a balance credit', () => {
    expect(portalDeposit([deposit()], { portal, sender, token, gross: 100n, hash })).toEqual({
      hash,
      netAmount: 93n,
      fee: 7n,
    })
    expect(portalDeposit([deposit(0n)], { portal, sender, token, gross: 100n })).toEqual({
      hash,
      netAmount: 100n,
      fee: 0n,
    })
  })
  it('reads the existing encrypted-prefixed Portal event without changing fee semantics', () => {
    expect(
      portalDeposit([deposit(7n, 'EncryptedDepositMade')], { portal, sender, token, gross: 100n }),
    ).toEqual({ hash, netAmount: 93n, fee: 7n })
  })
  it('rejects uncorrelated, wrong-emitter, ambiguous and unaccounted returns', () => {
    expect(() =>
      portalDeposit([deposit()], { portal, sender, token, gross: 100n, hash: zeroHash }),
    ).toThrow('one attributable')
    expect(() =>
      portalDeposit([{ ...deposit(), address: recipient }], { portal, sender, token, gross: 100n }),
    ).toThrow('one attributable')
    expect(() =>
      portalDeposit([deposit(), deposit()], { portal, sender, token, gross: 100n }),
    ).toThrow('one attributable')
    expect(() => portalDeposit([deposit()], { portal, sender, token, gross: 101n })).toThrow(
      'account for the gross',
    )
  })
})

function request() {
  return event(Abis.zoneOutbox, 'WithdrawalRequested', Addresses.zoneOutbox, {
    withdrawalIndex: 1n,
    sender,
    token,
    to: portal,
    amount: 100n,
    fee: 3n,
    memo: zeroHash,
    gasLimit: 100n,
    fallbackNonce: 8n,
    data: '0x',
    revealTo: '0x',
  })
}

describe('sourceWithdrawal', () => {
  const options = { sender, to: portal, token, amount: 100n, data: '0x' as Hex, gasLimit: 100n }
  it('refuses the SDK pending receipt without a sender tag before any L1 polling', () => {
    expect(() =>
      sourceWithdrawal({ status: 'pending', transactionHash: hash, logs: [] }, options),
    ).toThrow('successful source receipt')
  })
  it('derives a bytes32 tag only from a unique successful source request', () => {
    const receipt = { status: 'success', transactionHash: hash, logs: [request()] }
    expect(sourceWithdrawal(receipt, options).senderTag).toMatch(/^0x[\da-f]{64}$/)
    expect(sourceWithdrawal(receipt, options).fee).toBe(3n)
    expect(() => sourceWithdrawal({ ...receipt, logs: [request(), request()] }, options)).toThrow(
      'exactly one',
    )
    expect(() => sourceWithdrawal(receipt, { ...options, sender: recipient })).toThrow(
      'exactly one',
    )
    expect(() => sourceWithdrawal(receipt, { ...options, data: '0x1234' })).toThrow('exactly one')
    expect(() => sourceWithdrawal(receipt, { ...options, gasLimit: 99n })).toThrow('exactly one')
  })
})

describe('receiptBalanceChange', () => {
  it('uses actual input and fee transfers without crediting a separate prefund', () => {
    const transfers = [
      event(Abis.tip20, 'Transfer', token, {
        from: sender,
        to: Addresses.zoneOutbox,
        amount: 103n,
      }),
      event(Abis.tip20, 'Transfer', token, { from: sender, to: recipient, amount: 2n }),
    ]
    expect(receiptBalanceChange(transfers, token, sender)).toBe(-105n)
    // A certified return of 100 leaves a five-unit fee loss, not the pre-funding baseline.
    expect(100n + receiptBalanceChange(transfers, token, sender)).toBe(-5n)
    expect(receiptBalanceChange(transfers, portal, sender)).toBe(0n)
  })
})

describe('callbackBounce', () => {
  it('does not accept another failed callback to the same recipient', () => {
    const log = event(Abis.zonePortal, 'WithdrawalBounceBack', portal, {
      newCurrentDepositQueueHash: hash,
      fallbackNonce: 8n,
      token,
      amount: 100n,
      depositNumber: 2n,
    })
    expect(callbackBounce([log], { portal, fallbackNonce: 8n, token, amount: 100n })).toBe(hash)
    expect(() => callbackBounce([log], { portal, fallbackNonce: 9n, token, amount: 100n })).toThrow(
      'unique queued',
    )
    expect(() => callbackBounce([log], { portal, fallbackNonce: 8n, token, amount: 99n })).toThrow(
      'withdrawn input',
    )
  })
})

describe('processedCallbackBounce', () => {
  const payload = parseAbiParameters('(address token, address to, uint128 amount)')
  const value = { token, to: '0x0000000000000000000000000000000000000008' as Address, amount: 100n }
  const data = encodeAbiParameters(payload, [value])
  const bounceHash = keccak256(
    encodeAbiParameters([{ type: 'uint8' }, payload[0], { type: 'bytes32' }], [0, value, zeroHash]),
  )
  const input = encodeFunctionData({
    abi: Abis.zoneInbox,
    functionName: 'advanceTempo',
    args: ['0x', [{ depositType: 0, depositData: data, rejected: false }], [], []],
  })
  const log = event(Abis.zoneInbox, 'WithdrawalBounceBackProcessed', Addresses.zoneInbox, {
    zoneFallbackRecipient: recipient,
    token,
    amount: 100n,
  })
  const options = {
    input,
    previousHash: zeroHash,
    logs: [log],
    hash: bounceHash,
    fallbackNonce: 8n,
    token,
    amount: 100n,
    recipient,
  }
  it('requires the exact queue hash and input nonce even for matching token and amount', () => {
    expect(processedCallbackBounce(options)).toBe(true)
    expect(processedCallbackBounce({ ...options, hash })).toBe(false)
    expect(() => processedCallbackBounce({ ...options, fallbackNonce: 9n })).toThrow(
      'does not match',
    )
    expect(() => processedCallbackBounce({ ...options, recipient: sender })).toThrow(
      'different recipient',
    )
  })
  it('keeps dynamic deposit offsets when a regular deposit precedes the callback bounce', () => {
    const regular = parseAbiParameters(
      '(address token, address sender, uint128 amount, address tempoRefundRecipient, uint256 keyIndex, (bytes32 ephemeralPubkeyX, uint8 ephemeralPubkeyYParity, bytes ciphertext, bytes12 nonce, bytes16 tag) encrypted)',
    )
    const userDeposit = {
      token,
      sender,
      amount: 9n,
      tempoRefundRecipient: sender,
      keyIndex: 0n,
      encrypted: {
        ephemeralPubkeyX: zeroHash,
        ephemeralPubkeyYParity: 0,
        ciphertext: '0x123456' as Hex,
        nonce: `0x${'00'.repeat(12)}` as Hex,
        tag: `0x${'00'.repeat(16)}` as Hex,
      },
    }
    const regularHash = keccak256(
      encodeAbiParameters(
        [{ type: 'uint8' }, regular[0], { type: 'bytes32' }],
        [1, userDeposit, zeroHash],
      ),
    )
    const finalHash = keccak256(
      encodeAbiParameters(
        [{ type: 'uint8' }, payload[0], { type: 'bytes32' }],
        [0, value, regularHash],
      ),
    )
    const mixedInput = encodeFunctionData({
      abi: Abis.zoneInbox,
      functionName: 'advanceTempo',
      args: [
        '0x',
        [
          {
            depositType: 1,
            depositData: encodeAbiParameters(regular, [userDeposit]),
            rejected: false,
          },
          { depositType: 0, depositData: data, rejected: false },
        ],
        [],
        [],
      ],
    })
    const regularLog = event(Abis.zoneInbox, 'DepositProcessed', Addresses.zoneInbox, {
      depositHash: regularHash,
      sender,
      to: recipient,
      token,
      amount: 9n,
      memo: zeroHash,
    })
    expect(
      processedCallbackBounce({
        ...options,
        input: mixedInput,
        hash: finalHash,
        logs: [regularLog, log],
      }),
    ).toBe(true)
  })
  it('rejects a pending return instead of counting other private credit', () => {
    const pending = event(Abis.zoneInbox, 'WithdrawalBounceBackPending', Addresses.zoneInbox, {
      zoneFallbackRecipient: recipient,
      token,
      amount: 100n,
    })
    expect(() => processedCallbackBounce({ ...options, logs: [pending] })).toThrow(
      'pending instead of delivered',
    )
  })
})

describe('waitForDepositDelivery', () => {
  const options = { hash, token, sender, recipient, amount: 93n, fromBlock: 1n }
  const delivered = event(Abis.zoneInbox, 'DepositProcessed', Addresses.zoneInbox, {
    depositHash: hash,
    sender,
    to: recipient,
    token,
    amount: 93n,
    memo: zeroHash,
  })
  function context(logs: readonly Log[]) {
    const decoded = parseEventLogs({ abi: zoneDepositAbi, logs: [...logs], strict: true })
    return {
      pollingInterval: 60_000,
      zoneProofClient: { getLogs: async () => decoded },
    } as never
  }
  it('requires this exact processing hash even if unrelated credit exists', async () => {
    vi.useFakeTimers()
    try {
      const unrelated = event(Abis.zoneInbox, 'DepositProcessed', Addresses.zoneInbox, {
        depositHash: zeroHash,
        sender,
        to: recipient,
        token,
        amount: 93n,
        memo: zeroHash,
      })
      const assertion = expect(
        waitForDepositDelivery(context([unrelated]), options),
      ).rejects.toThrow('Timed out')
      await vi.advanceTimersByTimeAsync(180_000)
      await assertion
    } finally {
      vi.useRealTimers()
    }
  })
  it('accepts the matching legacy encrypted processing event', async () => {
    const legacy = event(zoneDepositAbi, 'EncryptedDepositProcessed', Addresses.zoneInbox, {
      depositHash: hash,
      sender,
      to: recipient,
      token,
      amount: 93n,
      memo: zeroHash,
    })
    await expect(waitForDepositDelivery(context([legacy]), options)).resolves.toHaveProperty(
      'eventName',
      'EncryptedDepositProcessed',
    )
  })
  it('accepts certified fee-net delivery but rejects partial output and failed processing', async () => {
    await expect(waitForDepositDelivery(context([delivered]), options)).resolves.toHaveProperty(
      'eventName',
      'DepositProcessed',
    )
    await expect(
      waitForDepositDelivery(context([delivered]), { ...options, amount: 100n }),
    ).rejects.toThrow('does not match')
    const failed = event(Abis.zoneInbox, 'DepositFailed', Addresses.zoneInbox, {
      depositHash: hash,
      sender,
      token,
      amount: 93n,
    })
    await expect(waitForDepositDelivery(context([failed]), options)).rejects.toThrow(
      'failed or was rejected',
    )
  })
})

describe('assertRouterReceipt', () => {
  it('does not let a separate donation disguise an operation deficit', () => {
    const deficit = event(Abis.tip20, 'Transfer', token, {
      from: portal,
      to: recipient,
      amount: 1n,
    })
    expect(() => assertRouterReceipt([deficit], [token], portal)).toThrow(
      'restore its token custody',
    )
    const incoming = event(Abis.tip20, 'Transfer', token, {
      from: sender,
      to: portal,
      amount: 100n,
    })
    const outgoing = event(Abis.tip20, 'Transfer', token, {
      from: portal,
      to: recipient,
      amount: 100n,
    })
    expect(() => assertRouterReceipt([incoming, outgoing], [token], portal)).not.toThrow()
  })
})
