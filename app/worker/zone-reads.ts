import { tempoApiRpcUrl } from '@tempoxyz/earn/deployments'
import { encodeFunctionData, erc20Abi, getAddress, hexToBigInt, isHex, type Address } from 'viem'

import type { PrivateTransaction } from '../deployments/catalog.js'
import { zoneReadConfiguration } from './config.js'
import { boundedJsonBody, readCapped } from './request-body.js'

const MAX_BODY_SIZE = 1_024
const REQUEST_TIMEOUT = 10_000
const MAX_TRANSACTION_RESPONSE_SIZE = 256 * 1_024

/** A catalog-bounded Zone read the Worker serves for one requested account. */
export type ZoneRead = 'balances' | 'transactions'

/**
 * Serves one Zone balance snapshot over the deployment's registered tokens, or the account's
 * newest Zone transactions.
 */
export async function read(
  request: Request,
  kind: ZoneRead,
  options: read.Options,
): Promise<Response> {
  const apiKey = options.apiKey?.trim()
  if (!apiKey) return json({ error: 'Zone reads are unavailable.' }, 503)
  const parsed = await boundedJsonBody(request, MAX_BODY_SIZE)
  if (parsed.response) return parsed.response
  const body = parseBody(parsed.body)
  if (!body) return json({ error: 'Invalid Zone read request.' }, 400)
  const configuration = zoneReadConfiguration(
    options.environmentId,
    options.zoneId,
    body.deploymentId,
  )
  if (!configuration) return json({ error: 'Unknown private Earn deployment.' }, 404)

  const tempoApi = {
    account: body.account,
    apiKey,
    chainId: configuration.chainId,
    fetcher: options.fetcher,
  }
  try {
    if (kind === 'transactions') {
      return json(
        { account: body.account, transactions: await readPrivateTransactions(tempoApi) },
        200,
      )
    }
    const balances = await readZoneBalances({ ...tempoApi, tokens: configuration.tokens })
    return json(
      {
        account: body.account,
        balances: balances.map(({ amount, token }) => ({ amount: amount.toString(), token })),
      },
      200,
    )
  } catch {
    return json({ error: `Zone ${kind} are temporarily unavailable.` }, 502)
  }
}

export declare namespace read {
  type Options = {
    apiKey?: string | undefined
    environmentId: string
    fetcher?: typeof fetch | undefined
    zoneId: number
  }
}

/** Accepts exactly `{ account, deploymentId }`; any caller-selected field is refused. */
function parseBody(bytes: Uint8Array): { account: Address; deploymentId: string } | undefined {
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes))
    if (
      value === null ||
      typeof value !== 'object' ||
      Array.isArray(value) ||
      Object.keys(value).length !== 2 ||
      !('account' in value) ||
      typeof value.account !== 'string' ||
      !('deploymentId' in value) ||
      typeof value.deploymentId !== 'string' ||
      value.deploymentId.length === 0 ||
      value.deploymentId.length > 128
    ) {
      return undefined
    }
    return { account: getAddress(value.account), deploymentId: value.deploymentId }
  } catch {
    return undefined
  }
}

function json(body: Record<string, unknown>, status: number) {
  return Response.json(body, { headers: { 'Cache-Control': 'no-store' }, status })
}

/** Reads exact TIP-20 balances from a Zone through Tempo API's key-backed transport. */
async function readZoneBalances(
  options: TempoApiOptions & { tokens: readonly Address[] },
): Promise<{ amount: bigint; token: Address }[]> {
  if (options.tokens.length === 0) return []
  const requests = options.tokens.map((token, index) => ({
    id: index + 1,
    jsonrpc: '2.0' as const,
    method: 'eth_call',
    params: [
      {
        data: encodeFunctionData({
          abi: erc20Abi,
          args: [options.account],
          functionName: 'balanceOf',
        }),
        from: options.account,
        to: token,
      },
      'latest',
    ],
  }))
  const responses = await rpc(requests, options)
  if (!Array.isArray(responses) || responses.length !== requests.length) {
    throw new Error('Tempo API returned an incomplete Zone balance response.')
  }
  const byId = new Map(responses.map((response) => [response.id, response]))
  return options.tokens.map((token, index) => {
    const response = byId.get(index + 1)
    if (!response || 'error' in response || !isHex(response.result)) {
      throw new Error('Tempo API could not read a registered Zone token balance.')
    }
    return { amount: hexToBigInt(response.result), token }
  })
}

/** Reads the newest transactions involving one requested Zone account. */
async function readPrivateTransactions(options: TempoApiOptions): Promise<PrivateTransaction[]> {
  const url = new URL('https://api.tempo.xyz/v1/transactions')
  url.searchParams.set('address', options.account)
  url.searchParams.set('chainId', String(options.chainId))
  url.searchParams.set('include', 'receipt')
  url.searchParams.set('limit', '10')
  url.searchParams.set('order', 'desc')

  const fetcher = options.fetcher ?? fetch
  let response: Response
  try {
    response = await fetcher(url, {
      headers: { 'tempo-api-key': options.apiKey },
      signal: AbortSignal.timeout(REQUEST_TIMEOUT),
    })
  } catch {
    throw new Error('Tempo API Zone transaction request failed.')
  }
  if (!response.ok) throw new Error('Tempo API rejected the Zone transaction request.')

  let value: unknown
  try {
    if (Number(response.headers.get('content-length')) > MAX_TRANSACTION_RESPONSE_SIZE) {
      await response.body?.cancel()
      throw new Error('Response is too large')
    }
    const bytes = await readCapped(response.body, MAX_TRANSACTION_RESPONSE_SIZE)
    if (!bytes) throw new Error('Response is too large')
    value = JSON.parse(new TextDecoder().decode(bytes))
  } catch {
    throw new Error('Tempo API returned an invalid Zone transaction response.')
  }
  if (
    !isObject(value) ||
    !('data' in value) ||
    !Array.isArray(value.data) ||
    value.data.length > 10
  ) {
    throw new Error('Tempo API returned an invalid Zone transaction response.')
  }
  return value.data.map((transaction) => parseTransaction(transaction, options.account))
}

