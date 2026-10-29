import { parseEventLogs, type Address } from 'viem'
import { earnContributionControllerAbi, earnVaultAbi } from '@tempoxyz/contracts/abis'
import type { E2eActor, E2eContext } from '../../harness/context.js'
import { approve, tokenBalance } from '../../harness/support/funding.js'
import { write } from '../../harness/support/transactions.js'

// `fund` deliberately catches a failed provider/contribution leg and records zero. Automatic gas
// estimation can therefore settle on that cheaper failure path, so the operator supplies a bounded
// limit and verifies the actual event emitted by the mined transaction.
const REWARD_FUNDING_GAS = 5_000_000n

function engineShares(context: E2eContext) {
  return context.l1Public.readContract({
    address: context.contracts.earnVault,
    abi: earnVaultAbi,
    functionName: 'engineShares',
  })
}

export async function contributeDirectly(
  context: E2eContext,
  input: { assets: bigint; actor?: E2eActor },
) {
  const { account, wallet } = context.actors[input.actor ?? 'user']
  const { earnVault, earnShare } = context.contracts
  const [engineSharesBefore, earnBefore] = await Promise.all([
    engineShares(context),
    tokenBalance(context, earnShare, account.address),
  ])
  await approve(context, wallet, context.assets.base, earnVault, input.assets)
  const receipt = await write(wallet, {
    address: earnVault,
    abi: earnVaultAbi,
    functionName: 'contribute',
    args: [input.assets],
  })
  const [engineSharesAfter, earnAfter] = await Promise.all([
    engineShares(context),
    tokenBalance(context, earnShare, account.address),
  ])
  return {
    earnShareBalanceDelta: earnAfter - earnBefore,
    receipt,
    engineShares: engineSharesAfter - engineSharesBefore,
  }
}

/** Funds rewards through the contribution controller as its owner, pulling from `funder`. */
export async function fundRewards(
  context: E2eContext,
  input: { funder: Address; requestedAssets: bigint; approveFunder?: boolean },
) {
  const controller = context.operations.earnContributionController!
  if (input.approveFunder !== false) {
    await approve(
      context,
      context.actors.user.wallet,
      context.assets.base,
      controller,
      input.requestedAssets,
    )
  }
  const maxEarnShareSupply = await context.l1Public.readContract({
    address: context.contracts.earnVault,
    abi: earnVaultAbi,
    functionName: 'totalEarnShares',
  })
  const receipt = await write(context.actors.operator.wallet, {
    address: controller,
    abi: earnContributionControllerAbi,
    functionName: 'fund',
    args: [input.funder, input.requestedAssets, maxEarnShareSupply],
    gas: REWARD_FUNDING_GAS,
  })
  const [event] = parseEventLogs({
    abi: earnContributionControllerAbi,
    eventName: 'Funded',
    logs: receipt.logs,
    strict: true,
  })
  if (!event) throw new Error('Reward transaction did not emit Funded')
  return { receipt, funded: event.args.fundedAssets }
}
