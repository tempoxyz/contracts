import { createServer } from 'node:http'
import { once } from 'node:events'
import { describe, expect, test } from 'vitest'
import { zeroAddress } from 'viem'
import { Abis, Addresses } from 'viem/tempo'
import { createE2eContext, type E2eStack, type E2eZoneContext } from './context.js'
import { environmentDefinitions } from './environments.js'
import { requireZoneProofReads } from '../modules/zone/proof.js'

const address = `0x${'11'.repeat(20)}` as const
const key = `0x${'11'.repeat(32)}` as const

describe('policy Zone transport', () => {
  test.each([false, true])(
    'authenticates global policy reads without changing their state view (split endpoints: %s)',
    async (split) => {
      const received: {
        token: string | undefined
        method: string
        from?: string
        path?: string
      }[] = []
      const server = createServer(async (request, response) => {
        const chunks: Buffer[] = []
        for await (const chunk of request) chunks.push(chunk)
        const body = JSON.parse(Buffer.concat(chunks).toString())
        received.push({
          token: request.headers['x-authorization-token'] as string | undefined,
          method: body.method,
          from: body.params?.[0]?.from,
          path: request.url,
        })
        response.setHeader('content-type', 'application/json')
        response.end(
          JSON.stringify({
            jsonrpc: '2.0',
            id: body.id,
            result: body.method === 'eth_call' ? `0x${'0'.repeat(63)}1` : '0x10',
          }),
        )
      })
      server.listen(0, '127.0.0.1')
      await once(server, 'listening')
      try {
        const port = (server.address() as { port: number }).port
        const rpcUrl = `http://127.0.0.1:${port}/private`
        const context = createE2eContext({
          deployment: {
            id: 'test',
            engineKind: 'erc4626',
            contracts: { asset: address },
            operations: {},
            network: {
              name: 'local',
              chainId: 1337,
              rpcUrl,
              pathUsd: address,
              zone: {
                id: 1,
                chainId: 421700001,
                rpcUrl,
                portal: address,
                messenger: address,
                sequencers: [],
              },
            },
          } as unknown as E2eStack,
          environment: environmentDefinitions.local,
          privateKeys: { user: key, operator: key, outsider: key, accessAdministrator: key },
          zoneSubmissionRpcUrl: split ? `http://127.0.0.1:${port}/public` : undefined,
        })
        expect(context.policyZoneClient!.account.address).toBe(zeroAddress)
        expect(context.actors.user.zone!.client.account.address).toBe(context.user.address)
        await context.actors.user.zone!.store.setItem('auth:token:421700001', 'user-policy-token')
        expect(
          await context.policyZoneClient!.readContract({
            address: Addresses.tip403Registry,
            abi: Abis.tip403Registry,
            functionName: 'isAuthorized',
            args: [2n, context.outsider.address],
          }),
        ).toBe(true)
        await context.actors.user.zone!.client.readContract({
          address: Addresses.tip403Registry,
          abi: Abis.tip403Registry,
          functionName: 'isAuthorized',
          args: [2n, context.user.address],
        })
        expect(received).toEqual([
          {
            token: 'user-policy-token',
            method: 'eth_call',
            from: zeroAddress,
            path: split ? '/public' : '/private',
          },
          {
            token: 'user-policy-token',
            method: 'eth_call',
            from: context.user.address,
            path: '/private',
          },
        ])
        expect(await context.actors.outsider.zone!.store.getItem('auth:token:421700001')).toBeNull()
      } finally {
        server.closeAllConnections()
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve())),
        )
      }
    },
  )
})

