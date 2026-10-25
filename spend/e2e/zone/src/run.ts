// Card spend on a real Tempo L1 and a real Tempo Zone, against a target (targets.ts):
//
//   pnpm zone                       local: a disposable L1 and Zone in Docker
//   pnpm zone:moderato              Moderato and its hosted Zone 3, with the recorded program
//   pnpm zone:moderato --deploy     deploys that program first and records it
//   pnpm zone:moderato --admit      grants the receiver and cardholder the Portal roles they lack,
//                                   with ZONE_ADMIN_PRIVATE_KEY
//
// 1. Prepares the target: its L1, its Zone, and a Bridge card program with the "TS" handler and a
//    ZoneSpendReceiver (script/ZoneE2EDeploy.s.sol). The local target then requires
//    script/deploy/Preflight.s.sol to report no todo.
// 2. The cardholder moves pathUSD into the Zone with an encrypted deposit and authorizes Bridge's
//    access key, scoped to an approval of the outbox and the outbox's requestWithdrawal.
// 3. Bridge requests the withdrawal with its Zone access key. The Zone batches it to the L1, where
//    the portal calls the receiver, which settles the spend through Bridge's spender clone.
// 4. Checks: a Zone token transfer reverts, the settlement wallet is paid on the L1, no L1 log of
//    the settlement names the cardholder, the cardholder's private balance ends exactly the spend
//    and fees lower once any change is back, and a spend to an address outside the program bounces
//    back into the Zone in full. On a disposable Zone it also shows the outbox-scoped key
//    withdrawing to an address outside the program, an accepted risk.
// 5. Where the target has a Tempo Earn vault (Moderato), spends from Earn shares in the Zone: the
//    cardholder deposits into the vault and moves the EarnShare into the Zone, Bridge withdraws
//    shares to the receiver, and the handler redeems exactly the spend for the settlement wallet.
//    Checks: the settlement wallet is paid in the vault's asset, the shares spent stay within
//    Bridge's quote, the unused shares come back to the Zone, and no L1 log names the cardholder.
// 6. Times the card-approval path: Zone request to Zone receipt (what Bridge waits for before it
//    approves), Zone receipt to L1 settlement (after approval), and a public spend's one L1
//    transaction, signed with Bridge's L1 access key. Writes them to
//    reports/zone-e2e-latency-<target>.json.
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  BaseError,
  concat,
  ContractFunctionRevertedError,
  encodeAbiParameters,
  encodePacked,
  encodeFunctionData,
  erc20Abi,
  formatUnits,
  isAddressEqual,
  keccak256,
  parseAbi,
  parseAbiParameters,
  parseEventLogs,
  toFunctionSelector,
  toHex,
  zeroAddress,
  zeroHash,
  type Abi,
  type Address,
  type Hex,
  type Log,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { Account, Actions } from 'viem/tempo'

import * as Network from './network.js'
import { forgeEnv, hosted, local, portalAbi, root, sendL1Sync, type EarnTarget, type Prepared } from './targets.js'

const CALLBACK_GAS = 3_000_000n
const DEPOSIT = 100_000_000n // 100 pathUSD
const SPEND = 20_000_000n // 20 pathUSD
const pathUsd = Network.address.pathUsd
const outbox = Network.address.zoneOutbox
// Public spends timed on the L1. One is not a sample.
const PUBLIC_SPENDS = 5
/** Exit code when the private steps could not run because the Zone lacks a role grant. */
const EXIT_BLOCKED = 3

const outboxAbi = parseAbi([
  'function calculateWithdrawalFee(uint64 gasLimit) view returns (uint128)',
  'function requestWithdrawal(address token, address to, uint128 amount, bytes32 memo, uint64 gasLimit, address fallbackRecipient, bytes data, bytes revealTo)',
  'event WithdrawalRequested(uint64 indexed withdrawalIndex, address indexed sender, address token, address to, uint128 amount, uint128 fee, bytes32 memo, uint64 gasLimit, uint64 fallbackNonce, bytes data, bytes revealTo)',
])
const portalEventsAbi = parseAbi([
  'event WithdrawalProcessed(address indexed to, bytes32 indexed senderTag, address token, uint128 amount, bool callbackSuccess)',
])
const zoneTokenAbi = parseAbi(['function transfer(address to, uint256 amount) returns (bool)', 'error Unauthorized()'])
const spendType = parseAbiParameters([
  'Spend spend',
  'struct Spend { bytes32 spenderId; address token; uint256 amount; address destination; address vault; uint256 fromVault; uint256 maxShares; bytes32 ref; }',
])
const cloneAbi = parseAbi(['function publicCall(bytes data)'])
const callbackType = parseAbiParameters([
  'Spend spend, ZoneReturn ret',
  'struct Spend { bytes32 spenderId; address token; uint256 amount; address destination; address vault; uint256 fromVault; uint256 maxShares; bytes32 ref; }',
  'struct ZoneReturn { uint256 keyIndex; DepositPayload encrypted; address refundRecipient; uint128 maxDepositFee; }',
  'struct DepositPayload { bytes32 ephemeralPubkeyX; uint8 ephemeralPubkeyYParity; bytes ciphertext; bytes12 nonce; bytes16 tag; }',
])

