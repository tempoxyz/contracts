import { describe, expect, test, vi } from 'vitest'
import { getAddress } from 'viem'

import { inspectZone, zoneFactoryAddress, zoneInboxAddress, zoneMessengerAddress } from './zone.js'

const address = (suffix: string) => `0x${suffix.padStart(40, '0')}` as const
const zone = { id: 7, chainId: 1424310007, portal: getAddress(address('7')) }

/**
 * A canonical Zone's L1 reads, with `l1` overriding single reads by function name, and a Zone RPC
 * whose Inbox resolves `inboxPortal`. Every Factory and Inbox read must target the canonical
 * predeploy.
 */
function inspect(l1: Record<string, unknown> = {}, inboxPortal: string = zone.portal) {
  const reads: Record<string, unknown> = {
    zoneFactory: zoneFactoryAddress,
    zones: { zoneId: 7, portal: zone.portal, sequencers: [address('a')] },
    zoneId: 7,
    messenger: zoneMessengerAddress,
    encryptionKeyCount: 1n,
    sequencerCount: 1n,
    sequencerAt: address('a'),
    ...l1,
  }
  const l1Client = {
    readContract: vi.fn(
      async ({ address: target, functionName }: { address: string; functionName: string }) => {
        if (functionName === 'zones') expect(getAddress(target)).toBe(zoneFactoryAddress)
        if (!(functionName in reads)) throw new Error(`unexpected ${functionName}`)
        return reads[functionName]
      },
    ),
  }
  const zoneClient = {
    getChainId: vi.fn(async () => zone.chainId),
    readContract: vi.fn(async ({ address: target }: { address: string }) => {
      expect(getAddress(target)).toBe(zoneInboxAddress)
      return inboxPortal
    }),
  }
  return inspectZone({ ...zone, l1Client: l1Client as never, zoneClient: zoneClient as never })
}

describe('canonical Zone inspection', () => {
  test('rejects a Messenger compiled against another Factory', async () => {
    await expect(inspect({ zoneFactory: address('b') })).rejects.toThrow(
      'Messenger is bound to Factory',
    )
  })

  test('rejects a Portal sequencer set that differs from the Factory', async () => {
    await expect(
      inspect({
        zones: { zoneId: 7, portal: zone.portal, sequencers: [address('a'), address('b')] },
        sequencerCount: 2n,
      }),
    ).rejects.toThrow('Factory and Portal sequencers do not match')
  })

  test('rejects a self-consistent Zone RPC identity that is not registered by the canonical Factory', async () => {
    await expect(inspect({ messenger: address('8') }, address('b'))).rejects.toThrow(
      'ZoneInbox resolves Portal',
    )
  })
})