describe('Zone proof transport', () => {
  test('keeps local evidence, actor reads and submissions on their explicit transports', async () => {
    await proofServer(async ({ rpcUrl, received }) => {
      const context = proofContext(rpcUrl, { localZoneProofRpcUrl: `${rpcUrl}/proof` })
      const user = context.actors.user.zone!
      await user.store.setItem('auth:token:421700001', 'user-proof-test-token')
      await requireZoneProofReads(context as E2eZoneContext)
      await user.client.readContract({
        address,
        abi: Abis.tip20,
        functionName: 'balanceOf',
        args: [context.user.address],
      })
      await user.submission.getChainId()
      expect(context.zoneProofClient).not.toHaveProperty('sendTransaction')
      expect(context.zoneProofClient).not.toHaveProperty('writeContract')
      expect(context.zoneProofClient).not.toHaveProperty('zone')
      expect(received.filter((request) => request.path === '/proof')).toHaveLength(4)
      expect(
        received.filter((request) => request.path === '/proof').every((request) => !request.token),
      ).toBe(true)
      expect(received.find((request) => request.method === 'eth_call')).toEqual({
        path: '/private',
        method: 'eth_call',
        token: 'user-proof-test-token',
        from: context.user.address,
      })
      expect(received.find((request) => request.path === '/submission')).toEqual({
        path: '/submission',
        method: 'eth_chainId',
        token: 'user-proof-test-token',
        from: undefined,
      })
      expect(received.find((request) => request.method === 'eth_getLogs')?.path).toBe('/proof')
      expect(await context.actors.outsider.zone!.store.getItem('auth:token:421700001')).toBeNull()
    })
  })

  test.each(
    Object.values(environmentDefinitions).filter(
      (environment) => environment.provider === 'hosted',
    ),
  )('rejects a separate operator proof endpoint for $id', (environment) => {
    expect(() =>
      proofContext('http://127.0.0.1:1', {
        environment,
        localZoneProofRpcUrl: 'http://127.0.0.1:2',
      }),
    ).toThrow('only allowed for a disposable local Zone')
  })

  test('retains configured user authority for devnet proof reads without a fallback', async () => {
    await proofServer(async ({ rpcUrl, received }) => {
      const context = proofContext(rpcUrl, { environment: environmentDefinitions.devnet })
      await context.actors.user.zone!.store.setItem(
        'auth:token:421700001',
        'devnet-proof-test-token',
      )
      await requireZoneProofReads(context as E2eZoneContext)
      expect(received.every((request) => request.path === '/private')).toBe(true)
      expect(received.every((request) => request.token === 'devnet-proof-test-token')).toBe(true)
    })
  })

  test.each(['chain', 'genesis', 'logs'] as const)(
    'fails closed on mismatched or unavailable %s evidence',
    async (failure) => {
      await proofServer(async ({ rpcUrl, received }) => {
        const context = proofContext(rpcUrl, { localZoneProofRpcUrl: `${rpcUrl}/proof` })
        await expect(requireZoneProofReads(context as E2eZoneContext)).rejects.toThrow(
          failure === 'logs'
            ? 'system-log prerequisite'
            : failure === 'chain'
              ? 'chain ID'
              : 'genesis',
        )
        expect(received.every((request) => !request.method.startsWith('eth_send'))).toBe(true)
        expect(received.some((request) => request.path === '/submission')).toBe(false)
        expect(
          received
            .filter((request) => request.method === 'eth_getLogs')
            .every((request) => request.path === '/proof'),
        ).toBe(true)
      }, failure)
    },
  )
})

function proofContext(
  rpcUrl: string,
  options: Partial<Parameters<typeof createE2eContext>[0]> = {},
) {
  return createE2eContext({
    deployment: {
      id: 'test',
      engineKind: 'erc4626',
      contracts: { asset: address, earnRouter: address },
      operations: {},
      network: {
        name: 'local',
        chainId: 1337,
        rpcUrl,
        pathUsd: address,
        zone: {
          id: 1,
          chainId: 421700001,
          rpcUrl: `${rpcUrl}/private`,
          portal: address,
          messenger: address,
          sequencers: [],
        },
      },
    } as unknown as E2eStack,
    environment: environmentDefinitions.local,
    privateKeys: { user: key, operator: key, outsider: key, accessAdministrator: key },
    zoneSubmissionRpcUrl: `${rpcUrl}/submission`,
    ...options,
  })
}

async function proofServer(
  run: (fixture: {
    rpcUrl: string
    received: {
      path: string | undefined
      method: string
      token: string | undefined
      from: string | undefined
    }[]
  }) => Promise<void>,
  failure?: 'chain' | 'genesis' | 'logs',
) {
  const received: {
    path: string | undefined
    method: string
    token: string | undefined
    from: string | undefined
  }[] = []
  const server = createServer(async (request, response) => {
    const chunks: Buffer[] = []
    for await (const chunk of request) chunks.push(chunk)
    const body = JSON.parse(Buffer.concat(chunks).toString())
    received.push({
      path: request.url,
      method: body.method,
      token: request.headers['x-authorization-token'] as string | undefined,
      from: body.params?.[0]?.from,
    })
    const proof = request.url === '/proof'
    const result = (() => {
      if (body.method === 'eth_chainId')
        return `0x${(proof && failure === 'chain' ? 1 : 421700001).toString(16)}`
      if (body.method === 'eth_getBlockByNumber')
        return {
          hash: `0x${(proof && failure === 'genesis' ? 'bb' : 'aa').repeat(32)}`,
          number: '0x0',
          timestamp: '0x0',
          transactions: [],
        }
      if (body.method === 'eth_getLogs') return []
      if (body.method === 'eth_call') return `0x${'0'.repeat(63)}1`
      return '0x7'
    })()
    response.setHeader('content-type', 'application/json')
    response.end(
      JSON.stringify({
        jsonrpc: '2.0',
        id: body.id,
        ...(proof && failure === 'logs' && body.method === 'eth_getLogs'
          ? { error: { code: -32602, message: 'invalid filter address' } }
          : { result }),
      }),
    )
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  try {
    await run({
      rpcUrl: `http://127.0.0.1:${(server.address() as { port: number }).port}`,
      received,
    })
  } finally {
    server.closeAllConnections()
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    )
  }
}
