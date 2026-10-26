// Starts the disposable Tempo L1 and Zone with the shared `localnet` package, so this run uses the
// same pinned images, genesis and TIP-1091 runtimes as Earn's E2E. Spend adds only its viem chain
// definition and the Zone outbox address.
import { Network as Localnet } from 'localnet'
import { defineChain, getAddress, type Address, type Hex } from 'viem'
import { tempoModerato } from 'viem/tempo/chains'

/** Zone blocks between empty withdrawal batches; localnet starts the Zone with this interval. */
export const zoneBatchIntervalBlocks = 10

export const address = {
  pathUsd: getAddress('0x20C0000000000000000000000000000000000000'),
  zoneFactory: getAddress('0x5aF2000000000000000000000000000000000000'),
  zoneMessenger: getAddress('0x5A4d000000000000000000000000000000000000'),
  zoneOutbox: getAddress('0x1c00000000000000000000000000000000000002'),
}

const containers = { name: `spend-zone-e2e.${crypto.randomUUID()}` }

export async function startL1(zoneFactoryOwner: Address) {
  return Localnet.startL1(zoneFactoryOwner, containers)
}

export type L1 = Awaited<ReturnType<typeof startL1>>

export async function startZone(options: { l1: L1; initialToken: Address; privateKey: Hex }) {
  const zone = await Localnet.startZone({
    client: options.l1.client,
    containers,
    initialToken: options.initialToken,
    l1Port: options.l1.port,
    privateKey: options.privateKey,
  })
  return { ...zone, zoneId: zone.id }
}

export type Zone = Awaited<ReturnType<typeof startZone>>

export function chain(chainId: number, rpcUrl: string, name = 'Local Tempo') {
  return defineChain({
    ...tempoModerato,
    id: chainId,
    name,
    rpcUrls: { default: { http: [rpcUrl] } },
  })
}
