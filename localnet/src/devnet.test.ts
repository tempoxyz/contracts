import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { encodeAbiParameters, parseAbiParameters, zeroAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { inspectZone } from '@tempoxyz/contracts/tempo/zone'
import * as Deployment from './deployment.js'
import * as Network from './network.js'
import { deploy } from './devnet.js'

vi.mock('@tempoxyz/contracts/tempo/zone', async (original) => ({
  ...(await original<typeof import('@tempoxyz/contracts/tempo/zone')>()),
  inspectZone: vi.fn(),
}))
vi.mock('./deployment.js', () => ({ createBase: vi.fn(), create: vi.fn() }))
vi.mock('./network.js', () => ({ createClient: vi.fn(), waitForToken: vi.fn() }))

const key = (value: number) => `0x${value.toString(16).padStart(64, '0')}` as const
const privateKeys = { deployer: key(1), zoneAdministrator: key(5) }
const zoneAdministrator = privateKeyToAccount(privateKeys.zoneAdministrator).address
const user = privateKeyToAccount(key(2)).address
const portal = privateKeyToAccount(key(6)).address
const client = { getChainId: vi.fn(), readContract: vi.fn(), call: vi.fn() }
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

describe('virtual devnet principals', () => {
  const virtual = '0x58e21090fdfdfdfdfdfdfdfdfdfd010203040506' as const
  it('rejects an unregistered virtual fee recipient before fixture broadcasts', async () => {
    client.call.mockResolvedValue({
      data: encodeAbiParameters(parseAbiParameters('address'), [zeroAddress]),
    })
    await expect(deploy({ ...options, user: virtual })).rejects.toThrow('has no registered master')
    expect(Deployment.createBase).not.toHaveBeenCalled()
  })
  it('resolves a registered virtual fee recipient before reaching fixture broadcasts', async () => {
    client.call.mockResolvedValue({
      data: encodeAbiParameters(parseAbiParameters('address'), [user]),
    })
    vi.mocked(Deployment.createBase).mockRejectedValueOnce(new Error('fixture boundary reached'))
    await expect(deploy({ ...options, user: virtual })).rejects.toThrow('fixture boundary reached')
    expect(client.call).toHaveBeenCalledOnce()
    expect(Deployment.createBase).toHaveBeenCalledOnce()
  })
})

describe('devnet build directory lifetime', () => {
  it('allocates independent fresh run directories for concurrent deployments and removes their build state', async () => {
    const directories: string[] = []
    let ready!: () => void
    const bothStarted = new Promise<void>((resolve) => {
      ready = resolve
    })
    vi.mocked(Deployment.createBase).mockImplementation(async ({ broadcastDirectory }) => {
      const directory = dirname(broadcastDirectory)
      directories.push(directory)
      expect(existsSync(resolve(directory, 'build'))).toBe(false)
      mkdirSync(resolve(directory, 'build/earn/out'), { recursive: true })
      writeFileSync(resolve(directory, 'build/earn/out/bytecode'), directory)
      if (directories.length === 2) ready()
      await bothStarted
      return {} as never
    })
    vi.mocked(Deployment.create).mockImplementation(async ({ broadcastDirectory }) => {
      const directory = dirname(broadcastDirectory)
      expect(readFileSync(resolve(directory, 'build/earn/out/bytecode'), 'utf8')).toBe(directory)
      return { state: {} } as never
    })
    await Promise.all([deploy(options), deploy(options)])
    expect(new Set(directories).size).toBe(2)
    for (const directory of directories) expect(existsSync(directory)).toBe(false)
  })

  it('removes failed build state and gives retries a new directory', async () => {
    const directories: string[] = []
    vi.mocked(Deployment.createBase).mockImplementation(async ({ broadcastDirectory }) => {
      const directory = dirname(broadcastDirectory)
      directories.push(directory)
      expect(existsSync(resolve(directory, 'build'))).toBe(false)
      mkdirSync(resolve(directory, 'build/earn/cache'), { recursive: true })
      writeFileSync(resolve(directory, 'build/earn/cache/partial'), 'failed build')
      throw new Error('fixture build failed')
    })
    for (const _ of [0, 1]) await expect(deploy(options)).rejects.toThrow('fixture build failed')
    expect(new Set(directories).size).toBe(2)
    for (const directory of directories) expect(existsSync(directory)).toBe(false)
  })
})
