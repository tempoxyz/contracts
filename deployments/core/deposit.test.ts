import { expect, test } from 'vitest'

import { depositEarnProfile } from './deposit.js'

test('refuses funding a verification-pending record before any RPC or key access', async () => {
  await expect(
    depositEarnProfile({
      broadcast: true,
      record: { source: { contractVerification: 'pending' } },
    } as never),
  ).rejects.toThrow('Source verification must be complete before funding')
})
