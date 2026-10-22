import { configuredZoneChain, type ZoneConfiguration } from '@tempoxyz/earn/deployments'
import { readZoneTempoBlock } from '@tempoxyz/earn/tempo/zone'
import { http, type Account, type Address } from 'viem'
import { createClient, type Account as TempoAccount } from 'viem/tempo'

/** Creates an account-isolated client for one registered Zone, built from its catalog facts. */
export function create<const account extends Account | Address>(options: create.Options<account>) {
  const { sourceId, zone } = options
  const rpcUrl = `/api/environments/${encodeURIComponent(options.environmentId)}/zone-rpc`
  return createClient({
    account: options.account,
    chain: configuredZoneChain({ sourceId, zone, rpcUrl }),
    transport: http(rpcUrl, { timeout: 10_000 }),
  })
}

export declare namespace create {
  type Options<account extends Account | Address> = {
    account: account
    environmentId: string
    sourceId: number
    zone: ZoneConfiguration
  }
}

/** Reads session-critical state without depending on optional Zone RPC metadata. */
export async function getInfo(client: Client) {
  const [chainId, tempoBlockNumber] = await Promise.all([
    client.getChainId(),
    readZoneTempoBlock(client),
  ])
  return { chainId, tempoBlockNumber }
}

/**
 * Returns an access-key account's key authorization still pending on one chain. The next
 * transaction on that chain carries it, and the session removes it once that transaction lands.
 */
export async function pendingKeyAuthorization(account: Account, chainId: number) {
  if (account.source !== 'accessKey') return undefined
  const {
    accessKeyAddress,
    address,
    keyAuthorizationManager: manager,
  } = account as TempoAccount.AccessKeyAccount
  if (!manager) return undefined
  const key = { accessKey: accessKeyAddress, address, chainId }
  const authorization = await manager.get(key)
  return authorization ? { authorization, key, manager } : undefined
}

export type Client = ReturnType<typeof create>
