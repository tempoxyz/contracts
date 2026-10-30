// Every ZoneRouter flow on the local L1 and Zone, through one router with every op: Earn deposit and
// redeem of a private stablecoin that converts to the vault asset at par through a DirectPropAMM pool,
// card spends through the program's BridgeSettler, sends through a SendSettler, refunds into the
// Zone, and the guards that bounce a withdrawal back into the Zone. Each flow is a real Zone
// withdrawal the sequencer batches to the L1, where the portal calls the router; the checks read the
// L1 settlement and the cardholder's Zone balance once any return lands.
import { writeFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  encodeAbiParameters,
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
  type Address,
  type Hex,
  type Log,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts'
import { Actions } from 'viem/tempo'

import {
  artifact,
  assert,
  CALLBACK_GAS,
  findCall,
  names,
  OP_SPEND,
  outbox,
  outboxAbi,
  pathUsd,
  portalEventsAbi,
  revertData,
  spendDataType,
  spendType,
  step,
  waitFor,
  withdrawalRequested,
  type CallFrame,
} from './support.js'
import {
  portalAbi,
  root,
  type EarnTarget,
  type Prepared,
  type RouterFlowsTarget,
} from './targets.js'

/** ZoneRouter.CallbackData, the callback data of ops 0 (deposit) and 1 (redeem). */
const earnDataType = parseAbiParameters([
  'CallbackData data',
  'struct CallbackData { uint8 op; uint128 minVaultAssets; uint128 minEarnShares; uint128 minOutputAmount; bytes32 actionId; ZoneReturn zoneReturn; }',
  'struct ZoneReturn { uint256 keyIndex; DepositPayload encrypted; address refundRecipient; }',
  'struct DepositPayload { bytes32 ephemeralPubkeyX; uint8 ephemeralPubkeyYParity; bytes ciphertext; bytes12 nonce; bytes16 tag; }',
])
/** SendSettler.Send: pay to exactly amount of token, redeemed from vault's EarnShare when vault is set. */
const sendType = parseAbiParameters([
  'Send send',
  'struct Send { address to; address token; uint128 amount; address vault; bytes32 ref; }',
])
const OP_DEPOSIT = 0
const OP_REDEEM = 1

const vaultAbi = parseAbi([
  'function previewRedeem(uint256 earnShares) view returns (uint256)',
  'function previewWithdraw(uint256 assets) view returns (uint256)',
])
const funderAbi = parseAbi(['function fund(address token, address receiver, uint256 amount)'])
const poolAbi = parseAbi([
  'function pause()',
  'function unpause()',
  'function setGuardian(address guardian)',
])
const portalAdminAbi = parseAbi([
  'function setAccessMode(bool enforced)',
  'function setGatewayMode(bool enforced)',
  'function setGateway(address account, bool allowed)',
  'function setAllowedAccount(address account, bool allowed)',
  'function depositEncrypted(address token, uint128 amount, uint256 keyIndex, (bytes32 ephemeralPubkeyX, uint8 ephemeralPubkeyYParity, bytes ciphertext, bytes12 nonce, bytes16 tag) encrypted, address tempoRefundRecipient) returns (bytes32)',
  'error AccountNotAllowed(address account)',
])

/** Bridge quotes an Earn spend at the live share cost plus this tolerance. */
const SHARE_TOLERANCE_BPS = 50n
const usd = (amount: bigint) => formatUnits(amount, 6)

/** One flow's L1 settlement: whether the router's callback succeeded, its receipt and callback gas. */
type Settlement = {
  ok: boolean
  logs: Log[]
  blockNumber: bigint
  callbackGas?: bigint
}

/** Steps 18 to 28. Returns each flow's router callback gas, for the run's report. */
export async function routerFlows(
  t: Prepared,
  run: string,
  r: RouterFlowsTarget,
  earn: EarnTarget,
) {
  const { cardholder, program, refundRecipient } = t
  const l1Public = t.l1Public
  const userZone = await t.zoneClient(cardholder, true)
  const ref = (label: string) => keccak256(toHex(`zone-e2e.${run}.router.${label}`))
  const gas: Record<string, bigint | null> = {}

  const zoneBalance = (token: Address) =>
    userZone.readContract({
      address: token,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [cardholder.address],
    })
  const l1Balance = (token: Address, account: Address, blockNumber?: bigint) =>
    l1Public.readContract({
      address: token,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [account],
      ...(blockNumber === undefined ? {} : { blockNumber }),
    })
  const l1Write = async (account: PrivateKeyAccount, request: object) => {
    const receipt = await t
      .l1Wallet(account)
      .writeContractSync({ ...request, feeToken: pathUsd } as never)
    assert(receipt.status === 'success', `L1 transaction ${receipt.transactionHash} succeeded`)
    return receipt
  }
  const [depositFee, bouncebackFee] = await Promise.all([
    l1Public.readContract({
      address: t.zone.portal,
      abi: portalAbi,
      functionName: 'calculateDepositFee',
    }),
    l1Public.readContract({
      address: t.zone.portal,
      abi: portalAbi,
      functionName: 'calculateBouncebackFee',
    }),
  ])
  // A spend or send returns what its settler did not use as an encrypted deposit, which the portal
  // rejects below its fees, so each carries change that covers them.
  const change = depositFee + bouncebackFee + 1n

  /** An encrypted deposit of amount token from account into the cardholder's Zone balance. */
  async function depositIntoZone(account: PrivateKeyAccount, token: Address, amount: bigint) {
    await l1Write(account, {
      address: token,
      abi: erc20Abi,
      functionName: 'approve',
      args: [t.zone.portal, amount],
    })
    const hash = await t.l1Wallet(account).zone.encryptedDeposit({
      amount,
      portalAddress: t.zone.portal,
      recipient: cardholder.address,
      token,
      zoneId: t.zone.id,
    })
    const receipt = await l1Public.waitForTransactionReceipt({ hash, timeout: 180_000 })
    assert(receipt.status === 'success', 'the encrypted deposit succeeded')
    return receipt
  }

  /** The encrypted return to the cardholder that the router deposits back into the Zone. */
  const zoneReturn = async () => {
    const recipient = await Actions.zone.encryptedDeposit.prepareRecipient(l1Public, {
      recipient: cardholder.address,
      sender: r.router,
      portalAddress: t.zone.portal,
      zoneId: t.zone.id,
    })
    return {
      keyIndex: recipient.keyIndex,
      encrypted: {
        ephemeralPubkeyX: recipient.encrypted.ephemeralPubkeyX,
        ephemeralPubkeyYParity: recipient.encrypted.ephemeralPubkeyYParity,
        ciphertext: recipient.encrypted.ciphertext,
        nonce: recipient.encrypted.nonce,
        tag: recipient.encrypted.tag,
      },
      refundRecipient,
    }
  }
  const earnData = async (
    op: number,
    minVaultAssets: bigint,
    minOutputAmount: bigint,
    label: string,
  ) =>
    encodeAbiParameters(earnDataType, [
      {
        op,
        minVaultAssets,
        // EarnVault rejects a zero share minimum.
        minEarnShares: op === OP_DEPOSIT ? 1n : 0n,
        minOutputAmount,
        actionId: ref(label),
        zoneReturn: await zoneReturn(),
      },
    ])
  const spendData = async (settler: Address, maxInput: bigint, settlerData: Hex) =>
    encodeAbiParameters(spendDataType, [
      {
        op: OP_SPEND,
        settler,
        maxInput,
        settlerData,
        zoneReturn: { ...(await zoneReturn()), maxDepositFee: depositFee },
      },
    ])
  const cardData = (
    token: Address,
    amount: bigint,
    vault: Address,
    maxShares: bigint,
    label: string,
  ) =>
    spendData(
      program.settler,
      vault === zeroAddress ? amount : maxShares,
      encodeAbiParameters(spendType, [
        {
          spenderId: program.spenderId,
          token,
          amount,
          destination: program.settlement,
          vault,
          fromVault: vault === zeroAddress ? 0n : amount,
          maxShares,
          ref: ref(label),
        },
      ]),
    )
  const sendData = (
    to: Address,
    token: Address,
    amount: bigint,
    vault: Address,
    maxInput: bigint,
    label: string,
  ) =>
    spendData(
      r.sendSettler,
      maxInput,
      encodeAbiParameters(sendType, [{ to, token, amount, vault, ref: ref(label) }]),
    )
  const maxShares = async (assets: bigint) => {
    const live = await l1Public.readContract({
      address: earn.vault,
      abi: vaultAbi,
      functionName: 'previewWithdraw',
      args: [assets],
    })
    return live + (live * SHARE_TOLERANCE_BPS) / 10_000n + 1n
  }

  /**
   * Withdraws amount token from the cardholder's Zone balance to the router with callback data, waits
   * for the portal to process it on the L1, and returns that settlement.
   */
  async function withdraw(
    token: Address,
    amount: bigint,
    data: Hex,
    flow: string,
  ): Promise<Settlement> {
    const fee = await userZone.readContract({
      address: outbox,
      abi: outboxAbi,
      functionName: 'calculateWithdrawalFee',
      args: [CALLBACK_GAS],
    })
    const fromBlock = await l1Public.getBlockNumber()
    const request = await userZone.sendTransactionSync({
      calls: [
        {
          to: token,
          data: encodeFunctionData({
            abi: erc20Abi,
            functionName: 'approve',
            args: [outbox, amount + fee],
          }),
        },
        {
          to: outbox,
          data: encodeFunctionData({
            abi: outboxAbi,
            functionName: 'requestWithdrawal',
            args: [token, r.router, amount, zeroHash, CALLBACK_GAS, cardholder.address, data, '0x'],
          }),
        },
      ],
      feeToken: pathUsd,
    })
    assert(request.status === 'success', `${flow}: the Zone accepted the withdrawal request`)
    const { senderTag } = withdrawalRequested(request)
    const [processed] = await waitFor(
      `${flow}: the portal processing the withdrawal`,
      () =>
        l1Public.getContractEvents({
          address: t.zone.portal,
          abi: portalEventsAbi,
          eventName: 'WithdrawalProcessed',
          args: { to: r.router, senderTag },
          fromBlock,
        }),
      (found) => found.length > 0,
      250,
    )
    const receipt = await l1Public.getTransactionReceipt({ hash: processed!.transactionHash })
    const settlement: Settlement = {
      ok: processed!.args.callbackSuccess === true,
      logs: receipt.logs,
      blockNumber: receipt.blockNumber,
    }
    if (t.l1.tracesCalls && settlement.ok) {
      const trace = (await l1Public.request({
        method: 'debug_traceTransaction',
        params: [receipt.transactionHash, { tracer: 'callTracer' }],
      } as never)) as CallFrame
      const frame = findCall(
        trace,
        r.router,
        toFunctionSelector('onWithdrawalReceived(uint32,address,bytes32,address,uint128,bytes)'),
      )
      if (frame?.gasUsed) settlement.callbackGas = BigInt(frame.gasUsed)
    }
    gas[flow] = settlement.callbackGas ?? null
    assert(
      !names(receipt.logs, cardholder.address),
      `${flow}: no L1 log of the settlement names the cardholder`,
    )
    return settlement
  }

  /** The change in account's token balance across the settlement's block. */
  const moved = async (token: Address, account: Address, s: Settlement) =>
    (await l1Balance(token, account, s.blockNumber)) -
    (await l1Balance(token, account, s.blockNumber - 1n))
  const routerEvent = (s: Settlement, eventName: 'EarnDeposit' | 'EarnRedeem' | 'Spent') => {
    const events = parseEventLogs({
      abi: artifact('ZoneRouter').abi,
      eventName,
      logs: s.logs.filter((log) => isAddressEqual(log.address, r.router)),
    })
    assert(events.length === 1, `one router ${eventName} event in the settlement`)
    return (events[0] as unknown as { args: Record<string, bigint | Address> }).args
  }
  const gasNote = (s: Settlement) => (s.callbackGas ? `, callback ${s.callbackGas} gas` : '')
  /** Waits for the cardholder's Zone balance of token to reach expected, once any return lands. */
  const zoneSettles = (token: Address, expected: bigint, label: string) =>
    waitFor(
      label,
      () => zoneBalance(token),
      (v) => v === expected,
      500,
    )

  // Funds the cardholder's private stablecoin balance in the Zone.
  const funded = 500_000_000n
  await l1Write(cardholder, {
    address: earn.funder,
    abi: funderAbi,
    functionName: 'fund',
    args: [r.privateAsset, cardholder.address, funded],
  })
  const privateStart = await zoneBalance(r.privateAsset)
  const zoneDeposit = await depositIntoZone(cardholder, r.privateAsset, funded)
  await Actions.zone.waitForTempoBlock(userZone, {
    pollingInterval: 500,
    tempoBlockNumber: zoneDeposit.blockNumber,
    timeout: 180_000,
  })
  await zoneSettles(
    r.privateAsset,
    privateStart + funded - depositFee,
    'the private stablecoin deposit',
  )
  step(
    18,
    `Cardholder moved ${usd(funded)} of the private stablecoin into the Zone; every-op router ${r.router}`,
  )

  // Earn deposit: the private stablecoin converts to the vault asset at par, then into EarnShare.
  {
    const amount = 100_000_000n
    const [privateBefore, sharesBefore] = await Promise.all([
      zoneBalance(r.privateAsset),
      zoneBalance(earn.earnShare),
    ])
    const s = await withdraw(
      r.privateAsset,
      amount,
      await earnData(OP_DEPOSIT, amount, 0n, 'deposit'),
      'Earn deposit',
    )
    assert(s.ok, 'Earn deposit: the router callback succeeded')
    const event = routerEvent(s, 'EarnDeposit')
    assert(
      event.inputAmount === amount && event.vaultAssets === amount,
      'Earn deposit: converted 1:1 at par',
    )
    const [poolIn, poolOut] = await Promise.all([
      moved(r.privateAsset, r.pool, s),
      moved(earn.asset, r.pool, s),
    ])
    assert(
      poolIn === amount && poolOut === -amount,
      'Earn deposit: the pool took the stablecoin and paid the vault asset 1:1',
    )
    const shares = event.earnShares as bigint
    await zoneSettles(
      earn.earnShare,
      sharesBefore + shares - depositFee,
      'Earn deposit: EarnShare back in the Zone',
    )
    assert(
      (await zoneBalance(r.privateAsset)) === privateBefore - amount,
      'Earn deposit: only the deposit left the Zone',
    )
    step(
      19,
      `Earn deposit: ${usd(amount)} private stablecoin converted at par and deposited, ${usd(shares)} EarnShare back in the Zone${gasNote(s)}`,
    )
  }

  // Earn redeem: EarnShare redeems to the vault asset, which converts back to the private stablecoin.
  {
    const shares = (await zoneBalance(earn.earnShare)) / 4n
    const expected = await l1Public.readContract({
      address: earn.vault,
      abi: vaultAbi,
      functionName: 'previewRedeem',
      args: [shares],
    })
    const privateBefore = await zoneBalance(r.privateAsset)
    const s = await withdraw(
      earn.earnShare,
      shares,
      await earnData(OP_REDEEM, expected, expected, 'redeem'),
      'Earn redeem',
    )
    assert(s.ok, 'Earn redeem: the router callback succeeded')
    const event = routerEvent(s, 'EarnRedeem')
    const out = event.outputAmount as bigint
    assert(
      out === event.vaultAssets && out >= expected,
      'Earn redeem: converted 1:1 at par, at least the preview',
    )
    const [poolIn, poolOut] = await Promise.all([
      moved(earn.asset, r.pool, s),
      moved(r.privateAsset, r.pool, s),
    ])
    assert(
      poolIn === out && poolOut === -out,
      'Earn redeem: the pool took the vault asset and paid the stablecoin 1:1',
    )
    await zoneSettles(
      r.privateAsset,
      privateBefore + out - depositFee,
      'Earn redeem: the stablecoin back in the Zone',
    )
    step(
      20,
      `Earn redeem: ${usd(shares)} EarnShare redeemed and converted at par, ${usd(out)} private stablecoin back in the Zone${gasNote(s)}`,
    )
  }

  // Card spends through the same router: the program's BridgeSettler pays through Bridge's clone.
  const spend = 20_000_000n
  {
    const paidBefore = await l1Balance(r.privateAsset, program.settlement)
    const privateBefore = await zoneBalance(r.privateAsset)
    const s = await withdraw(
      r.privateAsset,
      spend + change,
      await cardData(r.privateAsset, spend, zeroAddress, 0n, 'card.stablecoin'),
      'Card spend, private stablecoin',
    )
    assert(s.ok, 'stablecoin card spend: the router callback succeeded')
    const spent = routerEvent(s, 'Spent')
    assert(
      spent.used === spend && spent.change === change,
      'stablecoin card spend: used the spend, returned the change',
    )
    assert(
      (await l1Balance(r.privateAsset, program.settlement)) - paidBefore === spend,
      'stablecoin card spend: settlement wallet paid',
    )
    await zoneSettles(
      r.privateAsset,
      privateBefore - spend - depositFee,
      'stablecoin card spend: change back in the Zone',
    )
    step(
      21,
      `Card spend from the private stablecoin: settlement wallet paid ${usd(spend)}, change back in the Zone${gasNote(s)}`,
    )
  }
  {
    const quote = await maxShares(spend)
    const paidBefore = await l1Balance(earn.asset, program.settlement)
    const sharesBefore = await zoneBalance(earn.earnShare)
    const s = await withdraw(
      earn.earnShare,
      quote + change,
      await cardData(earn.asset, spend, earn.vault, quote, 'card.earn'),
      'Card spend, private Earn',
    )
    assert(s.ok, 'Earn card spend: the router callback succeeded')
    const spent = routerEvent(s, 'Spent')
    const used = spent.used as bigint
    assert(used <= quote, "Earn card spend: burned no more shares than Bridge's quote")
    assert(
      (await l1Balance(earn.asset, program.settlement)) - paidBefore === spend,
      'Earn card spend: settlement wallet paid in the vault asset',
    )
    await zoneSettles(
      earn.earnShare,
      sharesBefore - used - depositFee,
      'Earn card spend: unused shares back in the Zone',
    )
    step(
      22,
      `Card spend from Earn: settlement wallet paid ${usd(spend)} of the vault asset for ${usd(used)} EarnShare, the rest back in the Zone${gasNote(s)}`,
    )
  }

  // Sends to a public address through the SendSettler.
  const recipient = privateKeyToAccount(generatePrivateKey()).address
  const send = 10_000_000n
  {
    const s = await withdraw(
      r.privateAsset,
      send + change,
      await sendData(recipient, r.privateAsset, send, zeroAddress, send, 'send.stablecoin'),
      'Send, stablecoin',
    )
    assert(
      s.ok && (await l1Balance(r.privateAsset, recipient)) === send,
      'stablecoin send: recipient paid',
    )
    const shares = (await zoneBalance(earn.earnShare)) / 10n
    const s2 = await withdraw(
      earn.earnShare,
      shares + change,
      await sendData(recipient, earn.earnShare, shares, zeroAddress, shares, 'send.share'),
      'Send, EarnShare',
    )
    assert(
      s2.ok && (await l1Balance(earn.earnShare, recipient)) === shares,
      'EarnShare send: recipient holds the shares',
    )
    step(
      23,
      `Sends: ${usd(send)} private stablecoin and ${usd(shares)} EarnShare paid to a public address${gasNote(s)}`,
    )
  }
  {
    const quote = await maxShares(send)
    const s = await withdraw(
      earn.earnShare,
      quote + change,
      await sendData(recipient, earn.asset, send, earn.vault, quote, 'send.redeem'),
      'Send, Earn as vault asset',
    )
    assert(
      s.ok && (await l1Balance(earn.asset, recipient)) === send,
      'Earn send: recipient paid the vault asset',
    )
    assert((await moved(earn.asset, r.pool, s)) === 0n, 'Earn send: no conversion')
    const quote2 = await maxShares(send)
    const before = await l1Balance(r.privateAsset, recipient)
    const s2 = await withdraw(
      earn.earnShare,
      quote2 + change,
      await sendData(recipient, r.privateAsset, send, earn.vault, quote2, 'send.convert'),
      'Send, Earn converted at par',
    )
    assert(
      s2.ok && (await l1Balance(r.privateAsset, recipient)) - before === send,
      'converting send: recipient paid the stablecoin',
    )
    const [poolIn, poolOut] = await Promise.all([
      moved(earn.asset, r.pool, s2),
      moved(r.privateAsset, r.pool, s2),
    ])
    assert(poolIn === send && poolOut === -send, 'converting send: the pool converted 1:1 at par')
    step(
      24,
      `Sends from Earn: ${usd(send)} of the vault asset, and ${usd(send)} converted to the private stablecoin at par${gasNote(s2)}`,
    )
  }

  // Refund: the program wallet deposits back into the cardholder's Zone balance; no router involved.
  {
    const refund = 12_340_000n
    await l1Write(r.programWallet, {
      address: earn.funder,
      abi: funderAbi,
      functionName: 'fund',
      args: [r.privateAsset, r.programWallet.address, refund],
    })
    const before = await zoneBalance(r.privateAsset)
    await depositIntoZone(r.programWallet, r.privateAsset, refund)
    await zoneSettles(r.privateAsset, before + refund - depositFee, 'the refund in the Zone')
    step(
      25,
      `Refund: the program wallet deposited ${usd(refund)} back into the cardholder's Zone balance`,
    )
  }

  // A paused pool bounces Earn ops back into the Zone in full; a stablecoin spend needs no pool.
  {
    await l1Write(r.poolOwner, {
      address: r.pool,
      abi: poolAbi,
      functionName: 'setGuardian',
      args: [r.poolOwner.address],
    })
    await l1Write(r.poolOwner, { address: r.pool, abi: poolAbi, functionName: 'pause' })
    const amount = 10_000_000n
    const before = await zoneBalance(r.privateAsset)
    const bounced = await withdraw(
      r.privateAsset,
      amount,
      await earnData(OP_DEPOSIT, amount, 0n, 'paused'),
      'Earn deposit, pool paused',
    )
    assert(!bounced.ok, 'paused pool: the Earn deposit callback failed')
    await zoneSettles(
      r.privateAsset,
      before - bouncebackFee,
      'paused pool: the deposit bounced back into the Zone',
    )
    const s = await withdraw(
      r.privateAsset,
      spend + change,
      await cardData(r.privateAsset, spend, zeroAddress, 0n, 'paused.card'),
      'Card spend, pool paused',
    )
    assert(s.ok, 'paused pool: a stablecoin card spend still settles')
    await l1Write(r.poolOwner, { address: r.pool, abi: poolAbi, functionName: 'unpause' })
    step(
      26,
      'Paused pool: an Earn deposit bounced back into the Zone in full, a stablecoin card spend still settled',
    )
  }

  // Closed loop, as a production Zone runs: only admitted accounts deposit, only the registered
  // router takes callbacks, and a callback that returns nothing to the Zone bounces.
  {
    const admin = (functionName: string, args: readonly unknown[]) =>
      l1Write(r.zoneAdmin, { address: t.zone.portal, abi: portalAdminAbi, functionName, args })
    for (const account of [cardholder.address, refundRecipient, r.programWallet.address])
      await admin('setAllowedAccount', [account, true])
    await admin('setGateway', [r.router, true])
    await admin('setGatewayMode', [true])
    await admin('setAccessMode', [true])

    const before = await zoneBalance(r.privateAsset)
    const exact = await withdraw(
      r.privateAsset,
      spend,
      await cardData(r.privateAsset, spend, zeroAddress, 0n, 'closed.exact'),
      'Card spend without change, closed loop',
    )
    assert(!exact.ok, 'closed loop: a spend that returns nothing bounces')
    await zoneSettles(
      r.privateAsset,
      before - bouncebackFee,
      'closed loop: the spend bounced back into the Zone',
    )

    const amount = 10_000_000n
    const sharesBefore = await zoneBalance(earn.earnShare)
    const s = await withdraw(
      r.privateAsset,
      amount,
      await earnData(OP_DEPOSIT, amount, 0n, 'closed.deposit'),
      'Earn deposit, closed loop',
    )
    assert(s.ok, 'closed loop: an Earn deposit through the registered router settles')
    await waitFor(
      'closed loop: EarnShare back in the Zone',
      () => zoneBalance(earn.earnShare),
      (v) => v > sharesBefore,
      500,
    )

    const stranger = privateKeyToAccount(generatePrivateKey())
    await l1Public.faucet.fundSync({ account: stranger.address, timeout: 180_000 })
    await l1Write(stranger, {
      address: earn.funder,
      abi: funderAbi,
      functionName: 'fund',
      args: [r.privateAsset, stranger.address, amount],
    })
    await l1Write(stranger, {
      address: r.privateAsset,
      abi: erc20Abi,
      functionName: 'approve',
      args: [t.zone.portal, amount],
    })
    const keyIndex = (await zoneReturn()).keyIndex
    const refused = await l1Public
      .simulateContract({
        account: stranger,
        address: t.zone.portal,
        abi: portalAdminAbi,
        functionName: 'depositEncrypted',
        args: [r.privateAsset, amount, keyIndex, (await zoneReturn()).encrypted, stranger.address],
      })
      .then(
        () => undefined,
        (error: unknown) => error,
      )
    assert(
      revertData(refused)?.startsWith(toFunctionSelector('AccountNotAllowed(address)')),
      'closed loop: a deposit from an unadmitted wallet is refused',
    )
    step(
      27,
      `Closed loop: a spend returning nothing bounced back into the Zone, an Earn deposit through the registered router settled${gasNote(s)}, and an unadmitted wallet's deposit is refused`,
    )
  }

  const report = resolve(root, `reports/zone-e2e-router-flows-${t.name}.json`)
  writeFileSync(
    report,
    `${JSON.stringify(Object.fromEntries(Object.entries(gas).map(([k, v]) => [k, v === null ? null : Number(v)])), null, 2)}\n`,
  )
  step(28, `Router callback gas per flow written to ${report}`)
  for (const [flow, used] of Object.entries(gas))
    if (used !== null) console.log(`    ${flow}: ${used}`)
}
