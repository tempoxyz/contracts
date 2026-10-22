import { describe, expect, test, vi } from 'vitest'

import { app } from './index.js'
import type { AppEnv } from './log.js'

const bindings = {
  ASSETS: {
    fetch: vi.fn(async (request: Request) => {
      const path = new URL(request.url).pathname
      return new Response(`<main>asset fallback for ${path}</main>`, {
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
      })
    }),
  } as unknown as Fetcher,
  ENVIRONMENT: 'development',
  PRIVY_APP_ID: 'test-privy-app-id',
  TEMPO_API_KEY: 'tempo-secret',
} satisfies AppEnv['Bindings']

describe('Tempo Earn Worker', () => {
  test('returns only public runtime configuration', async () => {
    const response = await app.request('https://earn.example/api/config', undefined, bindings)

    const config = (await response.json()) as Record<string, unknown>

    expect(config.environment).toBe('development')
    expect(config.defaultEnvironmentId).toBe('moderato')
    expect(config.environments).toEqual([
      expect.objectContaining({
        id: 'moderato',
        sponsorUrl: 'https://sponsor.moderato.tempo.xyz',
        tempoApiZoneReads: true,
      }),
    ])
    expect(JSON.stringify(config)).not.toContain('veda-mainnet')
    for (const value of config.environments as {
      id: string
      network: { rpcUrl: string; zone?: { rpcUrl: string } | undefined }
    }[]) {
      expect(value.network.rpcUrl).toBe(`https://earn.example/api/environments/${value.id}/l1-rpc`)
      if (value.network.zone) {
        expect(value.network.zone.rpcUrl).toBe(
          `https://earn.example/api/environments/${value.id}/zone-rpc`,
        )
      }
    }
    expect(JSON.stringify(config)).not.toContain(bindings.TEMPO_API_KEY)
    expect(JSON.stringify(config)).not.toContain('revenueShareRecipient')
    expect(JSON.stringify(config)).not.toContain('sourceCommit')
  })

  test('delegates navigation requests to Workers Static Assets', async () => {
    const response = await app.request('https://earn.example/products/pathusd', undefined, bindings)

    expect(response.status).toBe(200)
    expect(response.headers.get('content-security-policy')).toContain("frame-ancestors 'none'")
    expect(response.headers.get('content-security-policy')).toContain(
      'https://sponsor.moderato.tempo.xyz',
    )
    expect(response.headers.get('x-content-type-options')).toBe('nosniff')
    expect(response.headers.get('x-frame-options')).toBe('DENY')
    expect(bindings.ASSETS.fetch).toHaveBeenCalledOnce()
  })

  test('keeps deployed script policy strict', async () => {
    const response = await app.request('https://earn.example/', undefined, {
      ...bindings,
      ENVIRONMENT: 'production',
    })

    expect(response.headers.get('content-security-policy')).toContain(
      "script-src 'self' https://challenges.cloudflare.com",
    )
    expect(response.headers.get('content-security-policy')).not.toContain(
      "script-src 'self' 'unsafe-inline'",
    )
    expect(response.headers.get('content-security-policy')).not.toContain('ws://localhost:*')
  })
})
