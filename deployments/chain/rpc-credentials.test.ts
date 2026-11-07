import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import { promisify } from 'node:util'
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

  test.each(['authenticatedUrl', 'TEMPO_RPC_URL', 'ZONE_RPC_URL', 'FOUNDRY_ETH_RPC_URL'])(
    'redacts the credential-stripped transport URL derived from %s, including serialized forms',
    (source) => {
      const url =
        'HTTPS://fixture-user:fixture%2Fpassword@RPC.EXAMPLE:443/api/fixture-path%2Ftoken?key=fixture-query%22token%22&label=fixture\\label'
      const transportUrl =
        'https://rpc.example/api/fixture-path%2Ftoken?key=fixture-query%22token%22&label=fixture\\label'
      const forms = [
        transportUrl,
        encodeURIComponent(transportUrl),
        decodeURIComponent(transportUrl),
        lowerEscapes(transportUrl),
        lowerEscapes(encodeURIComponent(transportUrl)),
        JSON.stringify(transportUrl).slice(1, -1),
        JSON.stringify(decodeURIComponent(transportUrl)).slice(1, -1),
      ]
      expect(
        redactRpcCredentials(
          `request failed: ${forms.join(' | ')}`,
          source === 'authenticatedUrl' ? url : rpcUrl,
          source === 'authenticatedUrl' ? {} : { [source]: url },
        ),
      ).toBe(`request failed: ${forms.map(() => '***').join(' | ')}`)
    },
  )

  test('redacts credential-stripped URLs with and without a trailing slash', () => {
    const forms = ['https://rpc.example/', 'https://rpc.example']
    expect(
      redactRpcCredentials([...forms, ...forms.map(encodeURIComponent)].join(' | '), rpcUrl, {}),
    ).toBe('*** | *** | *** | ***')
  })

  test('redacts a real transport failure captured through a subprocess', async () => {
    let received: { authorization: string | undefined; url: string | undefined } | undefined
    const server = createServer((request, response) => {
      received = { authorization: request.headers.authorization, url: request.url }
      response.writeHead(503, { 'content-type': 'text/plain' })
      response.end('Service unavailable')
    })
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    try {
      const address = server.address()
      if (!address || typeof address === 'string') throw new Error('Missing local RPC address')
      const transportUrl = `http://127.0.0.1:${address.port}/fixture-path-token?key=fixture-query-token`
      const url = new URL(transportUrl)
      url.username = encodeURIComponent(username)
      url.password = encodeURIComponent(password)
      const script = `
        import { createPublicClient } from 'viem'
        import { rpcTransport } from ${JSON.stringify(new URL('./runtime.ts', import.meta.url).href)}
        const client = createPublicClient({
          transport: rpcTransport(process.env.TEMPO_RPC_URL, { retryCount: 0 }),
        })
        try {
          await client.getChainId()
        } catch (error) {
          process.stderr.write(error.message)
          process.exitCode = 1
        }
      `
      const error = await promisify(execFile)(
        process.execPath,
        ['--import', 'tsx', '--input-type=module', '-e', script],
        {
          cwd: new URL('../', import.meta.url),
          env: { TEMPO_RPC_URL: url.href },
          timeout: 10_000,
        },
      ).catch((error: unknown) => error)
      if (!(error instanceof Error)) throw new Error('Expected a transport subprocess failure')
      expect(received).toEqual({
        authorization: `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`,
        url: '/fixture-path-token?key=fixture-query-token',
      })
      expect(error.message).toContain(transportUrl)
      const redacted = redactRpcCredentials(error.message, url.href, {})
      expect(redacted).toContain('HTTP request failed')
      expect(redacted).toContain('Status: 503')
      expect(redacted).toContain('URL: ***')
      for (const secret of [username, password, 'fixture-path-token', 'fixture-query-token']) {
        expect(redacted).not.toContain(secret)
        expect(redacted).not.toContain(encodeURIComponent(secret))
      }
    } finally {
      server.closeAllConnections()
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      )
    }
  }, 15_000)

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

  test.each(['*', '**', '***', '****', '%2A', '%2a', '%2A%2a'])(
    'is stable across repeated redaction with the asterisk credential %s',
    (password) => {
      const url = `https://fixture-user:${encodeURIComponent(password)}@rpc.example/`
      const environment = { TEMPO_RPC_PASSWORD: password }
      const forms = [url, password, encodeURIComponent(password), decodeURIComponent(password)]
      const redacted = redactRpcCredentials(`failure: ${forms.join(' | ')}`, url, environment)
      expect(redacted).toBe('failure: *** | *** | *** | ***')
      expect(redactRpcCredentials(redacted, url, environment)).toBe(redacted)
      expect(
        redactRpcCredentials(redactRpcCredentials(redacted, url, environment), url, environment),
      ).toBe(redacted)
    },
  )

  test.each(['%2A', '%2a', '%2A%2a'])(
    'keeps masks stable for encoded asterisk userinfo %s without environment credentials',
    (password) => {
      const url = `https://fixture-user:${password}@rpc.example/`
      const redacted = redactRpcCredentials(
        `failure: ${url} ${password} ${decodeURIComponent(password)} ***`,
        url,
        {},
      )
      expect(redacted).toBe('failure: *** *** *** ***')
      expect(redactRpcCredentials(redacted, url, {})).toBe(redacted)
    },
  )

  test('redacts credentials containing mask-shaped text before coalescing repeated masks', () => {
    const url = 'https://***suffix:*@rpc.example/api/fixture-path?key=fixture-query'
    const environment = { TEMPO_RPC_USERNAME: '***suffix', TEMPO_RPC_PASSWORD: '*' }
    const redacted = redactRpcCredentials(`failure: ${url} ***suffix ****suffix`, url, environment)
    expect(redacted).toBe('failure: *** *** ***')
    expect(redactRpcCredentials(redacted, url, environment)).toBe(redacted)
  })

  test('preserves unrelated asterisks when no credential can expand a redaction mask', () => {
    expect(redactRpcCredentials('failure: * ** *** **** ******', rpcUrl, environment)).toBe(
      'failure: * ** *** **** ******',
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
