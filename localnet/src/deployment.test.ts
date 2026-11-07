import { decodeFunctionData, getAddress, type Hex } from 'viem'
import { zonePortalAbi } from '@tempoxyz/contracts/abis'
import { describe, expect, it, vi } from 'vitest'

import { administerZonePortal, create, deploymentStartBlock } from './deployment.js'
import { assertFixtureChain, provisionFixtures, validateFixtures } from './deployment/fixtures.js'
import { run } from './environment.js'

const address = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)

describe('administerZonePortal', () => {
  function administrator(status = 'success', readback = true) {
    let mined = false
    const readContract = vi.fn(async ({ functionName }: { functionName: string }) =>
      functionName === 'isAccessEnforced' || functionName === 'isGatewayOpen'
        ? false
        : mined && readback,
    )
    const sendTransactionSync = vi.fn(async (_request: Record<string, unknown>) => {
      mined = true
      return { status, transactionHash: `0x${'ab'.repeat(32)}` }
    })
    return {
      readContract,
      sendTransactionSync,
      account: { address: address(1) },
      chain: { id: 1337 },
      getTransactionCount: async () => 0,
    }
  }
  for (const accessEnforced of [false, true]) {
    for (const gatewayOpen of [false, true]) {
      for (const initialRole of [0, 2, 3]) {
        it(`admits routers with access=${accessEnforced}, open=${gatewayOpen}, role=${initialRole}`, async () => {
          let role = initialRole
          const calls: string[] = []
          const client = {
            account: { address: address(1) },
            chain: { id: 1337 },
            getTransactionCount: async () => 0,
            readContract: async ({
              functionName,
              args,
            }: {
              functionName: string
              args?: unknown[]
            }) => {
              if (functionName === 'isAccessEnforced') return accessEnforced
              if (functionName === 'isGatewayOpen') return gatewayOpen
              if (functionName === 'hasRole') return role === args?.[1]
              throw new Error(`Unexpected read ${functionName}`)
            },
            sendTransactionSync: vi.fn(async ({ calls: batch }: { calls: { data: Hex }[] }) => {
              for (const call of batch) {
                const decoded = decodeFunctionData({ abi: zonePortalAbi, data: call.data })
                if (
                  decoded.functionName !== 'setGateway' &&
                  decoded.functionName !== 'setAllowedAccount'
                )
                  throw new Error('Unexpected Portal call')
                const next = decoded.functionName === 'setGateway' ? 3 : 2
                const allowed = decoded.args[1]
                calls.push(`${decoded.functionName}:${allowed}`)
                if (allowed && role !== 0) throw new Error('Portal already assigns another role')
                if (!allowed && role !== next)
                  throw new Error('Portal revocation names the wrong role')
                role = allowed ? next : 0
              }
              return { status: 'success', transactionHash: `0x${'ab'.repeat(32)}` }
            }),
          }
          const expected = accessEnforced && gatewayOpen ? 2 : 3
          const options = { tokens: [], gateways: [address(4)] }
          await administerZonePortal(client as never, address(2), options)
          expect(role).toBe(expected)
          expect(calls).toHaveLength(initialRole === expected ? 0 : initialRole === 0 ? 1 : 2)
          if (initialRole !== expected) {
            expect(client.sendTransactionSync).toHaveBeenCalledWith(
              expect.objectContaining({ forceAtomic: true }),
            )
          }
          const sent = client.sendTransactionSync.mock.calls.length
          expect(await administerZonePortal(client as never, address(2), options)).toBeUndefined()
          expect(client.sendTransactionSync).toHaveBeenCalledTimes(sent)
        })
      }
    }
  }
  it('rejects a reverted atomic batch and requests receipt-revert enforcement', async () => {
    const client = administrator('reverted')
    await expect(
      administerZonePortal(client as never, address(2), {
        tokens: [address(3)],
        gateways: [address(4)],
      }),
    ).rejects.toThrow('administration reverted')
    expect(client.sendTransactionSync).toHaveBeenCalledWith(
      expect.objectContaining({ forceAtomic: true, throwOnReceiptRevert: true }),
    )
    expect(client.sendTransactionSync.mock.calls[0]?.[0]).not.toHaveProperty('throwOnFailure')
  })
  it('checks both token admission and gateway state after success', async () => {
    const client = administrator()
    await expect(
      administerZonePortal(client as never, address(2), {
        tokens: [address(3)],
        gateways: [address(4)],
      }),
    ).resolves.toHaveProperty('status', 'success')
    expect(client.readContract).toHaveBeenCalledWith(
      expect.objectContaining({ functionName: 'isTokenEnabled' }),
    )
    expect(client.readContract).toHaveBeenCalledWith(
      expect.objectContaining({ functionName: 'hasRole' }),
    )
  })
  it('refuses a successful receipt whose token state did not change', async () => {
    await expect(
      administerZonePortal(administrator('success', false) as never, address(2), {
        tokens: [address(3)],
        gateways: [],
      }),
    ).rejects.toThrow('tokens were not enabled')
  })
  it('refuses a successful receipt whose gateway state did not change', async () => {
    await expect(
      administerZonePortal(administrator('success', false) as never, address(2), {
        tokens: [],
        gateways: [address(4)],
      }),
    ).rejects.toThrow('gateway was not registered')
  })
})

