import { ContractFunctionZeroDataError, getAddress, type Address, type PublicClient } from 'viem'
import { describe, expect, test, vi } from 'vitest'

import {
  nonMemberSpenders,
  spenderProvenanceBlockers,
  spenderRouterFactory,
  type SpenderReleases,
} from './inspection.js'

const address = (suffix: string) => getAddress(`0x${suffix.padStart(40, '0')}`) as Address
const customerId = `0x${'c'.repeat(64)}` as const

const routerFactory = address('f')
const cardFactory = address('cf')
const card = address('ca2d')
const send = address('5e2d')
const releases: SpenderReleases = {
  cardFactory: (factory) => (factory === routerFactory ? cardFactory : address('bad')),
  sendSpender: ({ routerFactory: factory, convertVault, pool, customerId: id }) =>
    factory === routerFactory &&
    convertVault === address('7a') &&
    pool === address('b0') &&
    id === customerId
      ? send
      : address('e15e'),
}

/** A chain of spenders, each answering only the getters in its own entry; others revert. */
function chain(contracts: Record<Address, Record<string, unknown>>) {
  return {
    readContract: vi.fn(
      async ({
        address: target,
        functionName,
        args,
      }: {
        address: Address
        functionName: string
        args?: readonly unknown[]
      }) => {
        const value = contracts[target]?.[functionName]
        if (value === undefined) throw new ContractFunctionZeroDataError({ functionName })
        return typeof value === 'function' ? value(...(args ?? [])) : value
      },
    ),
  } as unknown as Pick<PublicClient, 'readContract'>
}

const cardSpender = { ROUTER_FACTORY: routerFactory, PROVIDER: address('9a0') }
const sendSpender = {
  ROUTER_FACTORY: routerFactory,
  convertVault: address('7a'),
  pool: address('b0'),
  customerId,
}
const releaseCardFactory = { isDeployed: (program: Address) => program === card }

describe('spenderProvenanceBlockers', () => {
  test('accepts a release CardFactory program and the release SendSpender for its settings', async () => {
    const client = chain({
      [card]: cardSpender,
      [send]: sendSpender,
      [cardFactory]: releaseCardFactory,
    })
    await expect(
      spenderProvenanceBlockers(
        client,
        { factory: routerFactory, spenders: [card, send] },
        releases,
      ),
    ).resolves.toEqual([])
  })

  test('reports a spender bound to another router factory, or to none', async () => {
    const other = address('f2')
    const unbound = address('dead')
    const client = chain({
      [card]: { ...cardSpender, ROUTER_FACTORY: other },
      [unbound]: { PROVIDER: address('9a0') },
    })
    await expect(
      spenderProvenanceBlockers(
        client,
        { factory: routerFactory, spenders: [card, unbound] },
        releases,
      ),
    ).resolves.toEqual([
      `Spender ${card} takes spendFrom only from routers of ZoneRouterFactory ${other}, not the router's ${routerFactory}`,
      `Spender ${unbound} reports no ROUTER_FACTORY, so it may take spendFrom from any caller`,
    ])
  })

  test('reports a program another CardFactory made and a SendSpender off its release address', async () => {
    const copy = address('c0b1')
    const stray = address('57a7')
    const client = chain({
      [copy]: cardSpender,
      [stray]: sendSpender,
      [cardFactory]: releaseCardFactory,
    })
    await expect(
      spenderProvenanceBlockers(
        client,
        { factory: routerFactory, spenders: [copy, stray] },
        releases,
      ),
    ).resolves.toEqual([
      `Spender ${copy} is not a CardSpender the release CardFactory ${cardFactory} deployed`,
      `Spender ${stray} is not the release SendSpender for its settings, which is at ${send}`,
    ])
  })

  test('reports a spender that is neither kind, and unknown provenance without release builds', async () => {
    const neither = address('aaaa')
    const client = chain({ [neither]: { ROUTER_FACTORY: routerFactory }, [card]: cardSpender })
    const unbuilt: SpenderReleases = {
      ...releases,
      cardFactory: () => {
        throw new Error('forge inspect failed')
      },
    }
    await expect(
      spenderProvenanceBlockers(
        client,
        { factory: routerFactory, spenders: [neither, card] },
        unbuilt,
      ),
    ).resolves.toEqual([
      `Spender ${neither} is neither a CardSpender nor a SendSpender`,
      `Spender ${card} provenance is unknown: forge inspect failed`,
    ])
  })
})

describe('nonMemberSpenders', () => {
  test('lists the spenders the EarnShare policy does not authorize', async () => {
    const readContract = vi.fn(
      async ({ args }: { args: readonly [bigint, Address] }) => args[1] === card,
    )
    const client = { readContract } as unknown as Pick<PublicClient, 'readContract'>
    await expect(
      nonMemberSpenders(client, { policyId: 469n, spenders: [card, send] }),
    ).resolves.toEqual([send])
    expect(readContract).toHaveBeenCalledWith(
      expect.objectContaining({ functionName: 'isAuthorized', args: [469n, send] }),
    )
  })
})

describe('spender transport failures', () => {
  test.each(['ROUTER_FACTORY', 'PROVIDER', 'convertVault', 'isDeployed'])(
    'preserves RPC errors at %s',
    async (failed) => {
      const error = new Error('RPC unavailable')
      const client = {
        readContract: async ({ functionName }: { functionName: string }) => {
          if (functionName === failed) throw error
          if (functionName === 'ROUTER_FACTORY') return routerFactory
          if (functionName === 'PROVIDER' && failed === 'isDeployed') return address('9a0')
          throw new ContractFunctionZeroDataError({ functionName })
        },
      }
      if (failed === 'ROUTER_FACTORY')
        await expect(spenderRouterFactory(client as never, card)).rejects.toBe(error)
      await expect(
        spenderProvenanceBlockers(
          client as never,
          { factory: routerFactory, spenders: [card] },
          releases,
        ),
      ).rejects.toBe(error)
    },
  )
})
