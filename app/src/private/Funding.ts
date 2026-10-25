import type { ZoneConfiguration } from '@tempoxyz/earn/deployments'
import { waitForZoneCredit, waitForZoneTempoBlock } from '@tempoxyz/earn/tempo/zone'
import type { Account, Address, Client, PublicClient } from 'viem'
import { Actions as TempoActions } from 'viem/tempo'

import type { CatalogStack } from '../../deployments/catalog.js'
import { tokenMetadata } from '../../deployments/tokens.js'
import * as Environment from '../deployments/Environment.js'
import * as Errors from '../Errors.js'
import * as Tempo from '../Tempo.js'
import type { TransactionToast } from '../transactions/Toasts.js'
import * as Admission from './Admission.js'
import * as Position from './Position.js'
import type * as Zone from './Zone.js'

/** Moves one public Tempo token balance into the authenticated Zone account. */
export async function execute(options: execute.Options) {
  const id = `${options.flowId}-encrypted-deposit`
  const zoneLabel = Environment.displayName(options.zone.name)
  const symbol = tokenMetadata(options.deployment, options.token).symbol
  options.onTransaction({
    environment: 'Tempo L1',
    id,
    message: `Funding ${zoneLabel}`,
    status: 'pending',
  })
  try {
    const [before] = await Promise.all([
      Position.balance(options.zoneClient, options.token, options.account.address),
      Admission.assertDepositorAdmitted(options.l1Client, {
        account: options.account.address,
        portal: options.zone.portal,
        token: options.token,
        zoneLabel,
      }),
    ])
    const result = await Tempo.sendWithFaucetRetry(
      () =>
        TempoActions.zone.encryptedDepositSync(options.walletClient, {
          account: options.account,
          amount: options.amount,
          chain: options.walletClient.chain,
          ...(options.sponsorUrl ? { feePayer: true as const } : {}),
          portalAddress: options.zone.portal,
          recipient: options.account.address,
          timeout: Tempo.transactionTimeout,
          token: options.token,
          zoneId: options.zone.id,
        }),
      options.sponsorUrl ? undefined : options.fundFees,
    )
    options.onTransaction({
      detail: `Waiting for ${zoneLabel}.`,
      environment: 'Tempo L1',
      hash: result.receipt.transactionHash,
      id,
      message: 'Deposit confirmed',
      status: 'pending',
    })
    await waitForZoneTempoBlock(options.zoneClient, {
      tempoBlockNumber: result.receipt.blockNumber,
      pollingInterval: 2_000,
      timeout: Tempo.transactionTimeout,
    })
    // The Zone importing the block proves only that it processed it, not that this deposit credited.
    await waitForZoneCredit(options.zoneClient, {
      account: options.account.address,
      amount: options.amount,
      before,
      token: options.token,
      pollingInterval: 2_000,
      timeout: Tempo.transactionTimeout,
    })
    options.onTransaction({
      detail: `${symbol} settled privately.`,
      environment: 'Tempo L1',
      hash: result.receipt.transactionHash,
      id,
      message: `${zoneLabel} funded`,
      steps: [
        `Approved ${symbol} for the Zone Portal`,
        'Submitted the encrypted recipient and deposit to the Zone Portal',
        `${zoneLabel} processed the parent-chain block`,
        'Credited the authenticated private balance',
      ],
      status: 'success',
    })
    return result
  } catch (error) {
    options.onTransaction({
      environment: 'Tempo L1',
      error,
      id,
      message: Errors.message(error),
      status: 'error',
    })
    throw error
  }
}

export declare namespace execute {
  type Options = {
    account: Account
    amount: bigint
    deployment: CatalogStack
    flowId: string
    /** Funds the sender after an insufficient-funds failure on a self-funded testnet. */
    fundFees?: (() => Promise<unknown>) | undefined
    l1Client: Pick<PublicClient, 'simulateContract'>
    onTransaction: (transaction: TransactionToast) => void
    sponsorUrl?: string | undefined
    token: Address
    walletClient: Client
    zone: ZoneConfiguration
    zoneClient: Zone.Client
  }
}
