import { describe, expect, test } from 'vitest'

import { redactRpcCredentials } from './rpc-credentials.js'

const username = 'fixture-user@example'
const password = 'fixture/p@ss:word?+%'
const rpcUrl = `https://${encodeURIComponent(username)}:${encodeURIComponent(password)}@rpc.example/`
const environment = { TEMPO_RPC_USERNAME: username, TEMPO_RPC_PASSWORD: password }

const lowerEscapes = (value: string) => value.replace(/%[\da-f]{2}/gi, (part) => part.toLowerCase())

describe('redactRpcCredentials', () => {
  test('removes raw and encoded credentials without discarding the diagnostic', () => {
    const forms = [username, password, encodeURIComponent(username), encodeURIComponent(password)]
    const message = `compiler failed: ${forms.join(' | ')}`
    expect(redactRpcCredentials(message, rpcUrl, environment)).toBe(
      'compiler failed: *** | *** | *** | ***',
    )
  })

  test('removes whole URLs before their credentials, including percent-encoded URLs', () => {
    const forms = [
      rpcUrl,
      rpcUrl.slice(0, -1),
      encodeURIComponent(rpcUrl),
      encodeURIComponent(rpcUrl.slice(0, -1)),
      decodeURIComponent(rpcUrl),
      lowerEscapes(encodeURIComponent(rpcUrl)),
      lowerEscapes(rpcUrl),
    ]
    expect(redactRpcCredentials(forms.join(' | '), rpcUrl, {})).toBe(
      forms.map(() => '***').join(' | '),
    )
  })

  test('recognizes credentials inside configured URLs even when the selected RPC differs', () => {
    const tempo = 'https://other-user:other%3Apassword@tempo.example/'
    const zone = 'https://zone-user:zone%2Fpassword@zone.example/'
    const foundry = 'https://foundry-user:foundry%40password@foundry.example/'
    expect(
      redactRpcCredentials(
        `request failed: ${tempo} ${zone} ${foundry}; other:password zone/password foundry@password`,
        rpcUrl,
        { TEMPO_RPC_URL: tempo, ZONE_RPC_URL: zone, FOUNDRY_ETH_RPC_URL: foundry },
      ),
    ).toBe('request failed: *** *** ***; *** *** ***')
  })

  test('removes Zone environment credentials in raw and encoded form', () => {
    expect(
      redactRpcCredentials('zone+user zone%2Buser zone/pass zone%2Fpass', rpcUrl, {
        ZONE_RPC_USERNAME: 'zone+user',
        ZONE_RPC_PASSWORD: 'zone/pass',
      }),
    ).toBe('*** *** *** ***')
  })

  test('covers normalized URLs and full URLs containing path or query credentials', () => {
    const url = 'HTTPS://RPC.EXAMPLE:443/api/fixture-path?key=fixture-query'
    const normalized = new URL(url).href
    expect(
      redactRpcCredentials([url, normalized, encodeURIComponent(normalized)].join(' | '), url, {}),
    ).toBe('*** | *** | ***')
  })

  test('matches mixed percent-encoding case without treating credentials as regex syntax', () => {
    const secret = 'fixture.*[key]/@:'
    const encoded = encodeURIComponent(secret).replace('%5B', '%5b').replace('%3A', '%3a')
    expect(
      redactRpcCredentials(`${secret} ${encoded}; fixture-other`, rpcUrl, {
        TEMPO_RPC_PASSWORD: secret,
      }),
    ).toBe('*** ***; fixture-other')
  })

  test('redacts JSON-escaped credential values in subprocess diagnostics', () => {
    const secret = 'fixture\\password\n"quoted"'
    expect(
      redactRpcCredentials(JSON.stringify({ password: secret }), rpcUrl, {
        TEMPO_RPC_PASSWORD: secret,
      }),
    ).toBe('{"password":"***"}')
  })

  test('does not let malformed URLs or encodings hide the original error', () => {
    const url = 'not a URL with fixture-secret%zz'
    const secret = 'fixture-secret%zz'
    expect(
      redactRpcCredentials(`spawn failed: ${url}; ${secret}; ${encodeURIComponent(secret)}`, url, {
        TEMPO_RPC_PASSWORD: secret,
      }),
    ).toBe('spawn failed: ***; ***; ***')
  })

  test('does not throw while redacting malformed Unicode', () => {
    const secret = 'fixture-\ud800'
    expect(
      redactRpcCredentials(`compiler failed: ${secret}`, rpcUrl, { TEMPO_RPC_PASSWORD: secret }),
    ).toBe('compiler failed: ***')
  })

  test('does not rewrite its replacement for punctuation-only credentials', () => {
    expect(redactRpcCredentials(`failure ${rpcUrl} *`, rpcUrl, { TEMPO_RPC_PASSWORD: '*' })).toBe(
      'failure *** ***',
    )
  })

  test('preserves the original API behavior for public URLs and unrelated diagnostics', () => {
    expect(redactRpcCredentials('timeout at https://rpc.example', 'https://rpc.example', {})).toBe(
      'timeout at ***',
    )
    expect(redactRpcCredentials('compiler failed', rpcUrl, {})).toBe('compiler failed')
    expect(redactRpcCredentials('compiler failed', '', {})).toBe('compiler failed')
  })
})
