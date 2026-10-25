import { describe, expect, test } from 'vitest'

import { rpcConfiguration } from './runtime.js'

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