type TempoApiOptions = {
  account: Address
  apiKey: string
  chainId: number
  fetcher?: typeof fetch | undefined
}

type RpcRequest = {
  id: number
  jsonrpc: '2.0'
  method: string
  params: readonly unknown[]
}

type RpcSuccess = { id: number; jsonrpc: '2.0'; result: unknown }
type RpcFailure = {
  error: unknown
  id: number
  jsonrpc: '2.0'
}
type RpcResponse = RpcSuccess | RpcFailure

async function rpc(body: RpcRequest[], options: TempoApiOptions): Promise<RpcResponse[]> {
  const fetcher = options.fetcher ?? fetch
  let response: Response
  try {
    response = await fetcher(tempoApiRpcUrl(options.chainId), {
      body: JSON.stringify(body),
      headers: {
        'Content-Type': 'application/json',
        'tempo-api-key': options.apiKey,
      },
      method: 'POST',
      signal: AbortSignal.timeout(REQUEST_TIMEOUT),
    })
  } catch {
    throw new Error('Tempo API Zone request failed.')
  }
  if (!response.ok) throw new Error('Tempo API rejected the Zone request.')
  try {
    const value: unknown = await response.json()
    if (!Array.isArray(value) || !value.every(isRpcResponse)) throw new Error()
    return value
  } catch {
    throw new Error('Tempo API returned an invalid Zone response.')
  }
}

function isObject(value: unknown): value is object {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function isRpcResponse(value: unknown): value is RpcResponse {
  if (!isObject(value) || !('id' in value) || !('jsonrpc' in value)) return false
  if (!Number.isSafeInteger(value.id) || value.jsonrpc !== '2.0') return false
  return 'result' in value !== 'error' in value
}

function parseTransaction(value: unknown, account: Address): PrivateTransaction {
  const transaction = parseTransactionRecord(value)
  const receiptStatus = parseReceiptStatus(transaction.meta)

  let sender: Address
  let recipient: Address | null
  try {
    sender = getAddress(transaction.sender)
    recipient = transaction.recipient ? getAddress(transaction.recipient) : null
  } catch {
    throw new Error('Tempo API returned an invalid Zone transaction.')
  }
  const normalizedAccount = getAddress(account)
  const outgoing = sender === normalizedAccount
  const incoming = recipient === normalizedAccount
  if (!outgoing && !incoming) {
    throw new Error('Tempo API returned a transaction for a different Zone account.')
  }

  return {
    blockNumber: transaction.blockNumber,
    counterparty: outgoing ? recipient : sender,
    direction: outgoing ? 'outgoing' : 'incoming',
    functionSelector: functionSelector(transaction.input),
    hash: transaction.hash,
    status: receiptStatus ?? 'pending',
    timestamp: transaction.timestamp,
  }
}

type TransactionRecord = {
  blockNumber: number | null
  hash: `0x${string}`
  input: `0x${string}`
  meta?: unknown
  recipient: string | null
  sender: string
  timestamp: string | null
}

function parseTransactionRecord(value: unknown): TransactionRecord {
  if (
    !isObject(value) ||
    !('hash' in value) ||
    typeof value.hash !== 'string' ||
    !isTransactionHash(value.hash) ||
    !('sender' in value) ||
    typeof value.sender !== 'string' ||
    !('input' in value) ||
    typeof value.input !== 'string' ||
    !isHex(value.input) ||
    !('blockNumber' in value) ||
    (value.blockNumber !== null &&
      (typeof value.blockNumber !== 'number' ||
        !Number.isSafeInteger(value.blockNumber) ||
        value.blockNumber < 0)) ||
    !('timestamp' in value) ||
    (value.timestamp !== null &&
      (typeof value.timestamp !== 'string' || !Number.isFinite(Date.parse(value.timestamp)))) ||
    !('recipient' in value) ||
    (value.recipient !== null && typeof value.recipient !== 'string')
  ) {
    throw new Error('Tempo API returned an invalid Zone transaction.')
  }

  return {
    blockNumber: value.blockNumber,
    hash: value.hash,
    input: value.input,
    meta: 'meta' in value ? value.meta : undefined,
    recipient: value.recipient,
    sender: value.sender,
    timestamp: value.timestamp,
  }
}

function parseReceiptStatus(meta: unknown): 'reverted' | 'success' | undefined {
  if (!isObject(meta) || !('receipt' in meta) || !isObject(meta.receipt)) return undefined
  if (!('status' in meta.receipt) || meta.receipt.status === undefined) return undefined
  if (meta.receipt.status !== 'success' && meta.receipt.status !== 'reverted') {
    throw new Error('Tempo API returned an invalid Zone transaction status.')
  }
  return meta.receipt.status
}

function isTransactionHash(value: string): value is `0x${string}` {
  return /^0x[0-9a-fA-F]{64}$/.test(value)
}

function functionSelector(input: `0x${string}`): `0x${string}` {
  const value = input.slice(0, 10)
  if (!isHex(value)) throw new Error('Tempo API returned an invalid Zone transaction.')
  return value
}
