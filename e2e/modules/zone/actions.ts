import { performance } from 'node:perf_hooks'

import { getAbiItem, getAddress, type Address, type Hex } from 'viem'
import { getGasPrice, getTransactionCount } from 'viem/actions'
import { Abis, Actions as TempoActions } from 'viem/tempo'
import { processedRouterEvent, waitForWithdrawalProcessed } from '@tempoxyz/contracts/tempo/zone'
import {
  requireE2eZone,
  type E2eActor,
  type E2eContext,
  type E2eZoneContext,
} from '../../harness/context.js'
import {
  ensureFeeBalance,
  fundAsset,
  tokenBalance,
  tokenSupply,
} from '../../harness/support/funding.js'
import { chainMs, wallMs, type ActionTiming } from '../../harness/support/timings.js'
import {
  assert,
  E2ePrerequisiteError,
  errorSummary,
  TIMEOUT_MS,
  waitFor,
} from '../../harness/support/utils.js'
import {
  minimumOutput,
  previewEarnDeposit,
  previewEarnRedeem,
} from '../../harness/support/slippage.js'
import { ensureZoneReady } from './readiness.js'
import { submitZoneWithdrawal } from './proof.js'
import {
  assertRouterReceipt,
  callbackBounce,
  portalDeposit,
  receiptBalanceChange,
  sourceWithdrawal,
  waitForCallbackBounce,
  waitForDepositDelivery,
} from './delivery.js'
import { waitForRecipientRefund } from './refund-settlement.js'
import { zoneRefundRecipients } from './refund.js'

/** PATHUSD moved into the Zone for its fees before each private leg when Zone gas is priced. */
export const ZONE_FEE_BUFFER = 1_100_000n
const ZONE_WITHDRAWAL_TRANSACTION_GAS = 10_000_000n
const depositEvent = getAbiItem({ abi: Abis.earnRouter, name: 'EarnDeposit' })

/** A private deposit of the router's private asset, the alternate fixture asset. */
type ZoneDepositInput = {
  amount: bigint
  recipient?: E2eActor
  minimumVaultAssetsOverride?: bigint
  /** The harness already funded the private input and fee buffer, as the benchmark does. */
  funded?: boolean
}

/** A private redemption, always paid in the router's private asset. */
type ZoneRedeemInput = {
  earnShares: bigint
  owner?: E2eActor
  recipient?: E2eActor
  /** The harness already funded the fee buffer, as the benchmark does. */
  funded?: boolean
}

/**
 * Tops the user's private balance of the router's private asset up to `amount` through a Portal
 * entry funded by the stack's fixture. A production stack has no fixture funder, so a shortfall
 * there is a manual Zone top-up the run cannot make.
 */
export async function fundPrivateInput(context: E2eContext, amount: bigint) {
  requireE2eZone(context)
  const token = context.assets.alternate
  await ensureZoneReady(context)
  const balance = await zoneBalance(context, token)
  if (balance >= amount) {
    context.progress.step('INPUT', 'reused private balance already in the Zone')
    return
  }
  const zone = context.deployment.network.zone
  if (!context.funding?.funder) {
    throw new E2ePrerequisiteError(
      `${context.user.address} holds ${balance} of the ${amount} units of ${token} this case needs in Zone ${zone.id}; top up its Zone balance manually, then rerun`,
    )
  }
  const funding = await encryptedEntry(context, token, amount - balance)
  context.progress.step(
    'INPUT',
    'funded private balance through the Portal',
    funding.receipt.transactionHash,
  )
}

export async function zoneDeposit(context: E2eContext, input: ZoneDepositInput) {
  requireE2eZone(context)
  await ensureZoneReady(context)
  if (!input.funded) {
    await fundPrivateInput(context, input.amount)
    await fundPrivateFeeBuffer(context)
  }
  const before = await zoneBalance(context, context.contracts.earnShare, input.recipient)
  const leg = await submitDeposit(context, { ...input, funded: true })
  if (!leg.processed.args.callbackSuccess) throw callbackReverted(context, leg.processed)
  context.progress.step('L1', 'router deposit settled', leg.processed.transactionHash)
  const settled = await routerEvent(context, leg, 'EarnDeposit')
  const delivery = await routerDelivery(context, leg, {
    token: context.contracts.earnShare,
    gross: settled.args.earnShares,
    hash: settled.args.zoneDepositHash,
    recipient: input.recipient,
  })
  const earnShares = await waitForZoneCredit(context, {
    token: context.contracts.earnShare,
    actor: input.recipient,
    before,
    expected:
      delivery.netAmount +
      receiptBalanceChange(
        leg.receipt.logs,
        context.contracts.earnShare,
        context.actors[input.recipient ?? 'user'].account.address,
      ),
    exact: true,
    message: 'Zone did not credit the router-deposited EarnShare',
  })
  recordZoneTiming(context, 'zone-deposit', leg)
  context.progress.step('RETURN', 'EarnShare delivered privately', settled.args.zoneDepositHash)
  context.progress.step('CHECK', 'private balance and public backing increased')
  assert(
    earnShares === delivery.netAmount,
    'EarnShare delivery changed beyond the certified credit',
  )
  return { earnShares: delivery.netAmount }
}

