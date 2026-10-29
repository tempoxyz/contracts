import { getAddress } from 'viem'
import { KeyAuthorizationManager } from 'viem/tempo'
import { expect, test, vi } from 'vitest'

const key = {
  accessKey: getAddress('0x0000000000000000000000000000000000000010'),
  address: getAddress('0x0000000000000000000000000000000000000009'),
  chainId: 42431,
}

// accounts (the passkey provider) builds every access key's manager with
// `KeyAuthorizationManager.from({ source })`. viem 2.57.5 replaced that with a store-only `from`,
// which throws on every pending-authorization read, so passkey private sessions would fail.
test('viem accepts the source-backed key authorization manager accounts builds', async () => {
  const source = { get: vi.fn(() => undefined), remove: vi.fn(), set: vi.fn() }
  const manager = KeyAuthorizationManager.from({ source })

  expect(await manager.get(key)).toBeUndefined()
  expect(source.get).toHaveBeenCalledWith(key)
})
