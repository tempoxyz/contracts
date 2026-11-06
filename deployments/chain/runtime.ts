import {
  createPublicClient,
  http,
  type Hex,
  type HttpTransportConfig,
  type PublicClient,
} from 'viem'

/**
 * HTTP transport for lifecycle RPC clients. Hosted public RPCs enforce short burst limits, and
 * reconciliation issues many parallel reads, so retry with exponential backoff (about 16s in total)
 * instead of viem's default three quick retries.
 */
export function rpcTransport(url: string | undefined, config: HttpTransportConfig = {}) {
  const rpc = rpcConfiguration('TEMPO', {}, url)
  const headers = new Headers(config.fetchOptions?.headers)
  if (rpc.headers && !headers.has('Authorization'))
    headers.set('Authorization', rpc.headers.Authorization)
  return http(rpc.url, {
    retryCount: 6,
    retryDelay: 250,
    ...config,
    fetchOptions: { ...config.fetchOptions, headers },
  })
}

const clients = new Map<string, PublicClient>()

/** The lifecycle's read client for one RPC URL, shared by every step that reads through it. */
export function rpcClient(url: string): PublicClient {
  let client = clients.get(url)
  if (!client) clients.set(url, (client = createPublicClient({ transport: rpcTransport(url) })))
  return client
}

/** The lifecycle transport of a configured RPC: its credential headers and a 60s request timeout. */
export function configuredRpcTransport(rpc: {
  url: string | undefined
  headers?: Record<string, string> | undefined
}) {
  return rpcTransport(rpc.url, {
    ...(rpc.headers ? { fetchOptions: { headers: rpc.headers } } : {}),
    timeout: 60_000,
  })
}

/**
 * The trimmed 32-byte, 0x-prefixed private key in environment variable `name`; unset or blank is
 * `undefined` unless `required`.
 */
export function envPrivateKey(
  environment: Readonly<Record<string, string | undefined>>,
  name: string,
  options: { required: true },
): Hex
export function envPrivateKey(
  environment: Readonly<Record<string, string | undefined>>,
  name: string,
  options?: { required?: boolean },
): Hex | undefined
export function envPrivateKey(
  environment: Readonly<Record<string, string | undefined>>,
  name: string,
  options: { required?: boolean } = {},
) {
  const value = environment[name]?.trim()
  if (!value) {
    if (options.required) throw new Error(`${name} is required`)
    return undefined
  }
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`${name} must be a 32-byte 0x-prefixed private key`)
  }
  return value as Hex
}

/** Returns a credential-free URL, an executable URL, and optional request headers. */
export function rpcConfiguration(
  prefix: 'TEMPO' | 'ZONE',
  values: Readonly<Record<string, string | undefined>>,
  fallbackUrl?: string,
) {
  const rawUrl = values[`${prefix}_RPC_URL`] || fallbackUrl
  const { parsed, username, password } = (() => {
    try {
      const parsed = rawUrl ? new URL(rawUrl) : undefined
      if (parsed && !['http:', 'https:'].includes(parsed.protocol)) throw new Error()
      return {
        parsed,
        username: values[`${prefix}_RPC_USERNAME`] || decodeURIComponent(parsed?.username ?? ''),
        password: values[`${prefix}_RPC_PASSWORD`] || decodeURIComponent(parsed?.password ?? ''),
      }
    } catch {
      // URL errors retain raw input as an enumerable property, including malformed userinfo.
      throw new Error(
        `${prefix}_RPC_URL must be a valid HTTP(S) URL with valid credential encoding`,
      )
    }
  })()
  if (parsed) {
    parsed.username = ''
    parsed.password = ''
  }
  if (Boolean(username) !== Boolean(password)) {
    throw new Error(`${prefix}_RPC_USERNAME and ${prefix}_RPC_PASSWORD must be configured together`)
  }
  const headers = username
    ? { Authorization: `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}` }
    : undefined
  const authenticatedUrl = parsed ? new URL(parsed) : undefined
  if (authenticatedUrl && username) {
    authenticatedUrl.username = encodeURIComponent(username)
    authenticatedUrl.password = encodeURIComponent(password)
  }
  return {
    authenticatedUrl: authenticatedUrl?.toString(),
    headers,
    url: parsed?.toString(),
  }
}

/** Renders only a sanitized message, never an error object's enumerable RPC request or cause. */
export function sanitizedDiagnostic(error: unknown): string {
  const message = error instanceof Error ? error.message : 'Operation failed with an unknown error'
  return message
    .replace(/(https?:\/\/)[^\s/]*@/gi, '$1[redacted]@')
    .replace(/(Authorization[\s"':=]+)(?:Basic|Bearer)\s+[^\s,}]+/gi, '$1[redacted]')
}
