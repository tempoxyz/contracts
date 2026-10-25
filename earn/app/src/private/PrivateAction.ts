import { formatUnits, type Account, type Address, type Hex, type PublicClient } from 'viem'
import { engineDefinitions, type ZoneConfiguration } from '@tempoxyz/earn/deployments'
import {
  processedRouterEvent,
  waitForWithdrawalProcessed,
  waitForZoneCredit,
  waitForZoneTempoBlock,
} from '@tempoxyz/earn/tempo/zone'
import { getGasPrice, getTransactionCount } from 'viem/actions'
import { Actions as TempoActions } from 'viem/tempo'

import type { CatalogStack } from '../../deployments/catalog.js'
import { privateRouteAsset, tokenMetadata } from '../../deployments/tokens.js'
import * as Environment from '../deployments/Environment.js'
import { actions, privateFlow, type Action } from '../earn/Actions.js'
import * as Errors from '../Errors.js'
import * as Tempo from '../Tempo.js'
import type { TransactionToast } from '../transactions/Toasts.js'
import * as Admission from './Admission.js'
import * as Liquidity from './Liquidity.js'
import * as Position from './Position.js'
import * as Zone from './Zone.js'

type Deployment = CatalogStack

const ZONE_WITHDRAWAL_GAS = 20_000_000n
/** Hosted Portal processing can exceed three minutes even when the callback succeeds. */
const WITHDRAWAL_TIMEOUT = 600_000

/** A settled private action's router amounts and the L1 block that settled it. */
type Settlement = {
  inputAmount: bigint
  outputAmount: bigint
  tempoBlockNumber: bigint
  vaultAssets: bigint
}

/**
 * Executes a private vault entry or exit from assets already held in the Zone. The router is fixed
 * to the deployment's one private asset, which enters on deposit and returns on redemption.
 */
