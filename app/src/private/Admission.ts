import { zonePortalAbi } from '@tempoxyz/earn/abis'
import {
  type Address,
  BaseError,
  ContractFunctionRevertedError,
  decodeAbiParameters,
  type Hex,
  isAddress,
  isAddressEqual,
  type PublicClient,
  zeroHash,
} from 'viem'
import { Abis } from 'viem/tempo'

import { UserFacingError } from '../Errors.js'

/**
 * Rejects a private action whose router return the source Zone would refuse for its refund recipient.
 * The router returns every successful callback with `ZonePortal.depositEncrypted`, which an
 * account-admission Zone rejects unless the Tempo refund recipient holds the `Account` role.
 *
 * The Portal has no admission getter, so this simulates the router's return deposit. It fails only
 * on `AccountNotAllowed` for this exact recipient; any other outcome, including RPC failure, leaves
 * the action to the callback's own checks and bounce path.
 */
export async function assertRefundRecipientAdmitted(
  client: Pick<PublicClient, 'simulateContract'>,
  options: assertRefundRecipientAdmitted.Options,
) {
  const [{ zoneReturn }] = decodeAbiParameters(Abis.earnRouterCallbackData, options.callbackData)
  const { encrypted, keyIndex, refundRecipient } = zoneReturn
  try {
    await client.simulateContract({
      abi: zonePortalAbi,
      account: options.router,
      address: options.portal,
      args: [options.token, 1n, keyIndex, encrypted, refundRecipient],
      functionName: 'depositEncrypted',
    })
  } catch (error) {
    if (rejectsRecipient(error, refundRecipient)) {
      throw new UserFacingError(
        `${options.zoneLabel} returns private conversions only to admitted accounts, and ${refundRecipient} is not admitted. Ask the Zone administrator to admit it.`,
      )
    }
  }
}

export declare namespace assertRefundRecipientAdmitted {
  type Options = {
    /** The prepared router callback, so the simulation returns exactly its encrypted output. */
    callbackData: Hex
    portal: Address
    router: Address
    /** Token the router returns to the Zone for this action. */
    token: Address
    zoneLabel: string
  }
}

function rejectsRecipient(error: unknown, recipient: Address) {
  if (!(error instanceof BaseError)) return false
  const reverted = error.walk((cause) => cause instanceof ContractFunctionRevertedError)
  if (!(reverted instanceof ContractFunctionRevertedError)) return false
  const { data } = reverted
  const account = data?.args?.[0]
  return (
    data?.errorName === 'AccountNotAllowed' &&
    typeof account === 'string' &&
    isAddress(account) &&
    isAddressEqual(account, recipient)
  )
}

/**
 * Rejects Deposit to Zone from a depositor the Zone would refuse. The Portal checks the depositor's
 * `Account` role before the token, payload, or allowance, so this simulates `depositEncrypted` with
 * an empty payload. It fails only on `AccountNotAllowed` for this depositor; any other outcome
 * leaves the deposit to its own transaction.
 */
export async function assertDepositorAdmitted(
  client: Pick<PublicClient, 'simulateContract'>,
  options: assertDepositorAdmitted.Options,
) {
  try {
    await client.simulateContract({
      abi: zonePortalAbi,
      account: options.account,
      address: options.portal,
      args: [options.token, 1n, 0n, emptyPayload, options.account],
      functionName: 'depositEncrypted',
    })
  } catch (error) {
    if (rejectsRecipient(error, options.account)) {
      throw new UserFacingError(
        `${options.zoneLabel} accepts deposits only from admitted accounts, and ${options.account} is not admitted. Ask the Zone administrator to admit it.`,
      )
    }
  }
}

export declare namespace assertDepositorAdmitted {
  type Options = {
    account: Address
    portal: Address
    token: Address
    zoneLabel: string
  }
}

const emptyPayload = {
  ciphertext: '0x',
  ephemeralPubkeyX: zeroHash,
  ephemeralPubkeyYParity: 0,
  nonce: `0x${'00'.repeat(12)}`,
  tag: `0x${'00'.repeat(16)}`,
} as const
