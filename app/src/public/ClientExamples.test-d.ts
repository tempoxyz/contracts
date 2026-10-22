import {
  createClient,
  encodeAbiParameters,
  encodeFunctionData,
  http,
  parseAbiParameters,
  type Address,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { sendTransaction, simulateCalls, waitForTransactionReceipt } from 'viem/actions'
import { tempoModerato } from 'viem/chains'
import { Abis, Actions, createClient as createTempoClient, http as tempoHttp } from 'viem/tempo'
import { tempoModerato as tempoModerato_ } from 'viem/tempo/chains'

/** Keeps the public client-integration guide examples aligned with the pinned viem API. */
export async function clientExamples(parameters: {
  earnVault: Address
  gateway: Address
  privateKey: `0x${string}`
}) {
  const account = privateKeyToAccount(parameters.privateKey)
  const client = createClient({ account, chain: tempoModerato, transport: http() })
  const vault = await Actions.earn.getVault(client, { vault: parameters.earnVault })
  const decoratedClient = createTempoClient({
    account,
    chain: tempoModerato_,
    transport: tempoHttp(),
  })
  await decoratedClient.earn.getVault({ vault: parameters.earnVault })

  const deposited = await Actions.earn.depositSync(client, {
    assetAmount: 100_000_000n,
    shareAmount: 99_900_000n,
    slippageBps: 50,
    vault: parameters.earnVault,
  })
  const quoted = await Actions.earn.getRedeemQuote(client, {
    shareAmount: deposited.shareAmount,
    vault: parameters.earnVault,
  })
  await Actions.earn.redeemSync(client, {
    assetAmount: quoted,
    shareAmount: deposited.shareAmount,
    slippageBps: 50,
    vault: parameters.earnVault,
  })

  const calls = Actions.earn.deposit.calls({
    assetAmount: 100_000_000n,
    assetToken: vault.assetToken,
    recipient: account.address,
    shareAmountMin: 99_500_000n,
    vault: parameters.earnVault,
  })
  const simulation = await simulateCalls(client, {
    account: account.address,
    calls,
    validation: false,
  })
  if (simulation.results.some((result) => result.status === 'failure'))
    throw new Error('Earn deposit simulation failed.')
  const hash = await sendTransaction(client, { calls })
  const receipt = await waitForTransactionReceipt(client, { hash })
  if (receipt.status !== 'success') throw new Error(`Transaction ${hash} reverted.`)

  const shareAmount = 50_000_000n
  const engineData = encodeAbiParameters(
    parseAbiParameters(
      '(address assetOut, uint16 discountBps, uint24 secondsToDeadline, uint128 minQueuedAssets)',
    ),
    // minQueuedAssets is the absolute payout floor from a fresh Queue quote; zero reverts.
    [
      {
        assetOut: vault.assetToken,
        discountBps: 10,
        secondsToDeadline: 259_200,
        minQueuedAssets: 49_750_000n,
      },
    ],
  )
  const queuedCalls = [
    {
      data: encodeFunctionData({
        abi: Abis.tip20,
        args: [parameters.earnVault, shareAmount],
        functionName: 'approve',
      }),
      to: vault.shareToken,
    },
    {
      data: encodeFunctionData({
        abi: Abis.earnVault,
        args: [shareAmount, engineData, account.address],
        functionName: 'requestRedeem',
      }),
      to: parameters.earnVault,
    },
  ] as const
  await sendTransaction(client, { calls: queuedCalls })

  const prepared = await Actions.earn.privateDeposit.prepare(client, {
    assetAmount: 100_000_000n,
    gateway: parameters.gateway,
    recipient: account.address,
    tempoRefundRecipient: account.address,
    shareAmountMin: 99_500_000n,
    vault: parameters.earnVault,
    zoneId: 1,
  })
  await Actions.earn.waitForPrivateDeposit(client, {
    actionId: prepared.actionId,
    fromBlock: prepared.fromBlock,
    gateway: parameters.gateway,
    vault: parameters.earnVault,
  })
}
