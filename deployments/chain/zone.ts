import {
  erc20Abi,
  getAbiItem,
  getAddress,
  isAddressEqual,
  parseEventLogs,
  type Address,
  type Hex,
  type Log,
  type PublicClient,
} from 'viem'

import { earnRouterAbi } from '../abis/generated.js'
import {
  tempoStateAbi,
  zoneFactoryAbi,
  zoneInboxAbi,
  zoneMessengerAbi,
  zonePortalAbi,
} from '../abis/external.js'

/** Canonical Tempo ZoneFactory predeploy. */
export const zoneFactoryAddress = '0x5aF2000000000000000000000000000000000000'

/** Canonical Tempo Zone Messenger predeploy. */
export const zoneMessengerAddress = '0x5A4d000000000000000000000000000000000000'

/** Canonical Tempo Zone Inbox predeploy. */
export const zoneInboxAddress = '0x1c00000000000000000000000000000000000001'

/** Zone predeploy reporting the Tempo block the Zone has imported. */
const tempoStateAddress = '0x1c00000000000000000000000000000000000000'

/** The canonical, Factory-registered identity of one Zone. */
export type ZoneIdentity = {
  id: number
  chainId: number
  portal: Address
  messenger: Address
  sequencers: Address[]
}

type L1Client = Pick<PublicClient, 'readContract'>
type ZoneClient = Pick<PublicClient, 'getChainId' | 'readContract'>

/**
 * Discovers the live identity of one configured Zone from the canonical Factory and checks it
 * against the Zone's own RPC, which must also report an imported Tempo block.
 */
export async function discoverZone(options: {
  l1Client: L1Client
  zoneClient: ZoneClient
  zoneId: number
}): Promise<ZoneIdentity> {
  const [zone, chainId, inboxPortal] = await Promise.all([
    registeredZone(options.l1Client, options.zoneId),
    options.zoneClient.getChainId(),
    readInboxPortal(options.zoneClient),
    readZoneTempoBlock(options.zoneClient),
  ])
  requireInboxPortal(inboxPortal, zone.portal)
  return {
    id: zone.id,
    chainId,
    portal: zone.portal,
    messenger: zone.messenger,
    sequencers: zone.sequencers,
  }
}

/**
 * Inspects the complete canonical callback graph of one Zone: the Factory registration, Messenger
 * binding, Portal, encryption key, and sequencer set, plus the Zone RPC when one is given. Protocol
 * precompiles intentionally have empty `eth_getCode`, so functional ABI reads are the only reliable
 * readiness test.
 */
export async function inspectZone(options: {
  id: number
  chainId: number
  l1Client: L1Client
  zoneClient?: ZoneClient | undefined
}) {
  const { id, l1Client } = options
  const [zone, zoneChainId, inboxPortal] = await Promise.all([
    registeredZone(l1Client, id),
    options.zoneClient?.getChainId(),
    options.zoneClient ? readInboxPortal(options.zoneClient) : undefined,
  ])
  if (zoneChainId !== undefined && zoneChainId !== options.chainId) {
    throw new Error(
      `Zone RPC chain ID ${zoneChainId} does not match configured chain ID ${options.chainId}`,
    )
  }
  if (inboxPortal !== undefined) requireInboxPortal(inboxPortal, zone.portal)
  const portal = { address: zone.portal, abi: zonePortalAbi } as const
  const [portalZoneId, portalMessenger, encryptionKeyCount, sequencerCount] = await Promise.all([
    l1Client.readContract({ ...portal, functionName: 'zoneId' }),
    l1Client.readContract({ ...portal, functionName: 'messenger' }),
    l1Client.readContract({ ...portal, functionName: 'encryptionKeyCount' }),
    l1Client.readContract({ ...portal, functionName: 'sequencerCount' }),
  ])
  if (portalZoneId !== id)
    throw new Error(`Portal reports Zone ${portalZoneId}, expected Zone ${id}`)
  if (getAddress(portalMessenger) !== zone.messenger) {
    throw new Error(
      `Portal resolves Messenger ${getAddress(portalMessenger)}, expected ${zone.messenger}`,
    )
  }
  if (encryptionKeyCount === 0n) throw new Error(`Zone ${id} has no registered encryption key`)
  const sequencers = await Promise.all(
    Array.from({ length: Number(sequencerCount) }, (_, index) =>
      l1Client
        .readContract({
          address: zone.portal,
          abi: zonePortalAbi,
          functionName: 'sequencerAt',
          args: [BigInt(index)],
        })
        .then((sequencer) => getAddress(sequencer)),
    ),
  )
  if (!sameAddresses(sequencers, zone.sequencers)) {
    throw new Error(`Factory and Portal sequencers do not match for Zone ${id}`)
  }
  return {
    id,
    chainId: options.chainId,
    portal: zone.portal,
    messenger: zone.messenger,
    sequencers,
    encryptionKeyCount,
  }
}