export async function execute(options: execute.Options) {
  const { account, action, amount, deployment, earnRouter, l1Client, onTransaction } = options
  const zoneLabel = Environment.displayName(options.zone.name)
  const definition = actions[action]
  const flow = definition.private
  if (!flow || !definition.available(deployment.capabilities)) {
    throw new Error('This action is unavailable.')
  }
  // The router converts 1:1 at par between a distinct private asset and the vault asset.
  const privateAsset = privateRouteAsset(deployment)
  if (!privateAsset) throw new Error('Private swap pair is not registered for this deployment.')
  const activity = routerActivity(deployment, action, privateAsset)

  const client = l1Client as PublicClient
  // viem's `prepare` reads only through `eth_*`, which the Worker forwards, and rechecks the
  // router's Zone, EarnVault, asset, EarnShare, and flow bindings. The user is also its refund and
  // fallback recipient.
  const { conversionAmount, prepared } = await flow.prepare(client, {
    amount,
    quote: (value) => definition.quote(client, deployment, value),
    target: {
      assetToken: privateAsset,
      gateway: earnRouter,
      portalAddress: options.zone.portal,
      recipient: account.address,
      tempoRefundRecipient: account.address,
      vault: deployment.contracts.earnVault,
      zoneId: options.zone.id,
    },
  })
  const tokens = { asset: privateAsset, earnShare: deployment.contracts.earnShare }
  const returnedToken = tokens[definition.output]
  // A deposit consumes pool vault-asset inventory; a redemption consumes private-asset inventory.
  Liquidity.assertConvertible({
    action,
    amount: conversionAmount,
    status: await Liquidity.read(l1Client, earnRouter),
    token:
      flow.inventoryToken === 'vaultAsset'
        ? deployment.expectedMetadata.asset
        : tokenMetadata(deployment, privateAsset),
  })
  // Refuse before withdrawing: the Zone would bounce a router return refunded to an unadmitted user.
  await Admission.assertRefundRecipientAdmitted(l1Client, {
    callbackData: prepared.data,
    portal: options.zone.portal,
    router: earnRouter,
    token: returnedToken,
    zoneLabel,
  })
  const [maxFeePerGas, nonce, pendingKeyAuthorization, withdrawalFee] = await Promise.all([
    getGasPrice(options.zoneClient),
    getTransactionCount(options.zoneClient, { address: account.address }),
    Zone.pendingKeyAuthorization(account, options.zone.chainId),
    TempoActions.zone.getWithdrawalFee(options.zoneClient, { callbackGas: prepared.callbackGas }),
  ])
  // The withdrawal approves only its amount, so a Zone fee on top would revert after signing.
  if (withdrawalFee > 0n) {
    throw new Errors.UserFacingError(
      `${zoneLabel} charges a withdrawal fee, which private Earn actions do not cover yet.`,
    )
  }
  const withdrawalId = `${options.flowId}-zone-withdrawal`
  onTransaction({
    environment: zoneLabel,
    id: withdrawalId,
    message: 'Submitting Zone withdrawal',
    status: 'pending',
  })
  let withdrawalSenderTag: Hex | undefined
  try {
    const withdrawal = await options.zoneClient.zone.requestWithdrawalSync({
      ...prepared,
      account,
      chain: options.zoneClient.chain,
      feeToken: options.feeToken,
      gas: ZONE_WITHDRAWAL_GAS,
      ...(pendingKeyAuthorization
        ? { keyAuthorization: pendingKeyAuthorization.authorization }
        : {}),
      maxFeePerGas,
      maxPriorityFeePerGas: 0n,
      nonce,
    })
    if (pendingKeyAuthorization)
      await pendingKeyAuthorization.manager.remove(pendingKeyAuthorization.key)
    withdrawalSenderTag = withdrawal.senderTag
    onTransaction({
      detail: 'Sent to EarnRouter.',
      environment: zoneLabel,
      hash: withdrawal.receipt.transactionHash,
      id: withdrawalId,
      message: 'Zone withdrawal confirmed',
      steps: [
        `Debited the private ${tokenMetadata(deployment, prepared.token).symbol} balance`,
        'Queued the withdrawal for Tempo L1',
        'Attached the EarnRouter callback payload',
      ],
      status: 'success',
    })
  } catch (error) {
    onTransaction({
      environment: zoneLabel,
      error,
      id: withdrawalId,
      message: Errors.message(error),
      status: 'error',
    })
    throw error
  }
  if (!withdrawalSenderTag) throw new Error('Zone withdrawal did not return an L1 sender tag.')
  const callbackId = `${options.flowId}-router-callback`
  onTransaction({
    environment: 'Tempo L1',
    id: callbackId,
    message: 'Waiting for L1 withdrawal processing',
    status: 'pending',
  })
  let settlement: Settlement
  let l1TransactionHash: Hex | undefined
  let before: bigint
  try {
    // Measured after the withdrawal and its fee, so the return must add the full router output.
    before = await submittedBalance(options.zoneClient, returnedToken, account.address)
    const processed = await waitForWithdrawalProcessed(l1Client, {
      portal: options.zone.portal,
      to: earnRouter,
      senderTag: withdrawalSenderTag,
      fromBlock: prepared.fromBlock,
      pollingInterval: 2_000,
      timeout: WITHDRAWAL_TIMEOUT,
    })
    l1TransactionHash = processed.transactionHash
    if (!processed.args.callbackSuccess) {
      throw new Errors.UserFacingError(
        `The L1 withdrawal was processed, but the EarnRouter callback reverted in transaction ${processed.transactionHash}.`,
      )
    }
    // This EarnVault's router event for the action, from the processing receipt.
    const { args, blockNumber } = await processedRouterEvent(l1Client, {
      transactionHash: processed.transactionHash,
      router: earnRouter,
      earnVault: deployment.contracts.earnVault,
      actionId: prepared.actionId,
      eventName: flow.event,
    })
    settlement = {
      inputAmount: 'inputAmount' in args ? args.inputAmount : args.earnShares,
      outputAmount: 'outputAmount' in args ? args.outputAmount : args.earnShares,
      tempoBlockNumber: blockNumber,
      vaultAssets: args.vaultAssets,
    }
    onTransaction({
      detail: activity.detail(settlement),
      environment: 'Tempo L1',
      hash: l1TransactionHash,
      id: callbackId,
      message: 'Vault transaction confirmed',
      steps: activity.steps,
      status: 'pending',
    })
  } catch (error) {
    onTransaction({
      environment: 'Tempo L1',
      error,
      hash: l1TransactionHash,
      id: callbackId,
      message: Errors.message(error),
      status: 'error',
    })
    throw error
  }
  try {
    await waitForZoneTempoBlock(options.zoneClient, {
      tempoBlockNumber: settlement.tempoBlockNumber,
      pollingInterval: 2_000,
      timeout: Tempo.transactionTimeout,
    })
    // The router event names the exact output; any smaller increase is not this action's return.
    const credited = await waitForZoneCredit(options.zoneClient, {
      account: account.address,
      amount: settlement.outputAmount,
      before,
      token: returnedToken,
      pollingInterval: 2_000,
      timeout: Tempo.transactionTimeout,
    })
    onTransaction({
      detail: activity.detail(settlement),
      environment: 'Tempo L1',
      hash: l1TransactionHash,
      id: callbackId,
      message: `Private ${action} complete`,
      steps: [
        ...activity.steps,
        'Encrypted the callback output for the authenticated Zone recipient',
        `Settled the private output in ${zoneLabel}`,
      ],
      status: 'success',
    })
    return { amount: credited }
  } catch (error) {
    onTransaction({
      detail: activity.detail(settlement),
      environment: 'Tempo L1',
      error,
      hash: l1TransactionHash,
      id: callbackId,
      message: `Vault executed, but private return failed: ${Errors.message(error)}`,
      steps: activity.steps,
      status: 'error',
    })
    throw error
  }
}

