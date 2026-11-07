import { createServer, type IncomingHttpHeaders } from 'node:http'
import { createPublicClient, type HttpTransportConfig } from 'viem'
import { describe, expect, test } from 'vitest'

import {
  configuredRpcTransport,
  rpcConfiguration,
  rpcTransport,
  sanitizedDiagnostic,
} from './runtime.js'

describe('deployment runtime', () => {
  test('separates display and authenticated RPC URLs', () => {
    expect(
      rpcConfiguration('TEMPO', {
        TEMPO_RPC_URL: 'https://user:password@rpc.example/path',
      }),
    ).toMatchObject({
      url: 'https://rpc.example/path',
      authenticatedUrl: 'https://user:password@rpc.example/path',
      headers: { Authorization: 'Basic dXNlcjpwYXNzd29yZA==' },
    })
  })
})

describe('RPC credential boundaries', () => {
  test.each(['%41', 'a:b@c/?#', 'ü%2F+ space'])(
    'preserves literal password %s in both representations',
    (password) => {
      const rpc = rpcConfiguration('TEMPO', {
        TEMPO_RPC_URL: 'https://rpc.example',
        TEMPO_RPC_USERNAME: 'user%41',
        TEMPO_RPC_PASSWORD: password,
      })
      const url = new URL(rpc.authenticatedUrl!)
      expect(decodeURIComponent(url.username)).toBe('user%41')
      expect(decodeURIComponent(url.password)).toBe(password)
      expect(rpc.headers?.Authorization).toBe(
        `Basic ${Buffer.from(`user%41:${password}`).toString('base64')}`,
      )
    },
  )

  test('malformed URL errors never retain raw credential input', () => {
    try {
      rpcConfiguration('TEMPO', { TEMPO_RPC_URL: 'https://user:secret@[bad' })
      throw new Error('expected validation failure')
    } catch (error) {
      expect(String(error)).toContain('must be a valid HTTP(S) URL')
      expect(String(error)).not.toContain('secret')
      expect(JSON.stringify(error)).not.toContain('secret')
    }
  })

  test('transport exposes only credential-free URL metadata and sends auth as a header', () => {
    const configured = rpcTransport('https://user:secret@rpc.example')({ chain: undefined })
    expect(configured.value?.url).toBe('https://rpc.example/')
    expect(new Headers(configured.value?.fetchOptions?.headers).get('Authorization')).toBe(
      'Basic dXNlcjpzZWNyZXQ=',
    )
  })

  test('diagnostics render a sanitized message without inspecting nested properties', () => {
    const error = new TypeError('RPC https://user:secret@rpc.example failed')
    Object.assign(error, { input: 'super-secret', cause: { url: 'secret-cause' } })
    expect(sanitizedDiagnostic(error)).toBe('RPC https://[redacted]@rpc.example failed')
    expect(sanitizedDiagnostic(new Error('Authorization: Basic dXNlcjpzZWNyZXQ='))).not.toContain(
      'dXNlcjpzZWNyZXQ=',
    )
  })
})

describe('RPC headers on the wire', () => {
  test.each(['record', 'tuples', 'headers', 'configured'] as const)(
    'sends URL-derived Basic auth and caller headers through %s configuration',
    async (kind) => {
      let received: IncomingHttpHeaders | undefined
      const server = createServer((request, response) => {
        received = request.headers
        response.setHeader('content-type', 'application/json')
        response.end(JSON.stringify({ jsonrpc: '2.0', id: 1, result: '0x1079' }))
      })
      await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
      try {
        const address = server.address()
        if (!address || typeof address === 'string') throw new Error('Missing local RPC address')
        const url = `http://user:password@127.0.0.1:${address.port}`
        const entries: [string, string][] = [['X-Request-Tag', 'caller-header']]
        const headers: NonNullable<HttpTransportConfig['fetchOptions']>['headers'] =
          kind === 'headers'
            ? new Headers(entries)
            : kind === 'tuples'
              ? entries
              : Object.fromEntries(entries)
        const client = createPublicClient({
          transport:
            kind === 'configured'
              ? configuredRpcTransport({ url, headers: Object.fromEntries(entries) })
              : rpcTransport(url, { fetchOptions: { headers }, retryCount: 0 }),
        })
        await expect(client.getChainId()).resolves.toBe(4217)
        expect(received?.authorization).toBe('Basic dXNlcjpwYXNzd29yZA==')
        expect(received?.['x-request-tag']).toBe('caller-header')
        expect(received?.['content-type']).toBe('application/json')
      } finally {
        server.closeAllConnections()
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve())),
        )
      }
    },
  )

  test('explicit mixed-case authorization overrides URL credentials on the wire', async () => {
    let authorization: string | undefined
    const server = createServer((request, response) => {
      authorization = request.headers.authorization
      response.setHeader('content-type', 'application/json')
      response.end(JSON.stringify({ jsonrpc: '2.0', id: 1, result: '0x1079' }))
    })
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    try {
      const address = server.address()
      if (!address || typeof address === 'string') throw new Error('Missing local RPC address')
      const client = createPublicClient({
        transport: rpcTransport(`http://user:password@127.0.0.1:${address.port}`, {
          fetchOptions: { headers: { aUtHoRiZaTiOn: 'Bearer caller-token' } },
          retryCount: 0,
        }),
      })
      await expect(client.getChainId()).resolves.toBe(4217)
      expect(authorization).toBe('Bearer caller-token')
    } finally {
      server.closeAllConnections()
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      )
    }
  })
})
