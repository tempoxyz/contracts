import { describe, expect, test, vi } from 'vitest'

import { hostedPrivateStack } from '../src/test/HostedCatalog.js'
import { read, type ZoneRead } from './zone-reads.js'

const account = '0x1111111111111111111111111111111111111111'
const recipient = '0x2222222222222222222222222222222222222222'
// The real hosted catalog: these reads must keep serving its listed private stack.
const { deployment, environment, zone } = hostedPrivateStack()
const deploymentId = deployment.id

function request(kind: ZoneRead, body: Record<string, unknown>) {
  return new Request(
    `https://earn.example/api/environments/${environment.id}/zones/${zone.id}/${kind}`,
    {
      body: JSON.stringify(body),
      headers: { 'Content-Type': 'application/json' },
      method: 'POST',
    },
  )
}

function options(fetcher: typeof fetch) {
  return { apiKey: 'tempo-secret', environmentId: environment.id, fetcher, zoneId: zone.id }
}

describe('Zone read endpoints', () => {
  test('reads the requested account and only registered deployment tokens', async () => {
    const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const body = (await new Request(input, init).json()) as { id: number }[]
      return Response.json(body.map(({ id }) => ({ id, jsonrpc: '2.0', result: '0x2a' })))
    })
    const response = await read(
      request('balances', { account, deploymentId }),
      'balances',
      options(fetcher),
    )

    expect(response.status).toBe(200)
    expect(response.headers.get('cache-control')).toBe('no-store')
    const body = (await response.json()) as {
      account: string
      balances: { amount: string; token: string }[]
    }
    const expectedTokens = new Set([
      deployment.contracts.earnShare,
      deployment.contracts.asset,
      ...(deployment.modes.private ? [deployment.modes.private.privateAsset] : []),
    ])
    expect(body.account).toBe(account)
    expect(new Set(body.balances.map((balance) => balance.token))).toEqual(expectedTokens)
    expect(body.balances.every((balance) => balance.amount === '42')).toBe(true)
    expect(fetcher).toHaveBeenCalledOnce()
    const [input, init] = fetcher.mock.calls[0]!
    const upstream = new Request(input, init)
    expect(upstream.headers.get('tempo-api-key')).toBe('tempo-secret')
    expect(upstream.headers.get('x-authorization-token')).toBeNull()
    const calls = (await upstream.json()) as { method: string; params: [{ to: string }] }[]
    expect(calls.every((call) => call.method === 'eth_call')).toBe(true)
    expect(new Set(calls.map((call) => call.params[0].to))).toEqual(expectedTokens)
  })

  test('returns a bounded transaction projection for the requested account', async () => {
    const hash = `0x${'12'.repeat(32)}`
    const fetcher = vi.fn(async () =>
      Response.json({
        data: [
          {
            blockNumber: 42,
            hash,
            input: '0xa9059cbb',
            meta: { receipt: { status: 'success' } },
            recipient,
            sender: account,
            timestamp: '2026-07-22T16:25:31.000Z',
          },
        ],
        nextCursor: null,
      }),
    )
    const response = await read(
      request('transactions', { account, deploymentId }),
      'transactions',
      options(fetcher),
    )

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      account,
      transactions: [
        {
          blockNumber: 42,
          counterparty: recipient,
          direction: 'outgoing',
          functionSelector: '0xa9059cbb',
          hash,
          status: 'success',
          timestamp: '2026-07-22T16:25:31.000Z',
        },
      ],
    })
  })

  test('cancels a chunked transaction response before buffering beyond the byte limit', async () => {
    const canceled = vi.fn()
    const source = JSON.stringify({
      data: [
        {
          blockNumber: 42,
          hash: `0x${'12'.repeat(32)}`,
          input: `0x${'12'.repeat(140_000)}`,
          meta: { receipt: { status: 'success' } },
          recipient,
          sender: account,
          timestamp: '2026-07-22T16:25:31.000Z',
        },
      ],
    })
    const bytes = new TextEncoder().encode(source)
    const upstream = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(bytes.slice(0, 128 * 1_024))
          controller.enqueue(bytes.slice(128 * 1_024))
        },
        cancel: canceled,
      }),
    )
    const response = await read(
      request('transactions', { account, deploymentId }),
      'transactions',
      options(vi.fn(async () => upstream)),
    )

    expect(response.status).toBe(502)
    expect(canceled).toHaveBeenCalledOnce()
  })

  test.each([
    ['balances', { token: account }],
    ['transactions', { limit: 100 }],
  ] as const)('refuses caller-selected %s fields', async (kind, extra) => {
    const fetcher = vi.fn()
    const response = await read(
      request(kind, { account, deploymentId, ...extra }),
      kind,
      options(fetcher),
    )

    expect(response.status).toBe(400)
    expect(fetcher).not.toHaveBeenCalled()
  })
})
