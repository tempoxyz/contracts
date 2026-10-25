import type { PrivyViemAccount } from '@privy-io/react-auth/tempo'
import { keccak256, parseSignature } from 'viem'
import type { ZoneConfiguration } from '@tempoxyz/earn/deployments'
import { Transaction } from 'viem/tempo'

import * as Zone from './Zone.js'

/** Creates a browser-owned Zone client backed by the user's Privy wallet. */
export function createPrivateZoneClient(options: createPrivateZoneClient.Options) {
  const account = createZoneAccount(options.account)
  const client = Zone.create({
    account,
    environmentId: options.environmentId,
    sourceId: options.sourceId,
    zone: options.zone,
  })
  return { account, client }
}

export declare namespace createPrivateZoneClient {
  type Options = {
    account: PrivyViemAccount
    environmentId: string
    sourceId: number
    zone: ZoneConfiguration
  }
}

/** Signs Zone transactions through Privy's raw secp256k1 method.
 *
 * Privy's Tempo transaction endpoint recognizes the public Tempo chain but not
 * Zone chain IDs. The raw signer is chain-agnostic, while viem still owns the
 * Tempo transaction serialization and digest.
 */
function createZoneAccount(account: PrivyViemAccount) {
  return {
    ...account,
    signTransaction: async (
      transaction: Record<string, unknown>,
      options?: { serializer?: typeof Transaction.serialize },
    ) => {
      const serializer = options?.serializer ?? Transaction.serialize
      const presign =
        transaction.feePayerSignature !== undefined && transaction.feePayerSignature !== null
          ? { ...transaction, feePayerSignature: null }
          : transaction
      const hash = keccak256(await serializer(presign as never))
      const signature = parseSignature(await account.sign!({ hash }))
      return await serializer(transaction as never, signature as never)
    },
  } as PrivyViemAccount
}
