import { encodeAbiParameters, encodeFunctionData, erc20Abi, parseEventLogs, type Hex } from 'viem'

import {
  earnVaultAbi,
  vedaBoringQueueAbi,
  vedaEngineAbi,
  vedaForwardingSolverAbi,
} from '@tempoxyz/contracts/abis'
import type { E2eCase, LaunchFeature } from '../../harness/case.js'
import { engineFixtures, type E2eContext } from '../../harness/context.js'
import {
  approve,
  mintVaultAsset,
  tokenBalance,
  tokenSupply,
} from '../../harness/support/funding.js'
import { deposit } from '../../harness/support/public.js'
import {
  expectRevertedWrite,
  waitForSuccessfulWrite,
  write,
} from '../../harness/support/transactions.js'
import { assert, errorSummary } from '../../harness/support/utils.js'

const AMOUNT = 1_000_000n
const REQUEST_DEADLINE = 3_600
const SOLVE_GAS_LIMIT = 5_000_000n

const engineAsyncAbi = [...vedaEngineAbi, ...earnVaultAbi] as const
const requestDataParameters = [
  {
    type: 'tuple',
    components: [
      { name: 'assetOut', type: 'address' },
      { name: 'discountBps', type: 'uint16' },
      { name: 'secondsToDeadline', type: 'uint24' },
      { name: 'minQueuedAssets', type: 'uint128' },
    ],
  },
] as const

type QueueRequest = readonly [
  bigint,
  `0x${string}`,
  `0x${string}`,
  bigint,
  bigint,
  number,
  number,
  number,
]

export const launchFeatures: Record<string, LaunchFeature> = {
  'queued-redeem': {
    dimensions: ['positive', 'recovery'],
    applies: ({ capabilities }) => capabilities.asyncRedeem,
  },
}

/**
 * Queued redemption through the Veda engine's own periphery. Engine and periphery edge cases are
 * covered by the Veda Solidity tests; this case proves the deployed request lifecycle end to end.
 */
export const cases: readonly E2eCase[] = [
  {
    id: 'veda-async-redeem',
    description:
      'A queued Veda redemption rejects a payout below its minimum, can be cancelled to restore EarnShare, and a tracked request solves and finalizes to its stored receiver atomically.',
    default: false,
    launch: true,
    requiredCapabilities: ['asyncRedeem'],
    coverage: { 'queued-redeem': ['positive', 'recovery'] },
    async run(context) {
      await cancelTrackedRequest(context)
      await solveTrackedRequest(context)
    },
  },
]

async function cancelTrackedRequest(context: E2eContext) {
  const { requestId } = await requestTracked(context, true)
  const earnBefore = await tokenBalance(context, context.contracts.earnShare, context.user.address)
  const pendingBefore = await pendingCount(context)

  const receipt = await write(context.actors.user.wallet, {
    address: context.contracts.earnVault,
    abi: earnVaultAbi,
    functionName: 'cancelRedeem',
    args: [requestId, 1n],
  })

  const earnAfter = await tokenBalance(context, context.contracts.earnShare, context.user.address)
  const event = parseEventLogs({
    abi: earnVaultAbi,
    eventName: 'RedeemCancelled',
    logs: receipt.logs,
  })[0]
  if (!event) throw new Error('EarnVault did not emit RedeemCancelled')
  assert(
    pendingBefore === 1n && (await pendingCount(context)) === 0n,
    'pending claim did not close',
  )
  assert(earnAfter > earnBefore, 'cancellation did not restore EarnShare')
  assert(
    event.args.requestId === requestId && event.args.receiver === context.user.address,
    'cancellation emitted the wrong claim recipient',
  )
  assert(
    earnAfter - earnBefore === event.args.earnShares,
    'cancellation balance did not match its restored-share event',
  )
}

async function solveTrackedRequest(context: E2eContext) {
  const veda = requireVeda(context)
  const { request, requestId } = await requestTracked(context, false)
  const assetsBefore = await tokenBalance(context, context.assets.base, context.user.address)

  const simulation = await context.l1Public.simulateContract({
    account: context.operator,
    address: veda.forwardingSolver,
    abi: vedaForwardingSolverAbi,
    functionName: 'solveAndForward',
    args: [[requestId], false],
    // The engine intentionally catches per-claim finalize failures. Without a floor, gas
    // estimation can select a cheaper successful transaction where the nested finalize runs
    // out of gas and is caught, leaving the claim recoverable but still pending.
    gas: SOLVE_GAS_LIMIT,
  })
  const receipt = await write(context.actors.operator.wallet, simulation.request)

  const assetsAfter = await tokenBalance(context, context.assets.base, context.user.address)
  const solveEvent = parseEventLogs({
    abi: vedaForwardingSolverAbi,
    eventName: 'SolvedAndForwarded',
    logs: receipt.logs,
  })[0]
  const failed = parseEventLogs({
    abi: engineAsyncAbi,
    eventName: 'FinalizeFailed',
    logs: receipt.logs,
  }).filter((event) => event.args.requestId === requestId)
  const finalized = parseEventLogs({
    abi: engineAsyncAbi,
    eventName: 'Finalized',
    logs: receipt.logs,
  }).filter((event) => event.args.requestId === requestId)
  const settled = await context.l1Public.readContract({
    address: context.contracts.engine,
    abi: engineAsyncAbi,
    functionName: 'settled',
    args: [request[2]],
  })
  const pending = await pendingCount(context)
  let recovery = 'not required'
  if (pending !== 0n) {
    try {
      await context.l1Public.simulateContract({
        account: context.user,
        address: context.contracts.engine,
        abi: engineAsyncAbi,
        functionName: 'claimRedeem',
        args: [requestId],
      })
      recovery = 'claim simulation succeeded'
    } catch (error) {
      recovery = errorSummary(error)
    }
  }
  assert(
    pending === 0n,
    `solved claim remained pending: forwarded=${solveEvent?.args.forwardedCount ?? 0n}, finalized=${finalized.length}, failed=${failed.length}, settled=${settled}, recovery=${recovery}`,
  )
  assert(assetsAfter - assetsBefore === request[4], 'solve paid the wrong asset amount')
}