export async function zoneDepositExpectBounce(context: E2eContext, input: ZoneDepositInput) {
  requireE2eZone(context)
  await ensureZoneReady(context)
  const state = () =>
    Promise.all([
      zoneBalance(context, context.contracts.earnShare, input.recipient),
      tokenSupply(context, context.contracts.earnShare),
      tokenBalance(context, context.contracts.venue, context.contracts.engine),
    ])
  if (!input.funded) {
    await fundPrivateInput(context, input.amount)
    await fundPrivateFeeBuffer(context)
  }
  const privateInputBefore = await zoneBalance(context, context.assets.alternate)
  const before = await state()
  const leg = await submitDeposit(context, { ...input, funded: true })
  assert(!leg.processed.args.callbackSuccess, 'bounded router deposit unexpectedly succeeded')
  context.progress.step('L1', 'router rejected the bounded deposit', leg.processed.transactionHash)
  const callbackReceipt = await context.l1Public.getTransactionReceipt({
    hash: leg.processed.transactionHash,
  })
  const hash = callbackBounce(callbackReceipt.logs, {
    portal: context.deployment.network.zone.portal,
    fallbackNonce: leg.request.fallbackNonce,
    token: context.assets.alternate,
    amount: input.amount,
  })
  await waitForCallbackBounce(context, {
    hash,
    fallbackNonce: leg.request.fallbackNonce,
    token: context.assets.alternate,
    amount: input.amount,
    recipient: context.user.address,
    fromBlock: leg.zoneFromBlock,
  })
  await waitForZoneCredit(context, {
    token: context.assets.alternate,
    before: privateInputBefore,
    expected:
      input.amount +
      receiptBalanceChange(leg.receipt.logs, context.assets.alternate, context.user.address),
    exact: true,
    message: 'Callback bounce did not return the input after recorded fees',
  })
  const [after, depositLogs] = await Promise.all([state(), routerDeposits(context, leg.fromBlock)])
  assert(after[0] === before[0], 'bounced deposit credited private EarnShare')
  assert(after[1] === before[1], 'bounced deposit changed public EarnShare supply')
  assert(after[2] === before[2], 'bounced deposit changed engine backing')
  assert(
    !depositLogs.some((log) => log.args.actionId === leg.actionId),
    'bounced deposit emitted a successful EarnRouter event',
  )
  context.progress.step('RETURN', 'private input bounced after the rejected callback')
  context.progress.step('CHECK', 'EarnShare supply and engine backing remained unchanged')
}

