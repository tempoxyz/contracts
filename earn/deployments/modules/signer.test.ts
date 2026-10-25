import { createClient, custom } from 'viem'
import { describe, expect, test } from 'vitest'

import { pinnedAuthorityTransport } from './signer.js'

/** A client whose RPC answers `eth_chainId` and `eth_fillTransaction` with `filled`. */
function clientFilling(filled: { chainId: string; nonceKey?: string }) {
  const transport = custom({
    request: async ({ method }) =>
      method === 'eth_chainId' ? filled.chainId : { raw: '0x', tx: filled },
  })
  return createClient({ transport: pinnedAuthorityTransport(transport, 42431) })
}

describe('authority signing domain', () => {
  test('accepts the profile chain and the protocol nonce', async () => {
    const client = clientFilling({ chainId: '0xa5bf', nonceKey: '0x0' })
    await expect(client.request({ method: 'eth_chainId' })).resolves.toBe('0xa5bf')
    await expect(
      client.request({ method: 'eth_fillTransaction', params: [{}] } as never),
    ).resolves.toMatchObject({ tx: { nonceKey: '0x0' } })
  })

  test('refuses an RPC that fills another chain or nonce space', async () => {
    await expect(
      clientFilling({ chainId: '0x1' }).request({ method: 'eth_chainId' }),
    ).rejects.toThrow("not the profile's 42431")
    await expect(
      clientFilling({ chainId: '0xa5bf', nonceKey: '0x5' }).request({
        method: 'eth_fillTransaction',
        params: [{}],
      } as never),
    ).rejects.toThrow('outside the protocol nonce')
  })
})
