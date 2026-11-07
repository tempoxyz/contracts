import { isAddressEqual, parseEventLogs, type Address } from 'viem'
import { earnContributionControllerAbi, earnFeesAbi, earnVaultAbi } from '@tempoxyz/contracts/abis'
import type { E2eActor, E2eContext } from '../../harness/context.js'
import { approve, tokenBalance } from '../../harness/support/funding.js'
import { write } from '../../harness/support/transactions.js'
import { fundWithSupplyQuote } from './funding.js'

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
  return fundWithSupplyQuote({
    async quote(atBlock) {
      const blockNumber = atBlock ?? (await context.l1Public.getBlockNumber({ cacheTime: 0 }))
      const vault = {
        address: context.contracts.earnVault,
        abi: earnVaultAbi,
        blockNumber,
      } as const
      const [supply, fees] = await Promise.all([
        context.l1Public.readContract({ ...vault, functionName: 'totalEarnShares' }),
        context.l1Public.readContract({ ...vault, functionName: 'earnFees' }),
      ])
      const preview = await context.l1Public.readContract({
        address: fees,
        abi: earnFeesAbi,
        functionName: 'previewAccruedFees',
        blockNumber,
      })
      return { supply, pendingFeeShares: preview.totalFeeEarnShares }
    },
    async submit(maxEarnShareSupply) {
      const receipt = await write(context.actors.operator.wallet, {
        address: controller,
        abi: earnContributionControllerAbi,
        functionName: 'fund',
        args: [input.funder, input.requestedAssets, maxEarnShareSupply],
        gas: REWARD_FUNDING_GAS,
      })
      const events = parseEventLogs({
        abi: earnContributionControllerAbi,
        eventName: 'Funded',
        logs: receipt.logs.filter((log) => isAddressEqual(log.address, controller)),
        strict: true,
      })
      const [event] = events
      if (
        events.length !== 1 ||
        !event ||
        !isAddressEqual(event.args.funder, input.funder) ||
        event.args.requestedAssets !== input.requestedAssets
      )
        throw new Error('Reward transaction did not emit the expected controller Funded event')
      return { receipt, funded: event.args.fundedAssets }
    },
  })
}
