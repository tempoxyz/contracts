// L1 and Zone clients for the card E2E, as the Bridge run builds them.
import { http, type Account as ViemAccount, type Address, type Transport } from 'viem'
import { createClient as createTempoClient, Store, http as zoneHttp } from 'viem/tempo'

import * as Network from '../../bridge/src/network.js'

type TempoChain = ReturnType<typeof Network.chain>
const publicClient = (chain: TempoChain, transport: Transport) =>
  createTempoClient({ chain, transport })
const walletClient = (chain: TempoChain, transport: Transport, account: ViemAccount) =>
  createTempoClient({ account, chain, transport })
export type PublicClient = ReturnType<typeof publicClient>
export type WalletClient = ReturnType<typeof walletClient>

export function l1Clients(l1: { chainId: number; rpcUrl: string }) {
  const chain = Network.chain(l1.chainId, l1.rpcUrl)
  const transport = http(l1.rpcUrl, { timeout: 60_000 })
  return {
    l1Public: publicClient(chain, transport),
    l1Wallet: (account: ViemAccount) => walletClient(chain, transport, account),
  }
}

/**
 * A Zone client acting as `account`. The private RPC answers only requests carrying the account's
 * authorization token and strips events from receipts, so `receipts` asks for the public RPC.
 */
export function zoneClients(l1ChainId: number, zone: Network.Zone) {
  const chain = {
    ...Network.chain(zone.chainId, zone.rpcUrl, 'Local Tempo Zone'),
    sourceId: l1ChainId,
  }
  return async (account: ViemAccount, receipts = false) => {
    const store = Store.memory()
    const client = walletClient(
      chain,
      zoneHttp(receipts ? zone.publicRpcUrl : zone.rpcUrl, { store, timeout: 60_000 }),
      account,
    )
    await client.zone.signAuthorizationToken({ account, zoneId: zone.zoneId, store })
    return client
  }
}

export type ZoneClient = Awaited<ReturnType<ReturnType<typeof zoneClients>>>
export type { Address }