/** The Factory registration of `zoneId`, whose Messenger must be bound to the canonical Factory. */
export async function registeredZone(l1Client: L1Client, zoneId: number) {
  const [registration, messengerFactory] = await Promise.all([
    l1Client.readContract({
      address: zoneFactoryAddress,
      abi: zoneFactoryAbi,
      functionName: 'zones',
      args: [zoneId],
    }),
    l1Client.readContract({
      address: zoneMessengerAddress,
      abi: zoneMessengerAbi,
      functionName: 'zoneFactory',
    }),
  ])
  if (getAddress(messengerFactory) !== zoneFactoryAddress) {
    throw new Error(
      `Zone Messenger is bound to Factory ${getAddress(messengerFactory)}, expected ${zoneFactoryAddress}`,
    )
  }
  if (registration.zoneId !== zoneId) throw new Error('Zone Factory ID mismatch')
  if (registration.sequencers.length === 0) throw new Error(`Zone ${zoneId} has no sequencers`)
  return {
    id: zoneId,
    portal: getAddress(registration.portal),
    messenger: zoneMessengerAddress as Address,
    sequencers: registration.sequencers.map((sequencer) => getAddress(sequencer)),
  }
}

function readInboxPortal(zoneClient: Pick<PublicClient, 'readContract'>) {
  return zoneClient.readContract({
    address: zoneInboxAddress,
    abi: zoneInboxAbi,
    functionName: 'tempoPortal',
  })
}

function requireInboxPortal(inboxPortal: Address, portal: Address) {
  if (getAddress(inboxPortal) !== portal) {
    throw new Error(`ZoneInbox resolves Portal ${getAddress(inboxPortal)}, expected ${portal}`)
  }
}

function sameAddresses(left: readonly Address[], right: readonly Address[]) {
  const expected = new Set(right)
  return (
    left.length > 0 &&
    new Set(left).size === left.length &&
    left.length === expected.size &&
    left.every((address) => expected.has(address))
  )
}

/** Reads the latest Tempo block the Zone has imported. */
export function readZoneTempoBlock(zoneClient: Pick<PublicClient, 'readContract'>) {
  return zoneClient.readContract({
    address: tempoStateAddress,
    abi: tempoStateAbi,
    functionName: 'tempoBlockNumber',
  })
}

/** Waits until the Zone has imported `tempoBlockNumber`, returning the imported block. */
export async function waitForZoneTempoBlock(
  zoneClient: Pick<PublicClient, 'readContract'>,
  parameters: { tempoBlockNumber: bigint; pollingInterval: number; timeout: number },
) {
  const deadline = Date.now() + parameters.timeout
  while (Date.now() < deadline) {
    const current = await readZoneTempoBlock(zoneClient)
    if (current >= parameters.tempoBlockNumber) return current
    await new Promise((resolve) => setTimeout(resolve, parameters.pollingInterval))
  }
  throw new Error(`Timed out waiting for Zone Tempo block ${parameters.tempoBlockNumber}`)
}

/**
 * Waits until `account`'s Zone balance of `token` exceeds `before` by at least `amount`, returning
 * the increase. A Zone cursor or any net increase alone cannot prove that one specific deposit was
 * credited, since an unrelated deposit can land in the same window.
 */
export async function waitForZoneCredit(
  zoneClient: Pick<PublicClient, 'readContract'>,
  parameters: {
    account: Address
    amount: bigint
    before: bigint
    token: Address
    pollingInterval: number
    timeout: number
  },
) {
  const deadline = Date.now() + parameters.timeout
  let credited = 0n
  while (Date.now() < deadline) {
    const balance = await zoneClient.readContract({
      address: parameters.token,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [parameters.account],
    })
    credited = balance - parameters.before
    if (credited >= parameters.amount) return credited
    await new Promise((resolve) => setTimeout(resolve, parameters.pollingInterval))
  }
  throw new Error(
    `Timed out waiting for the Zone to credit ${parameters.amount}; it credited ${credited > 0n ? credited : 0n}`,
  )
}

const withdrawalProcessedEvent = getAbiItem({ abi: zonePortalAbi, name: 'WithdrawalProcessed' })

/**
 * Waits for the source Portal to process one Zone withdrawal to `to`, keyed on the withdrawal's
 * unique sender tag, and returns its `WithdrawalProcessed` log. The tag correlates the two legs only
 * in memory: never log, persist, or surface it.
 */
