import { performance } from 'node:perf_hooks'

import { erc20Abi, type Address, type Hash, type Log } from 'viem'
import { earnVaultAbi, simple4626VaultAbi } from '@tempoxyz/earn/abis'
import type { E2eActor, E2eContext } from '../context.js'
import { approve, tokenBalance, tokenSupply } from './funding.js'
import { minimumOutput, previewEarnDeposit } from './slippage.js'
import { wallMs } from './timings.js'
import { write } from './transactions.js'
import { assert, TIMEOUT_MS, waitFor } from './utils.js'

/** The L1 client's own receipt type: Tempo receipts also carry account-operation status. */
type TransactionResult = {
  receipt: Awaited<ReturnType<E2eContext['l1Public']['waitForTransactionReceipt']>>
}

export async function depositIntoVenue(
  context: E2eContext,
  input: { assets: bigint; receiver: Address; actor?: E2eActor },
): Promise<TransactionResult & { venueShares: bigint }> {
  const { wallet } = context.actors[input.actor ?? 'user']
  const { venue } = context.contracts
  const before = await tokenBalance(context, venue, input.receiver)
  await approve(context, wallet, context.assets.base, venue, input.assets)
  const receipt = await write(wallet, {
    address: venue,
    abi: simple4626VaultAbi,
    functionName: 'deposit',
    args: [input.assets, input.receiver],
  })
  const after = await tokenBalance(context, venue, input.receiver)
  return { receipt, venueShares: after - before }
}

/** Redeems venue shares held directly, outside Earn, back to their holder. */
export async function redeemVenueShares(
  context: E2eContext,
  venueShares: bigint,
  actor: E2eActor = 'user',
) {
  const { account, wallet } = context.actors[actor]
  await write(wallet, {
    address: context.contracts.venue,
    abi: simple4626VaultAbi,
    functionName: 'redeem',
    args: [venueShares, account.address, account.address],
  })
}

/** Crystallizes accrued fees, fixing the conversion anchor that later quotes rely on. */
export async function accrueFees(context: E2eContext) {
  return write(context.actors.user.wallet, {
    address: context.contracts.earnVault,
    abi: earnVaultAbi,
    functionName: 'accrueFees',
  })
}

export async function depositVenueShares(
  context: E2eContext,
  input: { venueShares: bigint; receiver: Address; actor?: E2eActor },
): Promise<TransactionResult & { earnShares: bigint; venueSharesSpent: bigint }> {
  const { account, wallet } = context.actors[input.actor ?? 'user']
  const earn = wallet.earn
  const { earnVault, venue } = context.contracts
  await accrueFees(context)
  const expectedEarnShares = await context.l1Public.readContract({
    address: earnVault,
    abi: earnVaultAbi,
    functionName: 'convertEngineSharesToEarnShares',
    args: [input.venueShares],
  })
  const venueBefore = await tokenBalance(context, venue, account.address)
  const hash = await earn.depositShares({
    account,
    earnShareAmountMin: minimumOutput(expectedEarnShares),
    recipient: input.receiver,
    vault: earnVault,
    venueShareAmount: input.venueShares,
    venueShareToken: venue,
  })
  const { event, receipt } = await waitForReceiptEvent(
    context,
    hash,
    'venue-share deposit event',
    (logs) => earn.depositShares.extractEvent(logs, { vault: earnVault }),
  )
  const venueAfter = await tokenBalance(context, venue, account.address)
  return {
    earnShares: event.args.earnShares,
    receipt,
    venueSharesSpent: venueBefore - venueAfter,
  }
}

/** One L1 transaction's submit-to-receipt time, observed at the receipt poll that found it. */
function recordPublicTiming(context: E2eContext, action: string, submitted: number) {
  context.timings.record({
    action,
    phases: [{ phase: 'submit-to-receipt', ms: wallMs(submitted), clock: 'wall' }],
  })
}

/** The atomic approval and deposit the user-facing Earn client sends. */
export async function deposit(
  context: E2eContext,
  input: {
    assets: bigint
    receiver: Address
    actor?: E2eActor
    minimumEarnShares?: bigint
  },
): Promise<TransactionResult & { earnShares: bigint }> {
  const { account, wallet } = context.actors[input.actor ?? 'user']
  const earn = wallet.earn
  const minEarnShares =
    input.minimumEarnShares ?? minimumOutput(await previewEarnDeposit(context, input.assets))
  const submitted = performance.now()
  const hash = await earn.deposit({
    account,
    assetAmount: input.assets,
    recipient: input.receiver,
    shareAmountMin: minEarnShares,
    vault: context.contracts.earnVault,
  })
  const { event, receipt } = await waitForReceiptEvent(context, hash, 'deposit event', (logs) =>
    earn.deposit.extractEvent(logs, { vault: context.contracts.earnVault }),
  )
  recordPublicTiming(context, 'public-deposit', submitted)
  return { receipt, earnShares: event.args.earnShares }
}

