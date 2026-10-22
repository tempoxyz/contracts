import { getAddress } from 'viem'
import { describe, expect, test, vi } from 'vitest'

import { hostedPrivateStack } from '../test/HostedCatalog.js'
import { getPrivateAccessKeyAccount } from './PasskeySession.js'

const { deployment } = hostedPrivateStack()
const address = getAddress('0x0000000000000000000000000000000000000009')

describe('private Accounts provider access key', () => {
  test('rejects access-key authorization on a different parent chain', async () => {
    const request = vi.fn()
    const connector = {
      getProvider: vi.fn(async () => ({
        request,
        store: {
          accessKeys: { select: vi.fn() },
          getState: () => ({ chainId: 1 }),
        },
      })),
    }

    await expect(
      getPrivateAccessKeyAccount({
        chainId: 42431,
        connector,
        deployment,
        expected: address,
        rpcUrl: 'https://rpc.moderato.tempo.xyz',
      }),
    ).rejects.toThrow('The account provider is connected to chain 1, not 42431.')
    expect(request).not.toHaveBeenCalled()
  })
})