export async function zoneDepositExpectRecipientBounce(
  context: E2eContext,
  input: ZoneDepositInput,
) {
  requireE2eZone(context)
  const { earnShare, earnFees, engine, venue } = context.contracts
  await fundPrivateInput(context, input.amount)
  await fundPrivateFeeBuffer(context)
  const [recipientEarnBefore, publicRefundBefore, feeEarnBefore, supplyBefore, backingBefore] =
    await Promise.all([
      zoneBalance(context, earnShare, input.recipient),
      tokenBalance(context, earnShare, context.user.address),
      tokenBalance(context, earnShare, earnFees),
      tokenSupply(context, earnShare),
      tokenBalance(context, venue, engine),
    ])
  const leg = await submitDeposit(context, { ...input, funded: true })
  if (!leg.processed.args.callbackSuccess) throw callbackReverted(context, leg.processed)
  const depositLog = await routerEvent(context, leg, 'EarnDeposit')
  const receipt = await context.l1Public.getTransactionReceipt({
    hash: leg.processed.transactionHash,
  })
  const deposit = portalDeposit(receipt.logs, {
    portal: context.deployment.network.zone.portal,
    sender: context.contracts.earnRouter,
    token: earnShare,
    gross: depositLog.args.earnShares,
    hash: depositLog.args.zoneDepositHash,
  })
  const refundedEarnShares = await waitForRecipientRefund(context, {
    depositHash: deposit.hash,
    token: earnShare,
    sender: context.contracts.earnRouter,
    recipient: context.user.address,
    netAmount: deposit.netAmount,
    zoneFromBlock: leg.zoneFromBlock,
    l1FromBlock: leg.fromBlock,
  })
  const publicRefundAfter = await tokenBalance(context, earnShare, context.user.address)
  assert(
    publicRefundAfter - publicRefundBefore === refundedEarnShares,
    'Public EarnShare balance does not match the attributable fee-net refund',
  )
  const [recipientEarnAfter, feeEarnAfter, supplyAfter, backingAfter] = await Promise.all([
    zoneBalance(context, earnShare, input.recipient),
    tokenBalance(context, earnShare, earnFees),
    tokenSupply(context, earnShare),
    tokenBalance(context, venue, engine),
  ])
  const mintedEarnShares = depositLog.args.earnShares
  assert(
    recipientEarnAfter === recipientEarnBefore,
    'ineligible private recipient received EarnShare',
  )
  assert(
    refundedEarnShares > 0n && refundedEarnShares <= deposit.netAmount,
    `public refund ${refundedEarnShares} is invalid for ${mintedEarnShares} minted EarnShare`,
  )
  assert(
    supplyAfter - supplyBefore === mintedEarnShares + (feeEarnAfter - feeEarnBefore),
    'EarnShare supply does not match principal and fee-share minting',
  )
  assert(backingAfter > backingBefore, 'successful router deposit added no backing')
  context.progress.step('L1', 'router deposit executed', depositLog.transactionHash)
  context.progress.step('RETURN', 'EarnShare bounced to the eligible public initiator')
  context.progress.step('CHECK', 'ineligible private recipient received no EarnShare')
  return { refundedEarnShares }
}

export async function zoneRedeem(context: E2eContext, input: ZoneRedeemInput) {
  requireE2eZone(context)
  await ensureZoneReady(context)
  if (!input.funded) {
    await fundPrivateFeeBuffer(context, input.owner)
  }
  const assetAmountMin = minimumOutput(await previewEarnRedeem(context, input.earnShares))
  const before = await zoneBalance(context, context.assets.alternate, input.recipient)
  const leg = await submitRouterLeg(
    context,
    { owner: input.owner ?? 'user', recipient: input.recipient ?? 'user', funded: true },
    (common) =>
      TempoActions.earn.privateRedeem.prepare(context.l1Public, {
        ...common,
        assetAmountMin,
        assetToken: context.assets.alternate,
        shareAmount: input.earnShares,
      }),
  )
  if (!leg.processed.args.callbackSuccess) throw callbackReverted(context, leg.processed)
  context.progress.step('L1', 'router redemption settled', leg.processed.transactionHash)
  const settled = await routerEvent(context, leg, 'EarnRedeem')
  const delivery = await routerDelivery(context, leg, {
    token: context.assets.alternate,
    gross: settled.args.outputAmount,
    hash: settled.args.zoneDepositHash,
    recipient: input.recipient,
  })
  // Only movements in the source receipt adjust the baseline; unrelated credits never prove delivery.
  await waitForZoneCredit(context, {
    token: context.assets.alternate,
    actor: input.recipient,
    before,
    expected:
      delivery.netAmount +
      receiptBalanceChange(
        leg.receipt.logs,
        context.assets.alternate,
        context.actors[input.recipient ?? 'user'].account.address,
      ),
    exact: true,
    message: 'Zone did not credit the redeemed output token',
  })
  recordZoneTiming(context, 'zone-redeem', leg)
  context.progress.step('RETURN', 'private output asset delivered', settled.args.zoneDepositHash)
  context.progress.step('CHECK', 'private output balance increased')
  return { outputAmount: delivery.netAmount }
}

