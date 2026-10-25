import {
  encodeFunctionData,
  erc20Abi,
  getAddress,
  toHex,
  type Account,
  type Address,
  type Client,
  type TransactionReceipt,
} from 'viem'
import type { Provider } from 'accounts'
import type { PublicEarnStack, ZoneConfiguration } from '@tempoxyz/earn/deployments'
import { sendTransactionSync } from 'viem/actions'
import { Abis, Account as TempoAccount, Addresses, createClient } from 'viem/tempo'

import * as Errors from '../Errors.js'
import * as Tempo from '../Tempo.js'
import * as Zone from './Zone.js'

type Deployment = PublicEarnStack
type ProviderConnector = { getProvider(): Promise<unknown> }

const ZONE_ACCESS_KEY_LIFETIME_SECONDS = 60 * 60
const ACCESS_KEY_PUBLICATION_RETRY_DELAYS = [0, 250, 500, 1_000] as const

/** Restores an already-published private access key without requesting wallet approval or writes. */
export async function restorePrivateAccessKeyAccount(
  options: restorePrivateAccessKeyAccount.Options,
): Promise<restorePrivateAccessKeyAccount.ReturnType> {
  const { chainId, connector, expected } = options
  const accountsProvider = await getAccountsProvider(connector, chainId)
  const existing = await selectAccessKey(accountsProvider, expected, chainId)
  if (!existing) return undefined

  const account = validateAccessKeyAccount(existing, expected)
  const status = await accountsProvider.getAccessKeyStatus({
    accessKey: account.accessKeyAddress,
    address: expected,
    chainId,
  })
  return status === 'published' ? account : undefined
}

export declare namespace restorePrivateAccessKeyAccount {
  type Options = {
    chainId: number
    connector: ProviderConnector
    expected: Address
  }

  type ReturnType = TempoAccount.AccessKeyAccount | undefined
}

/** Obtains or authorizes the unrestricted session key owned by the connected Accounts provider. */
export async function getPrivateAccessKeyAccount(
  options: getPrivateAccessKeyAccount.Options,
): Promise<getPrivateAccessKeyAccount.ReturnType> {
  const {
    chainId,
    connector,
    deployment,
    expected,
    fundPublication,
    onProgress,
    rpcUrl,
    sponsorUrl,
  } = options
  const accountsProvider = await getAccountsProvider(connector, chainId)
  const publish = (account: Account) =>
    publishAccessKey(accountsProvider, {
      account,
      chainId,
      expected,
      // Publishing reads EarnShare: a harmless call that carries the pending key authorization.
      publicationCall: {
        data: encodeFunctionData({ abi: erc20Abi, functionName: 'balanceOf', args: [expected] }),
        to: getAddress(deployment.contracts.earnShare),
      },
      fundPublication:
        fundPublication && !sponsorUrl
          ? () => reportPrivateSetupProgress('l1-access-key-funding', onProgress, fundPublication)
          : undefined,
      onProgress,
      rpcUrl,
      sponsorUrl,
    })
  const existing = await selectAccessKey(accountsProvider, expected, chainId)
  if (existing) {
    try {
      return await publish(existing)
    } catch (error) {
      if (!shouldReauthorizeAccessKey(error)) throw error
      accountsProvider.store.accessKeys.clear()
    }
  }

  await reportPrivateSetupProgress('l1-access-key-authorization', onProgress, () =>
    accountsProvider.request({
      method: 'wallet_authorizeAccessKey',
      params: [accessKeyAuthorization(chainId)],
    }),
  )
  const authorized = await selectAccessKey(accountsProvider, expected, chainId)
  if (!authorized)
    throw new Error('The account provider did not retain the authorized Zone signer.')
  return await publish(authorized)
}

export declare namespace getPrivateAccessKeyAccount {
  type Options = {
    chainId: number
    connector: ProviderConnector
    deployment: Deployment
    expected: Address
    fundPublication?: (() => Promise<unknown>) | undefined
    onProgress?: ((progress: PrivateSetupProgress) => void) | undefined
    rpcUrl: string
    sponsorUrl?: string | undefined
  }

