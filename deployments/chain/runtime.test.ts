import { describe, expect, test } from 'vitest'

import { rpcConfiguration, rpcTransport, sanitizedDiagnostic } from './runtime.js'

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