/** Submits a funded private deposit leg; the caller has already funded its private input. */
async function submitDeposit(context: E2eZoneContext, input: ZoneDepositInput) {
  // The router's pool converts the private asset to vault assets one-to-one.
  const vaultAssetAmountMin = minimumOutput(input.amount)
  const shareAmountMin = minimumOutput(await previewEarnDeposit(context, vaultAssetAmountMin))
  return await submitRouterLeg(
    context,
    { owner: 'user', recipient: input.recipient ?? 'user', funded: input.funded },
    (common) =>
      TempoActions.earn.privateDeposit.prepare(context.l1Public, {
        ...common,
        assetAmount: input.amount,
        assetToken: context.assets.alternate,
        shareAmountMin,
        vaultAssetAmountMin: input.minimumVaultAssetsOverride ?? vaultAssetAmountMin,
      }),
  )
}

/** The router, Zone, and recipients every leg's viem `prepare` shares. */
type RouterLegTarget = {
  gateway: Address
  vault: Address
  portalAddress: Address
  zoneId: number
  recipient: Address
  tempoRefundRecipient: Address
  fallbackRecipient: Address
}

/**
 * One router leg: `owner` withdraws the prepared callback's input from the Zone to the EarnRouter,
 * which returns the output privately to `recipient` (refunding a bounced return to `owner`'s
 * verified Tempo refund recipient), and the Portal processes it on L1. viem's `prepare` also checks
 * the router's Zone, EarnVault, asset, EarnShare, and flow bindings before anything is submitted.
 */
async function submitRouterLeg(
  context: E2eZoneContext,
  leg: { owner: E2eActor; recipient: E2eActor; funded?: boolean | undefined },
  prepare: (
    target: RouterLegTarget,
  ) => Promise<TempoActions.earn.privateDeposit.prepare.ReturnValue>,
) {
  const owner = context.actors[leg.owner]
  const { earnRouter, earnVault } = context.contracts
  const { portal, id: zoneId } = context.deployment.network.zone
  const prepared = await prepare({
    gateway: earnRouter,
    vault: earnVault,
    portalAddress: portal,
    zoneId,
    recipient: context.actors[leg.recipient].account.address,
    tempoRefundRecipient: await tempoRefundRecipient(context, owner.account.address),
    fallbackRecipient: owner.account.address,
  })
  // Fee and nonce reads finish before the timer, so the phase is submission alone.
  const parameters = await withdrawalParameters(context, leg.owner, leg.funded)
  const zoneFromBlock = await owner.zone.client.getBlockNumber()
  const submitted = performance.now()
  const receipt = await submitZoneWithdrawal(context, leg.owner, {
    ...prepared,
    ...parameters,
  })
  const request = sourceWithdrawal(receipt, {
    sender: owner.account.address,
    to: earnRouter,
    token: prepared.token,
    amount: prepared.amount,
    data: prepared.data,
    gasLimit: prepared.callbackGas,
  })
  const zoneReceiptMs = wallMs(submitted)
  context.progress.step('ZONE', 'private withdrawal submitted', receipt.transactionHash)
  const processed = await waitForWithdrawalProcessed(context.l1Public, {
    portal,
    to: earnRouter,
    senderTag: request.senderTag,
    fromBlock: prepared.fromBlock,
    pollingInterval: context.pollingInterval,
    timeout: TIMEOUT_MS,
  })
  const callbackReceipt = await context.l1Public.getTransactionReceipt({
    hash: processed.transactionHash,
  })
  const privateAsset = await context.l1Public.readContract({
    address: earnRouter,
    abi: Abis.earnRouter,
    functionName: 'privateAsset',
  })
  assertRouterReceipt(
    callbackReceipt.logs,
    [context.contracts.asset, privateAsset, context.contracts.earnShare],
    earnRouter,
  )
  return {
    actionId: prepared.actionId,
    fromBlock: prepared.fromBlock,
    processed,
    receipt,
    request,
    zoneFromBlock,
    timing: {
      owner: leg.owner,
      submitted,
      zoneReceiptMs,
      zoneBlockNumber: receipt.blockNumber,
    },
  }
}

/**
 * Records a Zone round trip's phases: the Zone withdrawal's submit to receipt, the Zone block to
 * the L1 block that ran the router callback (chain time), and submit to the private credit. The
 * block reads resolve after the action returns, and a failed read drops only the chain phase.
 */
