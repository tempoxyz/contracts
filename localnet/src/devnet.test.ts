import { privateKeyToAccount } from 'viem/accounts'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { inspectZone } from '@tempoxyz/earn/tempo/zone'
import * as Deployment from './deployment.js'
import * as Network from './network.js'
import { deploy } from './devnet.js'

vi.mock('@tempoxyz/earn/tempo/zone', async (original) => ({
  ...(await original<typeof import('@tempoxyz/earn/tempo/zone')>()),
  inspectZone: vi.fn(),
}))
vi.mock('./deployment.js', () => ({ createBase: vi.fn(), create: vi.fn() }))
vi.mock('./network.js', () => ({ createClient: vi.fn(), waitForToken: vi.fn() }))

const key = (value: number) => `0x${value.toString(16).padStart(64, '0')}` as const
const privateKeys = { deployer: key(1), zoneAdministrator: key(5) }
const zoneAdministrator = privateKeyToAccount(privateKeys.zoneAdministrator).address
const user = privateKeyToAccount(key(2)).address
const portal = privateKeyToAccount(key(6)).address
const client = { getChainId: vi.fn(), readContract: vi.fn() }
const options = {
  chainId: 31318,
  rpcUrl: 'http://l1.test',
  zoneId: 7,
  zoneChainId: 31318 * 2 ** 32 + 7,
  zoneRpcUrl: 'http://zone.test',
  zonePortal: portal,
  privateKeys,
  user,
  accessAdministrator: user,
  portalAccounts: [user],
}
const portalReads = (reads: { admin?: string; enforced?: boolean; admitted?: boolean }) =>
  client.readContract.mockImplementation(async ({ functionName }) => {
    if (functionName === 'admin') return reads.admin ?? zoneAdministrator
    if (functionName === 'isAccessEnforced') return reads.enforced ?? false
    if (functionName === 'hasRole') return reads.admitted ?? true
    throw new Error(`Unexpected read ${functionName}`)
  })

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(Network.createClient).mockReturnValue(client as never)
  client.getChainId.mockResolvedValue(options.chainId)
  portalReads({})
  vi.mocked(inspectZone).mockResolvedValue({ id: 7, portal } as never)
})

// Each refusal happens before any fixture deployment; the deployer never changes the chains' access.
describe('devnet safety checks', () => {
  it.each([4217, 42431])('refuses hosted chain %s', async (chainId) => {
    await expect(deploy({ ...options, chainId })).rejects.toThrow('refuse hosted chain')
    expect(client.getChainId).not.toHaveBeenCalled()
  })

  it.each([
    ['a different live L1', () => client.getChainId.mockResolvedValue(1337), 'L1 RPC serves'],
    [
      'a Portal the Factory does not bind',
      () => vi.mocked(inspectZone).mockResolvedValue({ id: 7, portal: zoneAdministrator } as never),
      'ZONE_PORTAL_ADDRESS',
    ],
    ['the wrong Zone admin key', () => portalReads({ admin: portal }), 'does not administer'],
    [
      'an unadmitted account under access enforcement',
      () => portalReads({ enforced: true, admitted: false }),
      `admit ${user}`,
    ],
  ])('rejects %s', async (_, arrange, message) => {
    arrange()
    await expect(deploy(options)).rejects.toThrow(message)
    expect(Deployment.createBase).not.toHaveBeenCalled()
  })
})
