import {
  encodeFunctionData,
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

  return {
    id,
    chainId: options.chainId,
    portal: zone.portal,
    messenger: zone.messenger,
    sequencers: zone.sequencers,
    encryptionKeyCount: zone.encryptionKeyCount,
  }
}

/** The canonical registered Portal and its current callback graph, including rotated sequencers. */
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
  const portal = { address: getAddress(registration.portal), abi: zonePortalAbi } as const
  const [portalZoneId, messenger, encryptionKeyCount, sequencerCount] = await Promise.all([
    l1Client.readContract({ ...portal, functionName: 'zoneId' }),
    l1Client.readContract({ ...portal, functionName: 'messenger' }),
    l1Client.readContract({ ...portal, functionName: 'encryptionKeyCount' }),
    l1Client.readContract({ ...portal, functionName: 'sequencerCount' }),
  ])
  if (portalZoneId !== zoneId)
    throw new Error(`Portal reports Zone ${portalZoneId}, expected Zone ${zoneId}`)
  if (getAddress(messenger) !== zoneMessengerAddress)
    throw new Error(
      `Portal resolves Messenger ${getAddress(messenger)}, expected ${zoneMessengerAddress}`,
    )
  if (encryptionKeyCount === 0n) throw new Error(`Zone ${zoneId} has no registered encryption key`)
  // The Factory stores creation-time sequencers; the authenticated Portal owns subsequent rotations.
  const sequencers = await Promise.all(
    Array.from({ length: Number(sequencerCount) }, (_, index) =>
      l1Client
        .readContract({ ...portal, functionName: 'sequencerAt', args: [BigInt(index)] })
        .then((sequencer) => getAddress(sequencer)),
    ),
  )
  if (sequencers.length === 0 || new Set(sequencers).size !== sequencers.length)
    throw new Error(`Zone ${zoneId} has an empty or duplicate Portal sequencer set`)
  return {
    id: zoneId,
    portal: portal.address,
    messenger: zoneMessengerAddress as Address,
    sequencers,
    encryptionKeyCount,
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

/** Reads the latest Tempo block the Zone has imported. */
export function readZoneTempoBlock(zoneClient: Pick<PublicClient, 'readContract'>) {
  return zoneClient.readContract({
    address: tempoStateAddress,
    abi: tempoStateAbi,
    functionName: 'tempoBlockNumber',
  })
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
  if (typeof parameters.senderTag !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(parameters.senderTag))
    throw new Error(
      'Withdrawal correlation requires a bytes32 sender tag from a successful source receipt',
    )
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

/**
 * The Portal calls that give the router `role`. The Portal holds one role per account and grants
 * one only from none, so a router admitted under the other gateway mode is moved in one batch:
 * revoke the role it holds, then grant the one the current mode needs.
 */
export async function portalRoleCalls(
  client: Pick<PublicClient, 'readContract'>,
  portal: Address,
  router: Address,
  role: 'account' | 'callbackGateway',
) {
  const other = role === 'account' ? 'callbackGateway' : 'account'
  const setter = { account: 'setAllowedAccount', callbackGateway: 'setGateway' } as const
  const call = (functionName: (typeof setter)[keyof typeof setter], allowed: boolean) => ({
    to: portal,
    data: encodeFunctionData({ abi: zonePortalAbi, functionName, args: [router, allowed] }),
  })
  const holdsOther = await client.readContract({
    address: portal,
    abi: zonePortalAbi,
    functionName: 'hasRole',
    args: [router, zonePortalRole[other]],
  })
  return [...(holdsOther ? [call(setter[other], false)] : []), call(setter[role], true)]
}