  type ReturnType = TempoAccount.AccessKeyAccount
}

/** Returns the Accounts SDK L1 client with post-user-signature sponsorship when configured. */
export async function createPrivateL1Client(
  options: createPrivateL1Client.Options,
): Promise<createPrivateL1Client.ReturnType> {
  const { chainId, connector, rpcUrl, sponsorUrl } = options
  const provider = await getAccountsProvider(connector, chainId)
  return createPrivateL1ClientFromProvider(provider, chainId, rpcUrl, sponsorUrl)
}

export declare namespace createPrivateL1Client {
  type Options = {
    chainId: number
    connector: ProviderConnector
    rpcUrl: string
    sponsorUrl?: string | undefined
  }

  type ReturnType = Client
}

function validateAccessKeyAccount(
  account: Account,
  expected: Address,
): TempoAccount.AccessKeyAccount {
  if (
    !account.sign ||
    account.source !== 'accessKey' ||
    !('accessKeyAddress' in account) ||
    getAddress(account.address) !== getAddress(expected)
  ) {
    throw new Error('The account provider returned an invalid private-mode signer.')
  }
  return account as TempoAccount.AccessKeyAccount
}

async function publishAccessKey(provider: AccountsProvider, options: publishAccessKey.Options) {
  const { chainId, expected, fundPublication, onProgress, rpcUrl, sponsorUrl } = options
  const validated = validateAccessKeyAccount(options.account, expected)
  const status = await provider.getAccessKeyStatus({
    accessKey: validated.accessKeyAddress,
    address: expected,
    chainId,
  })
  if (status === 'published') return validated
  if (status === 'expired') throw new Error('The private Zone signer is expired.')

  const pending = await Zone.pendingKeyAuthorization(validated, chainId)
  if (!pending) throw new MissingPendingAccessKeyAuthorizationError()
  onProgress?.({ phase: 'l1-access-key-publication', status: 'pending' })
  let receipt: Pick<TransactionReceipt, 'transactionHash'> | undefined
  try {
    const client = createPrivateL1ClientFromProvider(provider, chainId, rpcUrl, sponsorUrl)
    receipt = await Tempo.sendWithFaucetRetry(
      () =>
        sendTransactionSync(client, {
          account: validated,
          calls: [options.publicationCall],
          ...(sponsorUrl ? { feePayer: true as const } : {}),
          keyAuthorization: pending.authorization,
        }),
      fundPublication,
    )
    const published = await waitForAccessKeyPublication(provider, {
      accessKey: validated.accessKeyAddress,
      address: expected,
      chainId,
    })
    if (!published) {
      throw new Error('The account provider did not publish the authorized Zone signer.')
    }
    onProgress?.({ phase: 'l1-access-key-publication', receipt, status: 'success' })
    return validated
  } catch (error) {
    onProgress?.({
      error,
      message: Errors.message(error),
      phase: 'l1-access-key-publication',
      receipt,
      status: 'error',
    })
    throw error
  }
}

declare namespace publishAccessKey {
  type Options = {
    account: Account
    chainId: number
    expected: Address
    /** Funds the publisher after an insufficient-funds failure; set only when self-funded. */
    fundPublication?: (() => Promise<unknown>) | undefined
    onProgress?: ((progress: PrivateSetupProgress) => void) | undefined
    publicationCall: { data: `0x${string}`; to: Address }
    rpcUrl: string
    sponsorUrl?: string | undefined
  }
}

/** Selects only a locally retained key that can call an arbitrary address, never a scoped one. */
function selectAccessKey(provider: AccountsProvider, account: Address, chainId: number) {
  return provider.store.accessKeys.select({
    account,
    calls: [{ data: '0x', to: getAddress(account) }],
    chainId,
  })
}

/** A short-lived authorization with unrestricted calls and token spending on one chain. */
function accessKeyAuthorization(chainId: number) {
  return {
    chainId: toHex(chainId),
    expiry: Math.floor(Date.now() / 1_000) + ZONE_ACCESS_KEY_LIFETIME_SECONDS,
  } as const
}