describe('deploymentStartBlock', () => {
  it('never starts a removal scan after the earliest fixture or lifecycle write', () => {
    expect(deploymentStartBlock(100n, [{ blockNumber: 12n }, { blockNumber: 7n }])).toBe(7n)
    expect(deploymentStartBlock(100n, [])).toBe(100n)
    expect(deploymentStartBlock(100n, [{ blockNumber: 101n }])).toBe(100n)
  })
})

describe('create', () => {
  it('rejects invalid fixtures before reading Zone identity or writing policy/bindings', async () => {
    const getCode = vi.fn(async () => '0x')
    const readContract = vi.fn()
    await expect(
      create({
        client: { getBlockNumber: async () => 10n, getCode, readContract },
        base: {
          engineKind: 'erc4626',
          baseAsset: address(1),
          vault: address(2),
          engineFixtures: {},
        },
        account: address(3),
      } as never),
    ).rejects.toThrow('Fixture baseAsset has no code')
    expect(readContract).not.toHaveBeenCalled()
  })
  it('rejects unsupported general-router profiles before starting disposable chains', async () => {
    await expect(
      run({ earnProfile: { id: 'router-profile', zoneRouter: {} } } as never),
    ).rejects.toThrow('local replacement')
  })
})

describe('assertFixtureChain', () => {
  it('keeps testnet and disposable fixtures while refusing valuable hosted chains before writes', async () => {
    expect(() => assertFixtureChain(42431)).not.toThrow()
    expect(() => assertFixtureChain(1337)).not.toThrow()
    await expect(provisionFixtures({ chainId: 4217 } as never)).rejects.toThrow(
      'retired fixtures must not be reused or funded',
    )
  })
})

describe('fixture ownership', () => {
  it('rejects a conversion pool owned by someone other than its fixture deployer', async () => {
    const owner = address(30)
    const fixtures = {
      baseAsset: address(1),
      vault: address(2),
      stablecoins: { alternateAsset: address(3), funder: address(4) },
      routerPool: { pool: address(5), oracle: address(6), registry: address(7) },
      engineFixtures: {},
    }
    const client = {
      getCode: async () => '0x01',
      readContract: async ({ functionName }: { functionName: string }) => {
        if (functionName === 'baseAsset' || functionName === 'quoteToken') return fixtures.baseAsset
        if (functionName === 'alternateAsset' || functionName === 'baseToken')
          return fixtures.stablecoins.alternateAsset
        if (functionName === 'ISSUER_ROLE') return `0x${'01'.repeat(32)}`
        if (functionName === 'hasRole') return true
        if (functionName === 'oracle') return fixtures.routerPool.oracle
        if (functionName === 'addressRegistry') return fixtures.routerPool.registry
        if (functionName === 'owner') return address(31)
        if (functionName === 'paused') return false
        throw new Error(`Unexpected read ${functionName}`)
      },
    }
    await expect(validateFixtures(client as never, 'erc4626', fixtures, owner)).rejects.toThrow(
      'Conversion pool owner',
    )
  })
})
