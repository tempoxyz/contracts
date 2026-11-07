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

test('custom networks retain protocol behavior without inventing hosted chain facts', () => {
  const chain = configuredTempoNetworkChain({
    id: 'custom',
    chainId: 991,
    rpcUrl: 'https://rpc.example',
  })
  expect(chain.id).toBe(991)
  expect(chain).not.toHaveProperty('blockExplorers')
  expect(chain).not.toHaveProperty('testnet')
  expect(chain).not.toHaveProperty('hardfork')
  expect(chain).not.toHaveProperty('contracts')
  expect(chain.serializers.transaction).toBeTypeOf('function')
})