function createPrivateL1ClientFromProvider(
  provider: AccountsProvider,
  chainId: number,
  rpcUrl: string,
  sponsorUrl?: string | undefined,
) {
  const providerClient = provider.getClient({ chainId })
  if (!sponsorUrl) return providerClient
  return createClient({
    batch: Tempo.l1Batch,
    chain: providerClient.chain,
    transport: Tempo.transport(rpcUrl, sponsorUrl),
  })
}

async function getAccountsProvider(connector: ProviderConnector, chainId: number) {
  const provider = await getConnectorProvider(connector)
  const providerChainId = provider.store.getState().chainId
  if (providerChainId !== chainId) {
    throw new Error(
      `The account provider is connected to chain ${providerChainId}, not ${chainId}.`,
    )
  }
  return provider
}

async function getConnectorProvider(connector: ProviderConnector) {
  if (typeof connector?.getProvider !== 'function') {
    throw new Error('The wallet connection is still restoring. Wait a moment and try again.')
  }
  const provider = await connector.getProvider()
  if (!provider || typeof provider !== 'object') {
    throw new Error('The connected account provider does not expose a signable account.')
  }
  return provider as AccountsProvider
}

async function waitForAccessKeyPublication(
  provider: AccountsProvider,
  parameters: { accessKey: Address; address: Address; chainId: number },
) {
  for (const delay of ACCESS_KEY_PUBLICATION_RETRY_DELAYS) {
    if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay))
    if ((await provider.getAccessKeyStatus(parameters)) === 'published') return true
  }
  return false
}

export type PrivateSetupProgress =
  | { phase: PrivateSetupPhase; status: 'pending' }
  | {
      error: unknown
      message: string
      phase: PrivateSetupPhase
      receipt?: Pick<TransactionReceipt, 'transactionHash'> | undefined
      status: 'error'
    }
  | {
      phase: PrivateSetupPhase
      receipt?: Pick<TransactionReceipt, 'transactionHash'> | undefined
      status: 'success'
    }

export type PrivateSetupPhase =
  | 'l1-access-key-authorization'
  | 'l1-access-key-funding'
  | 'l1-access-key-publication'
  | 'zone-access-key-authorization'

async function reportPrivateSetupProgress<result>(
  phase: PrivateSetupPhase,
  onProgress: ((progress: PrivateSetupProgress) => void) | undefined,
  action: () => Promise<result>,
) {
  onProgress?.({ phase, status: 'pending' })
  try {
    const result = await action()
    onProgress?.({ phase, status: 'success' })
    return result
  } catch (error) {
    onProgress?.({ error, message: Errors.message(error), phase, status: 'error' })
    throw error
  }
}

class MissingPendingAccessKeyAuthorizationError extends Error {
  constructor() {
    super('The account provider did not retain the pending Zone key authorization.')
    this.name = 'MissingPendingAccessKeyAuthorizationError'
  }
}

function shouldReauthorizeAccessKey(error: unknown) {
  return (
    error instanceof MissingPendingAccessKeyAuthorizationError ||
    Errors.nestedMessageIncludes(error, 'InvalidCallScope') ||
    Errors.nestedMessageIncludes(error, 'failed to recover signer from KeyAuthorization signature')
  )
}

/** Creates an account-isolated Zone client for the selected deployment. */
export function createPrivateZoneClient(options: createPrivateZoneClient.Options) {
  // Keep reads account-shaped but unsigned. An AccessKeyAccount makes viem encode even
  // eth_call as a keychain call and unnecessarily couples reads to signer state. Writes
  // pass the access-key signer explicitly.
  return Zone.create({
    account: options.account.address,
    environmentId: options.environmentId,
    sourceId: options.sourceId,
    zone: options.zone,
  })
}

export declare namespace createPrivateZoneClient {
  type Options = {
    account: Account
    environmentId: string
    sourceId: number
    zone: ZoneConfiguration
  }
}

