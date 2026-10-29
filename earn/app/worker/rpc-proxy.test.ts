import { describe, expect, test, vi } from 'vitest'

import { proxy } from './rpc-proxy.js'

describe('hosted RPC proxy', () => {
  test('forwards an allowed request without browser authorization headers', async () => {
    const fetcher = vi.fn(async (_input: RequestInfo | URL, _init?: RequestInit) =>
      Response.json({ id: 1, jsonrpc: '2.0', result: '0x1' }),
    )
    const body = JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'eth_chainId', params: [] })
    const response = await proxy(
      new Request('https://earn.example/api/zones/1/rpc', {
        body,
        headers: {
          'Content-Type': 'application/json',
          'X-Authorization-Token': 'signed-zone-token',
        },
        method: 'POST',
      }),
      'https://zone.example',
      {
        kind: 'zone',
        upstreamHeaders: { 'tempo-api-key': 'tempo-secret' },
      },
      fetcher as typeof fetch,
    )

    expect(response.status).toBe(200)
    expect(response.headers.get('cache-control')).toBe('no-store')
    expect(fetcher).toHaveBeenCalledOnce()
    const [url, init] = fetcher.mock.calls[0]!
    expect(url).toBe('https://zone.example')
    expect(init?.method).toBe('POST')
    expect(new Headers(init?.headers).get('authorization')).toBeNull()
    expect(new Headers(init?.headers).get('x-authorization-token')).toBeNull()
    expect(new Headers(init?.headers).get('tempo-api-key')).toBe('tempo-secret')
    expect(new TextDecoder().decode(init?.body as ArrayBuffer)).toBe(body)
  })

  test('rejects non-RPC and privileged Zone methods', async () => {
    const fetcher = vi.fn()
    const response = await proxy(
      new Request('https://earn.example/api/zones/1/rpc', {
        body: JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'zone_admin_reset', params: [] }),
        headers: { 'Content-Type': 'application/json' },
        method: 'POST',
      }),
      'https://zone.example',
      { kind: 'zone' },
      fetcher,
    )

    expect(response.status).toBe(400)
    expect(fetcher).not.toHaveBeenCalled()
  })

  test('rejects a batch containing malformed parameters', async () => {
    const fetcher = vi.fn()
    const response = await proxy(
      new Request('https://earn.example/api/zones/1/rpc', {
        body: JSON.stringify([
          { id: 1, jsonrpc: '2.0', method: 'eth_chainId', params: [] },
          { id: 2, jsonrpc: '2.0', method: 'eth_getBalance', params: 'latest' },
        ]),
        headers: { 'Content-Type': 'application/json' },
        method: 'POST',
      }),
      'https://zone.example',
      { kind: 'zone' },
      fetcher,
    )

    expect(response.status).toBe(400)
    expect(fetcher).not.toHaveBeenCalled()
  })
})