export async function waitForWithdrawalProcessed(
  l1Client: Pick<PublicClient, 'getLogs'>,
  parameters: {
    portal: Address
    to: Address
    senderTag: Hex
    fromBlock: bigint
    pollingInterval: number
    timeout: number
  },
) {
  const deadline = Date.now() + parameters.timeout
  while (Date.now() < deadline) {
    const [processed] = await l1Client.getLogs({
      address: parameters.portal,
      event: withdrawalProcessedEvent,
      args: { to: parameters.to, senderTag: parameters.senderTag },
      fromBlock: parameters.fromBlock,
      toBlock: 'latest',
      strict: true,
    })
    if (processed) return processed
    await new Promise((resolve) => setTimeout(resolve, parameters.pollingInterval))
  }
  throw new Error('Timed out waiting for the Portal to process the Zone withdrawal on Tempo L1')
}

/**
 * The EarnRouter event a processed withdrawal's callback emitted, from the processing receipt:
 * `router`'s event for `earnVault` with the action's ID. Throws when the callback emitted none.
 */
export async function processedRouterEvent<const Name extends 'EarnDeposit' | 'EarnRedeem'>(
  // Structural, so Tempo clients whose receipts also carry account-operation status qualify.
  l1Client: { getTransactionReceipt(parameters: { hash: Hex }): Promise<{ logs: Log[] }> },
  parameters: {
    transactionHash: Hex
    router: Address
    earnVault: Address
    actionId: Hex
    eventName: Name
  },
) {
  const receipt = await l1Client.getTransactionReceipt({ hash: parameters.transactionHash })
  const event = parseEventLogs({
    abi: earnRouterAbi,
    eventName: parameters.eventName,
    logs: receipt.logs,
    strict: true,
  }).find(
    (log) =>
      isAddressEqual(log.address, parameters.router) &&
      isAddressEqual(log.args.earnVault, parameters.earnVault) &&
      log.args.actionId === parameters.actionId,
  )
  if (!event)
    throw new Error(`EarnRouter callback emitted no ${parameters.eventName} for its action`)
  return event
}

/**
 * Returns the labels of tokens the Portal has not enabled or, with `depositsActive`, whose deposits
 * into the Zone are paused.
 */
export async function missingZoneTokens(
  l1Client: Pick<PublicClient, 'readContract'>,
  portal: Address,
  tokens: readonly (readonly [label: string, token: Address])[],
  options: { depositsActive?: boolean } = {},
) {
  const ready = await Promise.all(
    tokens.map(([, token]) =>
      l1Client.readContract({
        address: portal,
        abi: zonePortalAbi,
        functionName: options.depositsActive ? 'areDepositsActive' : 'isTokenEnabled',
        args: [token],
      }),
    ),
  )
  return tokens.filter((_, index) => !ready[index]).map(([label]) => label)
}

/** Portal roles accepted by `hasRole`; the Portal stores one role per account. */
export const zonePortalRole = { account: 2, callbackGateway: 3 } as const

/**
 * Whether the Portal accepts deposits from a callback gateway `router`: an access-enforced Portal
 * with open gateways admits it only as an account, since the gateway role then grants nothing.
 */
export async function zoneGatewayDepositsAdmitted(
  client: Pick<PublicClient, 'readContract'>,
  portal: Address,
  router: Address,
) {
  const read = (functionName: 'isAccessEnforced' | 'isGatewayOpen') =>
    client.readContract({ address: portal, abi: zonePortalAbi, functionName })
  const [accessEnforced, gatewayOpen] = await Promise.all([
    read('isAccessEnforced'),
    read('isGatewayOpen'),
  ])
  if (!accessEnforced || !gatewayOpen) return true
  return client.readContract({
    address: portal,
    abi: zonePortalAbi,
    functionName: 'hasRole',
    args: [router, zonePortalRole.account],
  })
}

/**
 * Whether the Portal accepts withdrawal callbacks to `gateway`: either it leaves gateways open or
 * `gateway` holds the callback-gateway role.
 */
export async function zoneCallbackGatewayRegistered(
  client: Pick<PublicClient, 'readContract'>,
  portal: Address,
  gateway: Address,
) {
  // Registration is only required while the Portal restricts callback gateways.
  if (
    await client.readContract({
      address: portal,
      abi: zonePortalAbi,
      functionName: 'isGatewayOpen',
    })
  )
    return true
  return client.readContract({
    address: portal,
    abi: zonePortalAbi,
    functionName: 'hasRole',
    args: [gateway, zonePortalRole.callbackGateway],
  })
}
