import { createServer } from 'node:http'
import { once } from 'node:events'
import { describe, expect, test } from 'vitest'
import { zeroAddress } from 'viem'
import { Abis, Addresses } from 'viem/tempo'
import { createE2eContext, type E2eStack } from './context.js'
import { environmentDefinitions } from './environments.js'

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