/**
 * Requests a tracked queued redemption of a fresh deposit. With `probeRejection`, a request whose
 * minimum payout exceeds the Queue quote must first revert without changing any accounting.
 */
async function requestTracked(context: E2eContext, probeRejection: boolean) {
  const veda = requireVeda(context)
  const wallet = context.actors.user.wallet
  await mintVaultAsset(context, AMOUNT)
  const { earnShares } = await deposit(context, {
    assets: AMOUNT,
    minimumEarnShares: 1n,
    receiver: context.user.address,
  })
  await approve(
    context,
    wallet,
    context.contracts.earnShare,
    context.contracts.earnVault,
    earnShares,
  )
  const engineShares = await context.l1Public.readContract({
    address: context.contracts.earnVault,
    abi: earnVaultAbi,
    functionName: 'convertToEngineShares',
    args: [earnShares],
  })
  assert(engineShares > 0n, 'async redemption converted to zero engine shares')
  assert(engineShares <= (1n << 128n) - 1n, 'async engine-share quote exceeds uint128')
  const minQueuedAssets = await context.l1Public.readContract({
    address: veda.queue,
    abi: vedaBoringQueueAbi,
    functionName: 'previewAssetsOut',
    args: [context.assets.base, engineShares, 0],
  })
  assert(minQueuedAssets > 0n, 'Veda Queue quoted zero assets')
  assert(minQueuedAssets < (1n << 128n) - 1n, 'Veda Queue quote cannot be raised for rollback test')

  const requestData = (minimum: bigint) =>
    encodeAbiParameters(requestDataParameters, [
      {
        assetOut: context.assets.base,
        discountBps: 0,
        secondsToDeadline: REQUEST_DEADLINE,
        minQueuedAssets: minimum,
      },
    ])
  const sendRequest = (data: Hex, gas?: bigint) =>
    wallet.sendTransaction({
      to: context.contracts.earnVault,
      data: encodeFunctionData({
        abi: earnVaultAbi,
        functionName: 'requestRedeem',
        args: [earnShares, data, context.user.address],
      }),
      gas,
    })
  if (probeRejection) {
    const before = await queuedRequestState(context, veda.queue)
    await expectRevertedWrite(
      context,
      () => sendRequest(requestData(minQueuedAssets + 1n), SOLVE_GAS_LIMIT),
      'Veda queued exit accepted a payout below the user minimum',
    )
    const after = await queuedRequestState(context, veda.queue)
    assert(
      after.every((value, index) => value === before[index]),
      'rejected queued exit changed EarnShare, venue custody, allowance, nonce, or claim counters',
    )
  }
  const receipt = await waitForSuccessfulWrite(
    context,
    await sendRequest(requestData(minQueuedAssets)),
  )
  const event = parseEventLogs({
    abi: earnVaultAbi,
    eventName: 'RedeemRequested',
    logs: receipt.logs,
  })[0]
  if (!event) throw new Error('EarnVault did not emit RedeemRequested')
  const requestId = event.args.requestId
  const request = (await context.l1Public.readContract({
    address: veda.queue,
    abi: vedaBoringQueueAbi,
    functionName: 'getOnChainWithdraw',
    args: [requestId],
  })) as QueueRequest
  assert(request[3] === engineShares, 'tracked Queue request holds the wrong engine-share amount')
  assert(request[4] >= minQueuedAssets, 'tracked Queue payout is below the user minimum')
  return { earnShares, request, requestId }
}

function queuedRequestState(context: E2eContext, queue: `0x${string}`) {
  return Promise.all([
    tokenBalance(context, context.contracts.earnShare, context.user.address),
    tokenSupply(context, context.contracts.earnShare),
    context.l1Public.readContract({
      address: context.contracts.earnShare,
      abi: erc20Abi,
      functionName: 'allowance',
      args: [context.user.address, context.contracts.earnVault],
    }),
    tokenBalance(context, context.contracts.venue, context.contracts.engine),
    tokenBalance(context, context.contracts.venue, queue),
    context.l1Public.readContract({
      address: queue,
      abi: vedaBoringQueueAbi,
      functionName: 'nonce',
    }),
    pendingCount(context),
    context.l1Public.readContract({
      address: context.contracts.engine,
      abi: engineAsyncAbi,
      functionName: 'unresolvedClaimCount',
    }),
  ])
}

function pendingCount(context: E2eContext) {
  return context.l1Public.readContract({
    address: context.contracts.earnVault,
    abi: earnVaultAbi,
    functionName: 'openRedeemRequestCount',
  })
}

function requireVeda(context: E2eContext) {
  const veda = engineFixtures(context, ['forwardingSolver', 'queue'])
  if (!veda) throw new Error('Veda E2E case requires Veda periphery addresses')
  return veda
}
