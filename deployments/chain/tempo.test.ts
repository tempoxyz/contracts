import { describe, expect, test } from 'vitest'

import { configuredTempoNetworkChain } from './tempo.js'

describe('Tempo chains', () => {
  test('never resolve an expiring-nonce transaction to another same-sender receipt', () => {
    const chain = configuredTempoNetworkChain({
      id: 'local',
      chainId: 1337,
      rpcUrl: 'http://127.0.0.1:8545',
    })

    expect(chain.supportsTransactionReplacementDetection).toBe(false)
  })
})