/** The atomic approval and redemption the user-facing Earn client sends. */
export async function redeem(
  context: E2eContext,
  input: { earnShares: bigint; receiver: Address; actor?: E2eActor },
): Promise<TransactionResult & { assets: bigint }> {
  const { account, wallet } = context.actors[input.actor ?? 'user']
  const earn = wallet.earn
  const expectedAssets = await context.l1Public.earn.getRedeemQuote({
    shareAmount: input.earnShares,
    vault: context.contracts.earnVault,
  })
  const submitted = performance.now()
  const hash = await earn.redeem({
    account,
    assetAmountMin: minimumOutput(expectedAssets),
    recipient: input.receiver,
    shareAmount: input.earnShares,
    vault: context.contracts.earnVault,
  })
  const { event, receipt } = await waitForReceiptEvent(context, hash, 'redeem event', (logs) =>
    earn.redeem.extractEvent(logs, { vault: context.contracts.earnVault }),
  )
  recordPublicTiming(context, 'public-redeem', submitted)
  return { assets: event.args.assets, receipt }
}

export async function withdrawExact(
  context: E2eContext,
  input: {
    assets: bigint
    maxEarnShares: bigint
    receiver: Address
    actor?: E2eActor
  },
): Promise<TransactionResult & { earnSharesBurned: bigint }> {
  const { account, wallet } = context.actors[input.actor ?? 'user']
  const earn = wallet.earn
  const hash = await earn.withdrawExact({
    account,
    assetAmount: input.assets,
    recipient: input.receiver,
    shareAmountMax: input.maxEarnShares,
    vault: context.contracts.earnVault,
  })
  const { event, receipt } = await waitForReceiptEvent(
    context,
    hash,
    'exact withdrawal event',
    (logs) => earn.withdrawExact.extractEvent(logs, { vault: context.contracts.earnVault }),
  )
  return { receipt, earnSharesBurned: event.args.earnSharesBurned }
}

async function waitForReceiptEvent<Result>(
  context: E2eContext,
  hash: Hash,
  label: string,
  extractEvent: (logs: Log[]) => Result,
) {
  const confirmed = await context.l1Public.waitForTransactionReceipt({ hash, timeout: TIMEOUT_MS })
  if (confirmed.status === 'reverted') throw new Error(`Transaction ${hash} reverted`)
  try {
    return { event: extractEvent(confirmed.logs), receipt: confirmed }
  } catch {
    // Tempo's disposable node can briefly expose a confirmed receipt before its
    // nested batch logs are queryable. Re-read only on that transient path.
  }
  return waitFor(
    label,
    async () => {
      const receipt = await context.l1Public.getTransactionReceipt({ hash })
      return { event: extractEvent(receipt.logs), receipt }
    },
    { timeoutMs: 30_000, intervalMs: context.pollingInterval },
  )
}

/**
 * Runs `reject`, which proves its own rejection, and requires it to leave Earn untouched: each
 * owner's asset, venue, and EarnShare balances and their allowances to the EarnVault, the engine,
 * and `spenders`, plus engine backing, EarnShare supply, engine shares, and open redeem requests.
 */
export async function expectUnchanged(
  context: E2eContext,
  label: string,
  reject: () => Promise<unknown>,
  scope: { owners: readonly Address[]; spenders?: readonly Address[] },
) {
  const before = await earnState(context, scope)
  await reject()
  const after = await earnState(context, scope)
  const changed = [...before].filter(([read, value]) => after.get(read) !== value)
  assert(changed.length === 0, `${label} changed ${changed.map(([read]) => read).join(', ')}`)
}

async function earnState(
  context: E2eContext,
  { owners, spenders = [] }: Parameters<typeof expectUnchanged>[3],
) {
  const { earnShare, earnVault, engine, venue } = context.contracts
  const vault = { address: earnVault, abi: earnVaultAbi } as const
  const reads: [string, Promise<unknown>][] = [
    ['engine backing', tokenBalance(context, venue, engine)],
    ['EarnShare supply', tokenSupply(context, earnShare)],
    ['engine shares', context.l1Public.readContract({ ...vault, functionName: 'engineShares' })],
    [
      'open redeem requests',
      context.l1Public.readContract({ ...vault, functionName: 'openRedeemRequestCount' }),
    ],
  ]
  const tokens = { asset: context.assets.base, venue, EarnShare: earnShare }
  for (const owner of owners) {
    for (const [name, token] of Object.entries(tokens)) {
      reads.push([`${name} balance of ${owner}`, tokenBalance(context, token, owner)])
      for (const spender of [earnVault, engine, ...spenders]) {
        const allowance = context.l1Public.readContract({
          address: token,
          abi: erc20Abi,
          functionName: 'allowance',
          args: [owner, spender],
        })
        reads.push([`${name} allowance of ${owner} to ${spender}`, allowance])
      }
    }
  }
  const values = await Promise.all(reads.map(([, read]) => read))
  return new Map(reads.map(([read], index) => [read, values[index]]))
}