/** Bootstraps the Zone's independent keychain when needed. */
export async function authorizePrivateZone(options: authorizePrivateZone.Options) {
  const { account, connector, expected, onProgress, zone, zoneClient } = options

  const provider = await getConnectorProvider(connector)
  const info = await Zone.getInfo(zoneClient)
  if (info.chainId !== zone.chainId) {
    throw new Error('Zone chain does not match the deployment registry.')
  }

  if ((await getZoneAccessKeyStatus(zoneClient, account)) === 'usable') {
    const pending = await Zone.pendingKeyAuthorization(account, zone.chainId)
    if (pending) await pending.manager.remove(pending.key)
    return
  }

  await reportPrivateSetupProgress('zone-access-key-authorization', onProgress, async () => {
    const result = await provider.request({
      method: 'wallet_authorizeAccessKey',
      params: [
        {
          ...accessKeyAuthorization(zone.chainId),
          address: account.accessKeyAddress,
          keyType: 'p256',
        },
      ],
    })
    if (getAddress(result.rootAddress) !== getAddress(expected)) {
      throw new Error('The account provider authorized the Zone signer for a different account.')
    }
    if (!(await Zone.pendingKeyAuthorization(account, zone.chainId)))
      throw new Error('The account provider did not retain the Zone key authorization.')
  })
}

/** Restores a delegated Zone key without signing or mutating state. */
export async function restorePrivateZoneSession(options: restorePrivateZoneSession.Options) {
  const { account, zone, zoneClient } = options

  const info = await Zone.getInfo(zoneClient)
  if (info.chainId !== zone.chainId) {
    throw new Error('Zone chain does not match the deployment registry.')
  }
  const usable = (await getZoneAccessKeyStatus(zoneClient, account)) === 'usable'
  const pending = await Zone.pendingKeyAuthorization(account, zone.chainId)
  if (usable) return pending === undefined
  const expiry = pending?.authorization.expiry
  return (
    pending !== undefined &&
    (expiry == null || BigInt(expiry) > BigInt(Math.floor(Date.now() / 1_000)))
  )
}

export declare namespace restorePrivateZoneSession {
  type Options = {
    account: TempoAccount.AccessKeyAccount
    zone: ZoneConfiguration
    zoneClient: Zone.Client
  }
}

async function getZoneAccessKeyStatus(
  zoneClient: Zone.Client,
  accessKeyAccount: TempoAccount.AccessKeyAccount,
) {
  const account = accessKeyAccount.address
  const accessKey = accessKeyAccount.accessKeyAddress
  try {
    const key = await zoneClient.readContract({
      account,
      address: Addresses.accountKeychain,
      abi: Abis.accountKeychain,
      functionName: 'getKey',
      args: [account, accessKey],
    })
    if (
      getAddress(key.keyId) !== getAddress(accessKey) ||
      key.isRevoked ||
      key.expiry <= BigInt(Math.floor(Date.now() / 1_000))
    )
      return 'missing' as const
    return !key.enforceLimits ? ('usable' as const) : ('missing' as const)
  } catch (error) {
    if (Errors.nestedMessageIncludes(error, 'KeyNotFound')) return 'missing' as const
    throw error
  }
}

export declare namespace authorizePrivateZone {
  type Options = {
    account: TempoAccount.AccessKeyAccount
    connector: { getProvider(): Promise<unknown> }
    expected: Address
    onProgress?: ((progress: PrivateSetupProgress) => void) | undefined
    zone: ZoneConfiguration
    zoneClient: Zone.Client
  }
}

type AccountsProvider = {
  getAccessKeyStatus: Provider.Provider['getAccessKeyStatus']
  getClient: Provider.Provider['getClient']
  request: Provider.Provider['request']
  store: {
    accessKeys: {
      clear(): void
      select(options: {
        account: Address
        calls?: readonly { data?: `0x${string}` | undefined; to: Address }[] | undefined
        chainId: number
      }): Promise<Account | undefined>
    }
    getState(): { chainId: number }
  }
}