function recordZoneTiming(
  context: E2eZoneContext,
  action: string,
  leg: Awaited<ReturnType<typeof submitRouterLeg>>,
) {
  const totalMs = wallMs(leg.timing.submitted)
  const timing = Promise.all([
    context.actors[leg.timing.owner].zone.client.getBlock({
      blockNumber: leg.timing.zoneBlockNumber,
    }),
    context.l1Public.getBlock({ blockNumber: leg.processed.blockNumber }),
  ])
    .then(
      ([zoneBlock, l1Block]) => chainMs(zoneBlock, l1Block),
      () => undefined,
    )
    .then((l1CallbackMs): ActionTiming => ({
      action,
      phases: [
        { phase: 'zone-submit-to-receipt', ms: leg.timing.zoneReceiptMs, clock: 'wall' },
        ...(l1CallbackMs === undefined
          ? []
          : [{ phase: 'zone-receipt-to-l1-callback', ms: l1CallbackMs, clock: 'chain' as const }]),
        { phase: 'submit-to-zone-credit', ms: totalMs, clock: 'wall' },
      ],
    }))
  context.timings.record(timing)
}

function callbackReverted(context: E2eZoneContext, processed: { transactionHash: Hex }) {
  return new Error(
    `Zone callback reverted in transaction ${processed.transactionHash} for ${context.deploymentId}`,
  )
}

/** The EarnRouter event the Portal's callback emitted for one leg, scoped to this stack. */
function routerEvent<const Name extends 'EarnDeposit' | 'EarnRedeem'>(
  context: E2eZoneContext,
  leg: { actionId: Hex; processed: { transactionHash: Hex } },
  eventName: Name,
) {
  return processedRouterEvent(context.l1Public, {
    transactionHash: leg.processed.transactionHash,
    router: context.contracts.earnRouter,
    earnVault: context.contracts.earnVault,
    actionId: leg.actionId,
    eventName,
  })
}

async function routerDelivery(
  context: E2eZoneContext,
  leg: Awaited<ReturnType<typeof submitRouterLeg>>,
  options: { token: Address; gross: bigint; hash: Hex; recipient?: E2eActor },
) {
  const receipt = await context.l1Public.getTransactionReceipt({
    hash: leg.processed.transactionHash,
  })
  const deposit = portalDeposit(receipt.logs, {
    portal: context.deployment.network.zone.portal,
    sender: context.contracts.earnRouter,
    token: options.token,
    gross: options.gross,
    hash: options.hash,
  })
  await waitForDepositDelivery(context, {
    hash: deposit.hash,
    token: options.token,
    sender: context.contracts.earnRouter,
    recipient: context.actors[options.recipient ?? 'user'].account.address,
    amount: deposit.netAmount,
    fromBlock: leg.zoneFromBlock,
  })
  return deposit
}

function routerDeposits(context: E2eZoneContext, fromBlock: bigint) {
  return context.l1Public.getLogs({
    address: context.contracts.earnRouter,
    event: depositEvent,
    fromBlock,
    toBlock: 'latest',
    strict: true,
  })
}

/** Whether a bounced router return refunds to the acting account itself rather than a delegate. */
export async function refundsToSelf(context: E2eContext, actor: Address) {
  const recipients = await zoneRefundRecipients(context)
  return !recipients || recipients.get(getAddress(actor)) === getAddress(actor)
}

/**
 * Skips a case whose router returns refund to an actor that is not an admitted Zone account, before
 * it mints EarnShare that a later return could not reclaim.
 */
export async function requireSelfRefunds(context: E2eContext, actors: readonly E2eActor[]) {
  for (const actor of actors) {
    if (!(await refundsToSelf(context, context[actor].address))) {
      throw new E2ePrerequisiteError(
        `The ${actor} is not an admitted Zone account, so its router returns have no verified Tempo refund recipient`,
      )
    }
  }
}

/** The acting account's verified Tempo refund recipient; itself unless the Zone enforces admission. */
async function tempoRefundRecipient(context: E2eZoneContext, actor: Address) {
  const recipients = await zoneRefundRecipients(context)
  if (!recipients) return actor
  const recipient = recipients.get(getAddress(actor))
  if (!recipient) {
    throw new Error(
      `${actor} is not an admitted Zone account and has no verified Tempo refund recipient`,
    )
  }
  return recipient
}

async function withdrawalParameters(
  context: E2eZoneContext,
  actor: E2eActor,
  funded: boolean | undefined,
) {
  // A funded flow already passed readiness and funded its fee, keeping both out of measured latency.
  if (!funded) {
    await ensureZoneReady(context)
    await fundPrivateFeeBuffer(context, actor)
  }
  const { account, zone } = context.actors[actor]
  // Hosted Zones currently revert while eth_fillTransaction estimates requestWithdrawal,
  // even though the same signed transaction executes successfully. Supplying every
  // fillable field keeps viem on the normal signed-transaction path.
  const [maxFeePerGas, nonce] = await Promise.all([
    getGasPrice(zone.client),
    getTransactionCount(zone.client, { address: account.address }),
  ])
  return {
    chain: zone.client.chain,
    feeToken: context.deployment.network.pathUsd,
    gas: ZONE_WITHDRAWAL_TRANSACTION_GAS,
    maxFeePerGas,
    maxPriorityFeePerGas: 0n,
    nonce,
  } as const
}