export declare namespace execute {
  type Options = {
    account: Account
    action: Action
    amount: bigint
    deployment: Deployment
    earnRouter: Address
    /** The Zone fee token, the environment's PATHUSD. */
    feeToken: Address
    flowId: string
    l1Client: ReturnType<typeof Tempo.createClient>
    onTransaction: (transaction: TransactionToast) => void
    zone: ZoneConfiguration
    zoneClient: Zone.Client
  }
}

/**
 * Reads the return baseline once the withdrawal is already submitted, retrying a transient failure:
 * giving up here would stop tracking a withdrawal that is still in flight.
 */
async function submittedBalance(client: Zone.Client, token: Address, account: Address) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await Position.balance(client, token, account)
    } catch (error) {
      if (attempt === 3) {
        throw new Errors.UserFacingError(
          `The Zone withdrawal was submitted, but its return cannot be tracked (${Errors.message(error)}). Check the private balance before retrying.`,
        )
      }
      await new Promise((resolve) => setTimeout(resolve, 2_000))
    }
  }
}

/** The router activity copy of one private action: its steps, and its detail once it settles. */
function routerActivity(deployment: Deployment, action: Action, privateAsset: Address) {
  const definition = actions[action]
  const flow = privateFlow(action)
  const asset = deployment.expectedMetadata.asset
  const earnShare = deployment.expectedMetadata.earnShare
  const token = tokenMetadata(deployment, privateAsset)
  const metadata = { asset: token, earnShare }
  const input = metadata[definition.input]
  const output = metadata[definition.output]
  const { engineContract, venueLabel } = engineDefinitions[deployment.engineKind]
  return {
    detail: (settlement: Settlement) =>
      flow.detail({
        engine: `${engineContract}/${venueLabel}`,
        input: `${formatUnits(settlement.inputAmount, input.decimals)} ${input.symbol}`,
        output: `${formatUnits(settlement.outputAmount, output.decimals)} ${output.symbol}`,
        vault: `${formatUnits(settlement.vaultAssets, asset.decimals)} ${asset.symbol}`,
      }),
    steps: flow.steps({
      asset: asset.symbol,
      earnShare: earnShare.symbol,
      engineContract,
      token: token.symbol,
      venueLabel,
    }),
  }
}
