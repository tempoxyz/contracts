import { describe, expect, it } from 'vitest'

import { expectContractRevert } from './transactions.js'

describe('expectContractRevert', () => {
  it('does not accept an unrelated transport failure', async () => {
    const unrelated = new Error('RPC unavailable')

    await expect(
      expectContractRevert(async () => {
        throw unrelated
      }, 'contract call unexpectedly succeeded'),
    ).rejects.toBe(unrelated)
  })
})
