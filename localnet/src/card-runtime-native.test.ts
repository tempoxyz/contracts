import { expect, it } from 'vitest'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'

import { checkImageIdentity } from './card-runtime.js'
import { startL1 } from './network.js'

it.skipIf(process.env.CARD_RUNTIME_NATIVE !== '1')(
  'inspects the running image through Testcontainers even when the CLI context is unavailable',
  async () => {
    const l1 = await startL1(privateKeyToAccount(generatePrivateKey()).address)
    const context = process.env.DOCKER_CONTEXT
    try {
      // Testcontainers already owns the live container; a different CLI daemon must not affect inspection.
      process.env.DOCKER_CONTEXT = `unavailable-${crypto.randomUUID()}`
      await expect(checkImageIdentity('l1', l1.container.getId())).resolves.toBeUndefined()
      await expect(checkImageIdentity('zone', l1.container.getId())).rejects.toThrow('Unreviewed')
    } finally {
      if (context === undefined) delete process.env.DOCKER_CONTEXT
      else process.env.DOCKER_CONTEXT = context
      await l1.container.stop()
    }
  },
  300_000,
)