export async function fundPrivateFeeBuffer(context: E2eContext, actor: E2eActor = 'user') {
  requireE2eZone(context)
  await ensureZoneReady(context)
  const { account, zone } = context.actors[actor]
  if ((await getGasPrice(zone.client)) === 0n) return
  // Fund every withdrawal independently: a recent encrypted balance read is not a reliable
  // spendability guarantee.
  await ensureFeeBalance(context, account.address)
  await encryptedEntry(context, context.deployment.network.pathUsd, ZONE_FEE_BUFFER, actor)
}

/** Deposits `amount` of `token` into `actor`'s own Zone balance through the Portal. */
async function encryptedEntry(
  context: E2eZoneContext,
  token: Address,
  amount: bigint,
  actor: E2eActor = 'user',
) {
  const { account, wallet } = context.actors[actor]
  const fee = await context.l1Public.readContract({
    address: context.deployment.network.zone.portal,
    abi: Abis.zonePortal,
    functionName: 'calculateDepositFee',
  })
  const gross = amount + fee
  await fundAsset(context, token, gross, actor)
  const before = await zoneBalance(context, token, actor)
  const fromBlock = await context.actors[actor].zone.client.getBlockNumber()
  const result = await wallet.zone.encryptedDepositSync({
    amount: gross,
    recipient: account.address,
    timeout: TIMEOUT_MS,
    token,
    portalAddress: context.deployment.network.zone.portal,
    zoneId: context.deployment.network.zone.id,
  })
  const receipt =
    result.receipt.status === 'pending'
      ? await context.l1Public.waitForTransactionReceipt({
          hash: result.receipt.transactionHash,
          timeout: TIMEOUT_MS,
        })
      : result.receipt
  assert(receipt.status === 'success', 'Portal funding transaction did not succeed')
  const deposit = portalDeposit(receipt.logs, {
    portal: context.deployment.network.zone.portal,
    sender: account.address,
    token,
    gross,
  })
  assert(
    deposit.netAmount >= amount,
    'Portal fee changed during funding; requested private balance was not funded',
  )
  await waitForDepositDelivery(context, {
    hash: deposit.hash,
    token,
    sender: account.address,
    recipient: account.address,
    amount: deposit.netAmount,
    fromBlock,
  })
  await waitForZoneCredit(context, {
    token,
    actor,
    before,
    expected: deposit.netAmount,
    exact: true,
    message: `Zone did not credit the ${actor}'s Portal entry`,
  })
  return result
}

export function zoneBalance(context: E2eContext, token: Address, actor: E2eActor = 'user') {
  requireE2eZone(context)
  const { account, zone } = context.actors[actor]
  return zone.client.readContract({
    address: token,
    abi: Abis.tip20,
    functionName: 'balanceOf',
    args: [account.address],
  })
}

/**
 * Polls one actor's Zone balance until it has risen by at least `expected` over `before`, and
 * returns the credit. An imported Tempo block does not mean the Zone has applied every deposit in
 * it yet, so a single read right after the transaction races the credit. `exact` also rejects an
 * overshoot. Failures name the expected and observed credit.
 */
export async function waitForZoneCredit(
  context: E2eContext,
  parameters: {
    token: Address
    actor?: E2eActor | undefined
    before: bigint
    expected: bigint
    exact?: boolean | undefined
    message: string
  },
) {
  const { before, expected, message } = parameters
  let credit = 0n
  try {
    await waitFor(
      message,
      async () => {
        credit = (await zoneBalance(context, parameters.token, parameters.actor)) - before
        return credit >= expected ? credit : undefined
      },
      { intervalMs: context.pollingInterval },
    )
  } catch (error) {
    throw new Error(`${message}: expected ${expected}, observed ${credit}; ${errorSummary(error)}`)
  }
  if (parameters.exact && credit !== expected) {
    throw new Error(`${message}: expected ${expected}, observed ${credit}`)
  }
  return credit
}
