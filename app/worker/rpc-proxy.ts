import { boundedJsonBody } from './request-body.js'

const MAXIMUM_BODY_BYTES = 1_000_000

type RpcRequest = {
  id?: number | string | null
  jsonrpc: '2.0'
  method: string
  params?: readonly unknown[] | object
}

/** Proxies allowed JSON-RPC methods to one fixed catalog upstream. */
export async function proxy(
  request: Request,
  rpcUrl: string,
  options: proxy.Options,
  fetcher: typeof fetch = fetch,
) {
  const parsed = await boundedJsonBody(request, MAXIMUM_BODY_BYTES)
  if (parsed.response) return parsed.response
  const body = parsed.body
  if (!allowsBody(body, options.kind)) {
    return new Response('JSON-RPC method is not allowed.', { status: 400 })
  }

  const headers = new Headers({ 'Content-Type': 'application/json' })
  for (const [name, value] of Object.entries(options.upstreamHeaders ?? {})) {
    headers.set(name, value)
  }
  const response = await fetcher(rpcUrl, {
    body: new Uint8Array(body).buffer,
    headers,
    method: 'POST',
  })
  if (!response.ok) {
    const responseBody = await response.text()
    const network = options.kind === 'l1' ? 'Tempo L1' : 'Zone'
    return new Response(responseBody || `${network} RPC returned ${response.status}.`, {
      headers: { 'Cache-Control': 'no-store', 'Content-Type': 'text/plain; charset=utf-8' },
      status: response.status,
    })
  }
  return new Response(response.body, {
    headers: {
      'Cache-Control': 'no-store',
      'Content-Type': response.headers.get('content-type') ?? 'application/json',
    },
    status: response.status,
  })
}

export declare namespace proxy {
  type Options = {
    kind: 'l1' | 'zone'
    upstreamHeaders?: Record<string, string> | undefined
  }
}

function allowsBody(body: Uint8Array, kind: 'l1' | 'zone') {
  let value: unknown
  try {
    value = JSON.parse(new TextDecoder().decode(body))
  } catch {
    return false
  }
  const requests = Array.isArray(value) ? value : [value]
  return requests.length > 0 && requests.every((request) => allowsRequest(request, kind))
}

function allowsRequest(value: unknown, kind: 'l1' | 'zone'): value is RpcRequest {
  if (
    !isObject(value) ||
    !('jsonrpc' in value) ||
    value.jsonrpc !== '2.0' ||
    !('method' in value) ||
    typeof value.method !== 'string' ||
    ('id' in value && !isRpcId(value.id)) ||
    ('params' in value && !Array.isArray(value.params) && !isObject(value.params))
  ) {
    return false
  }
  // The browser reads a Zone only through `eth_*`; L1 also serves Tempo and faucet methods.
  return (
    value.method.startsWith('eth_') ||
    (kind === 'l1' && (value.method.startsWith('tempo_') || value.method.startsWith('faucet_')))
  )
}

function isObject(value: unknown): value is object {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

function isRpcId(value: unknown): value is number | string | null {
  return (
    value === null ||
    typeof value === 'string' ||
    (typeof value === 'number' && Number.isFinite(value))
  )
}