function artifact(name: string) {
  const json = JSON.parse(readFileSync(resolve(root, `out/${name}.sol/${name}.json`), 'utf8'))
  return { abi: json.abi as Abi, bytecode: json.bytecode.object as Hex }
}

type CallFrame = { to?: string; input?: string; gas?: Hex; gasUsed?: Hex; calls?: CallFrame[] }

/** The first call frame in `frame`'s tree to `to` with `selector`, depth first. */
function findCall(frame: CallFrame, to: Address, selector: Hex): CallFrame | undefined {
  if (frame.to?.toLowerCase() === to.toLowerCase() && frame.input?.startsWith(selector)) return frame
  for (const child of frame.calls ?? []) {
    const found = findCall(child, to, selector)
    if (found) return found
  }
  return undefined
}

function step(n: number, text: string) {
  console.log(`[${n}] ${text}`)
}

async function waitFor<T>(
  label: string,
  read: () => Promise<T>,
  done: (value: T) => boolean,
  intervalMs = 1000,
) {
  const deadline = Date.now() + 240_000
  for (;;) {
    const value = await read()
    if (done(value)) return value
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${label} (last read ${String(value)})`)
    await new Promise((r) => setTimeout(r, intervalMs))
  }
}

/** Wall-clock milliseconds since `start`, from `performance.now()`. */
function since(start: number) {
  return Math.round(performance.now() - start)
}

function median(values: number[]) {
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor(sorted.length / 2)]!
}

/** Whether `logs` hold a `token` transfer of exactly `SPEND` to `destination`. */
function paid(logs: readonly Log[], destination: Address, token: Address = pathUsd) {
  return parseEventLogs({ abi: erc20Abi, eventName: 'Transfer', logs: [...logs] }).some(
    (log) => isAddressEqual(log.address, token) && isAddressEqual(log.args.to, destination) && log.args.value === SPEND,
  )
}

/** Whether any of `logs` carries `address` in its topics or data. */
function names(logs: readonly Log[], address: Address) {
  const needle = address.slice(2).toLowerCase()
  return logs.some((log) => log.data.toLowerCase().includes(needle) || log.topics.some((topic) => topic?.toLowerCase().includes(needle)))
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(`check failed: ${message}`)
}

/**
 * The revert data of a failed call: as viem decoded it, or as the Zone RPC quotes it in the message
 * of the internal error it wraps reverts in.
 */
function revertData(error: unknown): Hex | undefined {
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
function withdrawalRequested(receipt: { logs: Log[]; transactionHash: Hex }) {
  const logs = receipt.logs.filter((log) => isAddressEqual(log.address, outbox))
  const [event] = parseEventLogs({ abi: outboxAbi, eventName: 'WithdrawalRequested', logs })
  assert(event, 'the Zone receipt carries the outbox WithdrawalRequested event')
  const senderTag = keccak256(
    encodePacked(['address', 'bytes32', 'uint64'], [event.args.sender, receipt.transactionHash, event.args.fallbackNonce]),
  )
  return { ...event.args, senderTag }
}

/** Steps 5 to 12: a private spend, a bounce, and (on a disposable Zone) the leaked-key withdrawal. */
async function privateSpend(t: Prepared, run: string) {
  const receiverArtifact = artifact('ZoneSpendReceiver')
  const { cardholder, program, refundRecipient } = t
  const l1Public = t.l1Public
  const bridgeKeyPk = generatePrivateKey()
  const bridgeKey = privateKeyToAccount(bridgeKeyPk)
  const ref = (label: string) => keccak256(toHex(`zone-e2e.${run}.${label}`))

  // Encrypted deposit: the cardholder's spending balance.
  const userZone = await t.zoneClient(cardholder)
  const balance = () =>
    userZone.readContract({ address: pathUsd, abi: erc20Abi, functionName: 'balanceOf', args: [cardholder.address] })
  /** The balance as of a Zone block, such as the one holding a request, before any return lands. */
  const balanceAt = (blockNumber: bigint) =>
    userZone.readContract({ address: pathUsd, abi: erc20Abi, functionName: 'balanceOf', args: [cardholder.address], blockNumber })
  const startBalance = await balance()
  // The portal credits the deposit net of its fee.
  const depositFee = await l1Public.readContract({ address: t.zone.portal, abi: portalAbi, functionName: 'calculateDepositFee' })
  // Sent, then awaited: a synchronous send can outlast the public RPC proxy's 1 s limit.
  const depositHash = await t.l1Wallet(cardholder).zone.encryptedDeposit({
    amount: DEPOSIT,
    portalAddress: t.zone.portal,
    recipient: cardholder.address,
    token: pathUsd,
    zoneId: t.zone.id,
  })
  const deposit = await l1Public.waitForTransactionReceipt({ hash: depositHash, timeout: 180_000 })
  assert(deposit.status === 'success', 'the encrypted deposit succeeded')
  await Actions.zone.waitForTempoBlock(userZone, {
    pollingInterval: 500,
    tempoBlockNumber: deposit.blockNumber,
    timeout: 180_000,
  })
  await waitFor('encrypted deposit', balance, (v) => v - startBalance >= DEPOSIT - depositFee, 500)

  // Simulated, so nothing is sent: funds leave a Zone only by withdrawal (decision 8).
  const transferError = await userZone
    .simulateContract({ account: cardholder, address: pathUsd, abi: zoneTokenAbi, functionName: 'transfer', args: [program.settlement, 1n] })
    .then(() => undefined, (error: unknown) => error)
  assert(
    revertData(transferError) === toFunctionSelector('Unauthorized()'),
    `a Zone pathUSD transfer reverts with Unauthorized() (got ${transferError === undefined ? 'success' : String(transferError)})`,
  )
  step(5, `Cardholder deposited ${formatUnits(DEPOSIT, 6)} pathUSD privately into the Zone (fee ${formatUnits(depositFee, 6)}), and a Zone pathUSD transfer reverts with Unauthorized() in simulation: Zone funds leave only by withdrawal`)

  const userZoneReceipts = await t.zoneClient(cardholder, true)
  await userZoneReceipts.accessKey.authorizeSync({
    accessKey: { accessKeyAddress: bridgeKey.address, keyType: 'secp256k1' },
    expiry: Math.floor(Date.now() / 1000) + 86_400,
    limits: [{ token: pathUsd, limit: 100_000_000n, period: 30 * 86_400 }],
    scopes: [
      { address: pathUsd, selector: 'approve(address,uint256)', recipients: [outbox] },
      {
        address: outbox,
        selector: 'requestWithdrawal(address,address,uint128,bytes32,uint64,address,bytes,bytes)',
      },
    ],
    feeToken: pathUsd,
  })
  step(6, 'Cardholder authorized Bridge access key: 100 pathUSD per 30 days, outbox only')

  const [accessEnforced, bouncebackFee] = await Promise.all([
    l1Public.readContract({ address: t.zone.portal, abi: portalAbi, functionName: 'isAccessEnforced' }),
    l1Public.readContract({ address: t.zone.portal, abi: portalAbi, functionName: 'calculateBouncebackFee' }),
  ])
  const withdrawalFee = await userZone.readContract({
    address: outbox,
    abi: outboxAbi,
    functionName: 'calculateWithdrawalFee',
    args: [CALLBACK_GAS],
  })
  const change = accessEnforced ? depositFee + bouncebackFee + 1n : 0n

  async function callback(spendRef: Hex, destination: Address) {
    const recipient = await Actions.zone.encryptedDeposit.prepareRecipient(l1Public, {
      recipient: cardholder.address,
      sender: program.receiver,
      portalAddress: t.zone.portal,
      zoneId: t.zone.id,
    })
    const spend = {
      spenderId: program.spenderId,
      token: pathUsd,
      amount: SPEND,
      destination,
      vault: zeroAddress,
      fromVault: 0n,
      maxShares: 0n,
      ref: spendRef,
    }
    const zoneReturn = {
      keyIndex: recipient.keyIndex,
      encrypted: {
        ephemeralPubkeyX: recipient.encrypted.ephemeralPubkeyX,
        ephemeralPubkeyYParity: recipient.encrypted.ephemeralPubkeyYParity,
        ciphertext: recipient.encrypted.ciphertext,
        nonce: recipient.encrypted.nonce,
        tag: recipient.encrypted.tag,
      },
      refundRecipient,
      // The change already covers this fee, so a higher one at processing time bounces the spend.
      maxDepositFee: depositFee,
    }
    return encodeAbiParameters(callbackType, [spend, zoneReturn])
  }

  const bridgeZone = await t.zoneClient(Account.fromSecp256k1(bridgeKeyPk, { access: cardholder.address }), true)
  async function requestWithdrawal(to: Address, amount: bigint, callbackData: Hex, gas = CALLBACK_GAS) {
    const fee = gas === CALLBACK_GAS ? withdrawalFee : await userZone.readContract({
      address: outbox,
      abi: outboxAbi,
      functionName: 'calculateWithdrawalFee',
      args: [gas],
    })
    return bridgeZone.sendTransactionSync({
      calls: [
        {
          to: pathUsd,
          data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [outbox, amount + fee] }),
        },
        {
          to: outbox,
          data: encodeFunctionData({
            abi: outboxAbi,
            functionName: 'requestWithdrawal',
            args: [pathUsd, to, amount, zeroHash, gas, cardholder.address, callbackData, '0x'],
          }),
        },
      ],
      feeToken: pathUsd,
    })
  }
  const requestSpend = (callbackData: Hex) => requestWithdrawal(program.receiver, SPEND + change, callbackData)

  // Settlement checks key on this run's `ref` and its own receipts, not the shared settlement
  // wallet's balance, so overlapping runs against one program do not trip each other.
  const settledEvents = (spendRef: Hex, fromBlock: bigint) =>
    l1Public.getContractEvents({
      address: program.receiver,
      abi: receiverArtifact.abi,
      eventName: 'PrivateSpendSettled',
      args: { ref: spendRef },
      fromBlock,
    })
  const zoneBefore = await balance()
  const fromBlock = await l1Public.getBlockNumber()
  const spendRef = ref('auth.1')
  const callbackData = await callback(spendRef, program.settlement)
  const requested = performance.now()
  const spend = await requestSpend(callbackData)
  const zoneReceiptMs = since(requested)
  const zoneAccepted = performance.now()
  assert(spend.status === 'success', 'Bridge access key requested the spend')
  step(7, `Bridge requested a ${formatUnits(SPEND, 6)} pathUSD private spend, ${(callbackData.length - 2) / 2}-byte callback (Zone tx ${spend.transactionHash})`)

  const events = await waitFor('settlement on L1', () => settledEvents(spendRef, fromBlock), (found) => found.length > 0, 100)
  const l1SettlementMs = since(zoneAccepted)
  assert(events.length === 1, 'one PrivateSpendSettled event for the spend')
  const settlementReceipt = await l1Public.getTransactionReceipt({ hash: events[0]!.transactionHash })
  assert(paid(settlementReceipt.logs, program.settlement), 'the settlement transaction paid the settlement wallet')
  step(8, 'Settlement wallet paid on the L1')
  console.log(
    `    latency: Zone request to Zone receipt ${zoneReceiptMs} ms, Zone receipt to L1 settlement ${l1SettlementMs} ms`,
  )

  const needle = cardholder.address.slice(2).toLowerCase()
  const leaked = settlementReceipt.logs.some(
    (log) => log.data.toLowerCase().includes(needle) || log.topics.some((topic) => topic?.toLowerCase().includes(needle)),
  )
  assert(!leaked, 'no L1 log of the settlement names the cardholder')
  step(9, `No L1 log in the settlement transaction (${settlementReceipt.logs.length} logs) names the cardholder`)

  if (t.l1.tracesCalls) {
    const trace = (await l1Public.request({
      method: 'debug_traceTransaction',
      params: [settlementReceipt.transactionHash, { tracer: 'callTracer' }],
    } as never)) as CallFrame
    const onWithdrawal = toFunctionSelector('onWithdrawalReceived(uint32,address,bytes32,address,uint128,bytes)')
    const callbackFrame = findCall(trace, program.receiver, onWithdrawal)
    assert(callbackFrame?.gasUsed !== undefined, 'settlement trace contains the receiver callback')
    console.log(
      `    receiver callback used ${BigInt(callbackFrame.gasUsed)} gas (limit ${CALLBACK_GAS}, settlement tx ${settlementReceipt.gasUsed})`,
    )
  }

  assert(withdrawalRequested(spend).fee === withdrawalFee, 'the outbox charged the quoted withdrawal fee')
  // What the request's own block left short of its amount and fee is the Zone transaction's fee.
  const spendTxFee = zoneBefore - SPEND - change - withdrawalFee - (await balanceAt(spend.blockNumber))
  assert(spendTxFee >= 0n, 'the request took no more than its amount, withdrawal fee and transaction fee')
  // The receiver deposits the change back, which the portal credits net of its deposit fee.
  const expectedAfterSpend = zoneBefore - SPEND - withdrawalFee - spendTxFee - (change > 0n ? depositFee : 0n)
  const zoneAfter = await waitFor('the Zone balance after the spend and its change', balance, (v) => v === expectedAfterSpend)
  step(
    10,
    `Private balance down exactly ${formatUnits(zoneBefore - zoneAfter, 6)} pathUSD: spend ${formatUnits(SPEND, 6)}, withdrawal fee ${formatUnits(withdrawalFee, 6)}, ` +
      `${change > 0n ? `change back less its deposit fee ${formatUnits(depositFee, 6)}` : 'no change sent'}, Zone transaction fee ${formatUnits(spendTxFee, 6)}`,
  )

  const zoneBeforeBounce = zoneAfter
  const stranger = privateKeyToAccount(generatePrivateKey()).address
  const bounceFrom = await l1Public.getBlockNumber()
  const bounceRef = ref('auth.2')
  const outside = await requestSpend(await callback(bounceRef, stranger))
  assert(outside.status === 'success', 'spend outside the program requested in the Zone')
  const bounceRequest = withdrawalRequested(outside)
  const bounceTxFee = zoneBeforeBounce - SPEND - change - withdrawalFee - (await balanceAt(outside.blockNumber))
  const [processed] = await waitFor(
    'the portal processing the spend outside the program',
    () =>
      l1Public.getContractEvents({
        address: t.zone.portal,
        abi: portalEventsAbi,
        eventName: 'WithdrawalProcessed',
        args: { to: program.receiver, senderTag: bounceRequest.senderTag },
        fromBlock: bounceFrom,
      }),
    (found) => found.length > 0,
    250,
  )
  assert(processed!.args.callbackSuccess === false, 'the receiver rejected the spend outside the program')
  assert(processed!.args.amount === SPEND + change, 'the portal processed the whole withdrawal')
  // The portal bounces the whole withdrawal back, so the cardholder is out only the fees.
  await waitFor('the bounce back in the Zone', balance, (v) => v === zoneBeforeBounce - withdrawalFee - bounceTxFee)
  assert((await settledEvents(bounceRef, bounceFrom)).length === 0, 'spend outside the program settled nothing on L1')
  const strangerPaid = await l1Public.readContract({ address: pathUsd, abi: erc20Abi, functionName: 'balanceOf', args: [stranger] })
  assert(strangerPaid === 0n, 'the outside destination received nothing')
  step(11, `Spend to an address outside the program bounced (callback failed on the L1): nothing paid, all ${formatUnits(SPEND + change, 6)} pathUSD back in the Zone`)

  // Only on a disposable Zone: a hosted Zone would need an admitted outside account to receive it.
  if (t.disposable) {
    const outsider = privateKeyToAccount(generatePrivateKey()).address
    const leak = await requestWithdrawal(outsider, 1_000_000n, '0x', 0n)
    assert(leak.status === 'success', 'outbox-scoped key withdrew outside the program')
    await waitFor('withdrawal to an outside address', () =>
      l1Public.readContract({ address: pathUsd, abi: erc20Abi, functionName: 'balanceOf', args: [outsider] }),
      (v) => v === 1_000_000n,
    )
    step(12, 'Accepted risk: the outbox-scoped Bridge key also withdrew 1 pathUSD to an address outside the program')
  }

  return { zoneReceiptMs, l1SettlementMs }
}

const earnVaultAbi = parseAbi([
  'function deposit(uint256 assets, address receiver, uint256 minEarnShares) returns (uint256)',
  'function previewWithdraw(uint256 assets) view returns (uint256)',
])
const funderAbi = parseAbi(['function fund(address token, address receiver, uint256 amount)'])
// Bridge quotes an Earn spend at the live share cost plus this tolerance.
const SHARE_TOLERANCE_BPS = 50n

/**
 * Steps 13 to 16: a private spend from Earn shares. Bridge's Zone key withdraws EarnShare to the
 * receiver, and the handler redeems exactly the spend from the vault for the settlement wallet.
 */
async function earnSpend(t: Prepared, run: string, earn: EarnTarget) {
  const receiverArtifact = artifact('ZoneSpendReceiver')
  const { cardholder, program, refundRecipient } = t
  const l1Public = t.l1Public
  const userL1 = t.l1Wallet(cardholder)
  // Moderato's gateway can drop a synchronous send that waits for its block, so send, then wait.
  const write = async (request: object) => {
    const hash = await userL1.writeContract({ ...request, feeToken: pathUsd } as never)
    const receipt = await l1Public.waitForTransactionReceipt({ hash, timeout: 180_000 })
    assert(receipt.status === 'success', `L1 transaction ${hash} succeeded`)
  }
  const userZone = await t.zoneClient(cardholder)
  const shares = () =>
    userZone.readContract({ address: earn.earnShare, abi: erc20Abi, functionName: 'balanceOf', args: [cardholder.address] })

  // The cardholder's Earn position, moved into the Zone like any private balance.
  const assets = 2n * SPEND
  await write({ address: earn.funder, abi: funderAbi, functionName: 'fund', args: [earn.asset, cardholder.address, assets] })
  await write({ address: earn.asset, abi: erc20Abi, functionName: 'approve', args: [earn.vault, assets] })
  const l1Shares = () =>
    l1Public.readContract({ address: earn.earnShare, abi: erc20Abi, functionName: 'balanceOf', args: [cardholder.address] })
  const l1SharesBefore = await l1Shares()
  await write({ address: earn.vault, abi: earnVaultAbi, functionName: 'deposit', args: [assets, cardholder.address, 1n] })
  const minted = (await l1Shares()) - l1SharesBefore
  assert(minted > 0n, 'the Earn deposit minted EarnShare')
  const sharesBefore = await shares()
  const depositFee = await l1Public.readContract({ address: t.zone.portal, abi: portalAbi, functionName: 'calculateDepositFee' })
  await write({ address: earn.earnShare, abi: erc20Abi, functionName: 'approve', args: [t.zone.portal, minted] })
  const depositHash = await userL1.zone.encryptedDeposit({
    amount: minted,
    portalAddress: t.zone.portal,
    recipient: cardholder.address,
    token: earn.earnShare,
    zoneId: t.zone.id,
  })
  const deposit = await l1Public.waitForTransactionReceipt({ hash: depositHash, timeout: 180_000 })
  assert(deposit.status === 'success', 'the EarnShare deposit into the Zone succeeded')
  await Actions.zone.waitForTempoBlock(userZone, { pollingInterval: 500, tempoBlockNumber: deposit.blockNumber, timeout: 180_000 })
  await waitFor('EarnShare deposit', shares, (v) => v - sharesBefore >= minted - depositFee, 500)
  step(13, `Cardholder deposited ${formatUnits(assets, 6)} of the vault asset into Earn and moved ${formatUnits(minted, 6)} EarnShare privately into the Zone`)

  const bridgeKeyPk = generatePrivateKey()
  const bridgeKey = privateKeyToAccount(bridgeKeyPk)
  const userZoneReceipts = await t.zoneClient(cardholder, true)
  await userZoneReceipts.accessKey.authorizeSync({
    accessKey: { accessKeyAddress: bridgeKey.address, keyType: 'secp256k1' },
    expiry: Math.floor(Date.now() / 1000) + 86_400,
    limits: [{ token: earn.earnShare, limit: minted, period: 30 * 86_400 }],
    scopes: [
      { address: earn.earnShare, selector: 'approve(address,uint256)', recipients: [outbox] },
      { address: outbox, selector: 'requestWithdrawal(address,address,uint128,bytes32,uint64,address,bytes,bytes)' },
    ],
    feeToken: pathUsd,
  })
  step(14, `Cardholder authorized a Bridge Zone key for EarnShare: ${formatUnits(minted, 6)} per 30 days, outbox only`)

  const [bouncebackFee, live] = await Promise.all([
    l1Public.readContract({ address: t.zone.portal, abi: portalAbi, functionName: 'calculateBouncebackFee' }),
    l1Public.readContract({ address: earn.vault, abi: earnVaultAbi, functionName: 'previewWithdraw', args: [SPEND] }),
  ])
  const maxShares = live + (live * SHARE_TOLERANCE_BPS) / 10_000n + 1n
  // An Earn spend always returns leftover shares, and the portal rejects a deposit below its fees,
  // so the change covers them on every portal, not only an access-enforced one.
  const change = depositFee + bouncebackFee + 1n
  const input = maxShares + change
  const withdrawalFee = await userZone.readContract({ address: outbox, abi: outboxAbi, functionName: 'calculateWithdrawalFee', args: [CALLBACK_GAS] })
  const recipient = await Actions.zone.encryptedDeposit.prepareRecipient(l1Public, {
    recipient: cardholder.address,
    sender: program.receiver,
    portalAddress: t.zone.portal,
    zoneId: t.zone.id,
  })
  const spendRef = keccak256(toHex(`zone-e2e.${run}.earn`))
  const callbackData = encodeAbiParameters(callbackType, [
    {
      spenderId: program.spenderId,
      token: earn.asset,
      amount: SPEND,
      destination: program.settlement,
      vault: earn.vault,
      fromVault: SPEND,
      maxShares,
      ref: spendRef,
    },
    {
      keyIndex: recipient.keyIndex,
      encrypted: {
        ephemeralPubkeyX: recipient.encrypted.ephemeralPubkeyX,
        ephemeralPubkeyYParity: recipient.encrypted.ephemeralPubkeyYParity,
        ciphertext: recipient.encrypted.ciphertext,
        nonce: recipient.encrypted.nonce,
        tag: recipient.encrypted.tag,
      },
      refundRecipient,
      maxDepositFee: depositFee,
    },
  ])
  const bridgeZone = await t.zoneClient(Account.fromSecp256k1(bridgeKeyPk, { access: cardholder.address }), true)
  const zoneBefore = await shares()
  const fromBlock = await l1Public.getBlockNumber()
  const requested = performance.now()
  const request = await bridgeZone.sendTransactionSync({
    calls: [
      { to: earn.earnShare, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [outbox, input + withdrawalFee] }) },
      {
        to: outbox,
        data: encodeFunctionData({
          abi: outboxAbi,
          functionName: 'requestWithdrawal',
          args: [earn.earnShare, program.receiver, input, zeroHash, CALLBACK_GAS, cardholder.address, callbackData, '0x'],
        }),
      },
    ],
    feeToken: pathUsd,
  })
  const zoneReceiptMs = since(requested)
  assert(request.status === 'success', 'Bridge Zone key requested the Earn spend')
  step(15, `Bridge requested a ${formatUnits(SPEND, 6)} spend from Earn, up to ${formatUnits(maxShares, 6)} EarnShare (Zone tx ${request.transactionHash}, ${zoneReceiptMs} ms to receipt)`)

  const events = await waitFor(
    'Earn settlement on L1',
    () => l1Public.getContractEvents({ address: program.receiver, abi: receiverArtifact.abi, eventName: 'PrivateSpendSettled', args: { ref: spendRef }, fromBlock }),
    (found) => found.length > 0,
    250,
  )
  const settlement = await l1Public.getTransactionReceipt({ hash: events[0]!.transactionHash })
  assert(paid(settlement.logs, program.settlement, earn.asset), 'the settlement wallet received the vault asset')
  assert(!names(settlement.logs, cardholder.address), 'no L1 log of the settlement names the cardholder')
  const settled = events[0]!.args as { inputConsumed: bigint; inputReturned: bigint }
  assert(settled.inputConsumed <= maxShares, "the handler burned no more shares than Bridge's quote")
  const after = await waitFor('EarnShare change back in the Zone', shares, (v) => v > zoneBefore - input - withdrawalFee)
  const spent = zoneBefore - after
  assert(spent <= settled.inputConsumed + withdrawalFee + depositFee, 'the Zone balance paid only the burned shares and fees')
  step(16, `Settlement wallet paid ${formatUnits(SPEND, 6)} in the vault asset, ${formatUnits(spent, 6)} EarnShare spent including fees, the rest back in the Zone, no L1 log names the cardholder`)
}

/** Room in the public key's pathUSD limit for the fees its spends pay in pathUSD. */
const PUBLIC_FEE_BUDGET = 10_000_000n

/**
 * Step 17: public spends, each one L1 transaction from the cardholder's account that approves the
 * exact amount to the clone, spends, and clears the approval, signed with a Bridge access key the
 * cardholder scoped to those two calls.
 */
async function publicSpend(t: Prepared, run: string) {
  const { cardholder, program } = t
  const l1Public = t.l1Public
  const bridgeKeyPk = generatePrivateKey()
  const bridgeKey = privateKeyToAccount(bridgeKeyPk).address
  const limit = BigInt(PUBLIC_SPENDS) * SPEND + PUBLIC_FEE_BUDGET
  // Sent, then awaited: a synchronous send can outlast the public RPC proxy's 1 s limit.
  const authorized = await t.l1Wallet(cardholder).accessKey.authorize({
    accessKey: { accessKeyAddress: bridgeKey, keyType: 'secp256k1' },
    expiry: Math.floor(Date.now() / 1000) + 86_400,
    limits: [{ token: pathUsd, limit, period: 30 * 86_400 }],
    scopes: [
      { address: pathUsd, selector: 'approve(address,uint256)', recipients: [program.clone] },
      { address: program.clone, selector: 'publicCall(bytes)' },
    ],
    feeToken: pathUsd,
  })
  const authorization = await l1Public.waitForTransactionReceipt({ hash: authorized, timeout: 180_000 })
  assert(authorization.status === 'success', 'the cardholder authorized the public spend key')
  const bridgeL1 = t.l1Wallet(Account.fromSecp256k1(bridgeKeyPk, { access: cardholder.address }))
  const publicMs: number[] = []
  let recovered = 0
  for (let i = 0; i < PUBLIC_SPENDS; i++) {
    const spend = {
      spenderId: program.spenderId,
      token: pathUsd,
      amount: SPEND,
      destination: program.settlement,
      vault: zeroAddress,
      fromVault: 0n,
      maxShares: 0n,
      ref: keccak256(toHex(`zone-e2e.${run}.public.${i}`)),
    }
    const payload = concat(['0x54535053', encodeAbiParameters(spendType, [spend])])
    const sent = await sendL1Sync(bridgeL1, l1Public, [
      { to: pathUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [program.clone, SPEND] }) },
      { to: program.clone, data: encodeFunctionData({ abi: cloneAbi, functionName: 'publicCall', args: [payload] }) },
      { to: pathUsd, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [program.clone, 0n] }) },
    ])
    const receipt = sent.receipt
    publicMs.push(sent.ms)
    if (sent.recovered) recovered++
    assert(receipt.status === 'success', 'public spend settled in one L1 transaction')
    assert(paid(receipt.logs, program.settlement), 'public spend paid the settlement wallet')
  }
  const { remaining } = await l1Public.accessKey.getRemainingLimit({ account: cardholder.address, accessKey: bridgeKey, token: pathUsd })
  assert(remaining <= limit - BigInt(PUBLIC_SPENDS) * SPEND, "the spends counted against the access key's limit")
  step(
    17,
    `Public spend with a Bridge access key: ${PUBLIC_SPENDS} single L1 transactions settled, submit to receipt ${publicMs.join(', ')} ms (median ${median(publicMs)})` +
      (recovered ? `; ${recovered} cut off by the RPC proxy at 1 s and read back by hash` : ''),
  )
  return publicMs
}

async function main() {
  const args = process.argv.slice(2)
  const target = args.includes('--target') ? args[args.indexOf('--target') + 1] : 'local'
  if (target !== 'local' && target !== 'moderato') throw new Error(`unknown target ${target}: use local or moderato`)
  execFileSync('forge', ['build'], { cwd: root, stdio: 'ignore', env: forgeEnv() })

  const t = target === 'local' ? await local(step) : await hosted(step, { deploy: args.includes('--deploy'), admit: args.includes('--admit') })
  const run = `${t.name}.${Date.now()}`
  try {
    const privateResult = t.blocked.length === 0 ? await privateSpend(t, run) : undefined
    if (!privateResult) for (const reason of t.blocked) console.log(`BLOCKED private steps 5-16: ${reason}`)
    else if (t.earn) await earnSpend(t, run, t.earn)
    else console.log('    no Earn vault on this target: Earn steps 13-16 skipped')
    const publicMs = await publicSpend(t, run)

    mkdirSync(resolve(root, 'reports'), { recursive: true })
    const latency = {
      target: t.name,
      l1ChainId: t.l1.chainId,
      zoneChainId: t.zone.chainId,
      zoneRequestToZoneReceiptMs: privateResult?.zoneReceiptMs ?? null,
      zoneReceiptToL1SettlementMs: privateResult?.l1SettlementMs ?? null,
      publicSubmitToReceiptMs: publicMs,
      ...(t.l1.blockTime ? { l1BlockTime: t.l1.blockTime } : {}),
      ...(t.zone.batchIntervalBlocks ? { zoneBatchIntervalBlocks: t.zone.batchIntervalBlocks } : {}),
    }
    writeFileSync(resolve(root, `reports/zone-e2e-latency-${t.name}.json`), `${JSON.stringify(latency, null, 2)}\n`)

    if (!privateResult) {
      console.log(`zone e2e (${t.name}): public checks passed, private steps BLOCKED`)
      process.exitCode = EXIT_BLOCKED
      return
    }
    console.log(`zone e2e (${t.name}): all checks passed`)
  } finally {
    await t.close()
  }
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
