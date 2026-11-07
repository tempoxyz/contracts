import { createClient, custom, type Address } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { createClient as createTempoClient, Addresses } from 'viem/tempo'
import { describe, expect, test, vi } from 'vitest'

import {
  assertSigningIntent,
  guardedTransactionRequest,
  pinnedAuthorityTransport,
  privateKeyMatches,
  sendAuthorityCalls,
} from './signer.js'
import { configuredTempoNetworkChain } from '../chain/tempo.js'

/** A client whose RPC answers `eth_chainId` and `eth_fillTransaction` with `filled`. */
function clientFilling(filled: { chainId: string; nonceKey?: string }) {
  const transport = custom({
    request: async ({ method }) =>
      method === 'eth_chainId' ? filled.chainId : { raw: '0x', tx: filled },
  })
  return createClient({ transport: pinnedAuthorityTransport(transport, 42431) })
}

describe('authority signing domain', () => {
  test('accepts the profile chain and the protocol nonce', async () => {
    const client = clientFilling({ chainId: '0xa5bf', nonceKey: '0x0' })
    await expect(client.request({ method: 'eth_chainId' })).resolves.toBe('0xa5bf')
    await expect(
      client.request({ method: 'eth_fillTransaction', params: [{}] } as never),
    ).resolves.toMatchObject({ tx: { nonceKey: '0x0' } })
  })

  test('refuses an RPC that fills another chain or nonce space', async () => {
    await expect(
      clientFilling({ chainId: '0x1' }).request({ method: 'eth_chainId' }),
    ).rejects.toThrow("not the profile's 42431")
    await expect(
      clientFilling({ chainId: '0xa5bf', nonceKey: '0x5' }).request({
        method: 'eth_fillTransaction',
        params: [{}],
      } as never),
    ).rejects.toThrow('outside the protocol nonce')
  })
})

const calls = [{ to: `0x${'1'.repeat(40)}` as const, data: '0x1234' as const }]
const intent = { chainId: 42431, nonce: 7, feeToken: Addresses.pathUsd, calls } as const
const transaction = {
  type: 'tempo',
  ...intent,
  nonceKey: 0n,
  gas: 100_000n,
  maxFeePerGas: 20_000_000_000n,
  maxPriorityFeePerGas: 0n,
}

describe('final signing intent', () => {
  test('accepts only the authorized calls and protocol nonce under the fee ceiling', () => {
    expect(() => assertSigningIntent(transaction, intent)).not.toThrow()
  })
  test.each([
    { type: 'eip1559' },
    { chainId: 1 },
    { nonce: 8 },
    { nonceKey: 1n },
    { validBefore: 123 },
    { validAfter: 123 },
    { keyAuthorization: {} },
    { authorizationList: [] },
    { feePayerSignature: {} },
    { calls: [{ ...calls[0], value: 1n }] },
    { calls: [{ ...calls[0], data: '0x5678' }] },
    { feeToken: `0x${'2'.repeat(40)}` },
    { gas: 10n ** 18n },
  ])('rejects changed fields %s before signing', (override) => {
    expect(() => assertSigningIntent({ ...transaction, ...override }, intent)).toThrow()
  })
  test('signs an honest RPC-filled request while retaining the locally pinned fields', async () => {
    const client = signingClient({})
    const request = await guardedTransactionRequest(client, calls)
    const prepared = await client.prepareTransactionRequest(request)
    expect(prepared.nonce).toBe(7)
    expect(prepared.nonceKey).toBe(0n)
    expect(prepared.validBefore).toBe(request.validBefore)
    await expect(
      request.account.signTransaction(prepared as never, {
        serializer: client.chain.serializers.transaction,
      }),
    ).resolves.toMatch(/^0x/)
  })
  test.each([4217, 42431])('retains protocol fee selection on chain %s', async (chainId) => {
    const feeToken = `0x20c000000000000000000000${'2'.repeat(16)}` as const
    const client = signingClient({ feeToken }, { chainId })
    const request = await guardedTransactionRequest(client, calls)
    expect(request).not.toHaveProperty('feeToken')
    const prepared = await client.prepareTransactionRequest(request)
    expect(prepared.feeToken).toBe(feeToken)
    await expect(
      request.account.signTransaction(prepared as never, {
        serializer: client.chain.serializers.transaction,
      }),
    ).resolves.toMatch(/^0x/)
    expect(() =>
      request.account.signTransaction({ ...prepared, gas: 10n ** 18n } as never, {
        serializer: client.chain.serializers.transaction,
      }),
    ).toThrow('fee limit')
  })
  test('pins a chain-configured fee token through preparation and signing', async () => {
    const feeToken = `0x20c000000000000000000000${'2'.repeat(16)}` as const
    const client = signingClient({}, { chainId: 4217, feeToken })
    const request = await guardedTransactionRequest(client, calls)
    expect(request.feeToken).toBe(feeToken)
    const prepared = await client.prepareTransactionRequest(request)
    await expect(
      request.account.signTransaction(prepared as never, {
        serializer: client.chain.serializers.transaction,
      }),
    ).resolves.toMatch(/^0x/)
    expect(() =>
      request.account.signTransaction({ ...prepared, feeToken: Addresses.pathUsd } as never, {
        serializer: client.chain.serializers.transaction,
      }),
    ).toThrow('fee token')
  })
  test('pins an explicit deposit fee token over the chain default', async () => {
    const chainFeeToken = `0x20c000000000000000000000${'2'.repeat(16)}` as const
    const client = signingClient({}, { chainId: 4217, feeToken: chainFeeToken })
    const request = await guardedTransactionRequest(client, calls, Addresses.pathUsd)
    expect(request.feeToken).toBe(Addresses.pathUsd)
    const prepared = await client.prepareTransactionRequest(request)
    await expect(
      request.account.signTransaction(prepared as never, {
        serializer: client.chain.serializers.transaction,
      }),
    ).resolves.toMatch(/^0x/)
    expect(() =>
      request.account.signTransaction({ ...prepared, feeToken: chainFeeToken } as never, {
        serializer: client.chain.serializers.transaction,
      }),
    ).toThrow('fee token')
  })
  test('rejects RPC-filled validity immediately before signing through the real SDK', async () => {
    const client = signingClient({ validBefore: '0x7fffffff' })
    const request = await guardedTransactionRequest(client, calls)
    const prepared = await client.prepareTransactionRequest(request)
    expect(prepared.validBefore).toBe(2147483647)
    expect(() =>
      request.account.signTransaction(prepared as never, {
        serializer: client.chain.serializers.transaction,
      }),
    ).toThrow('signing validity')
  })
  test('rejects a foreign RPC-filled chain immediately before signing through the real SDK', async () => {
    const client = signingClient({ chainId: '0x1' })
    const request = await guardedTransactionRequest(client, calls)
    const prepared = await client.prepareTransactionRequest(request)
    expect(prepared.chainId).toBe(1)
    expect(() =>
      request.account.signTransaction(prepared as never, {
        serializer: client.chain.serializers.transaction,
      }),
    ).toThrow('signing chain')
  })
  test('malformed keys fail configuration instead of becoming a handoff', () => {
    expect(privateKeyMatches({}, 'DEPLOYER_PRIVATE_KEY', calls[0]!.to)).toBe(false)
    expect(() =>
      privateKeyMatches({ DEPLOYER_PRIVATE_KEY: 'oops' }, 'DEPLOYER_PRIVATE_KEY', calls[0]!.to),
    ).toThrow('32-byte')
    expect(() =>
      privateKeyMatches(
        { DEPLOYER_PRIVATE_KEY: `0x${'0'.repeat(64)}` },
        'DEPLOYER_PRIVATE_KEY',
        calls[0]!.to,
      ),
    ).toThrow('secp256k1')
  })
  test('does not return a reverted authority hash, even if external state already satisfies the action', async () => {
    const client = {
      account: { address: calls[0]!.to },
      chain: { id: 42431 },
      getTransactionCount: async () => 7,
      sendTransactionSync: vi.fn(async () => ({
        status: 'reverted',
        transactionHash: `0x${'a'.repeat(64)}`,
      })),
    }
    await expect(
      sendAuthorityCalls(client as never, { fundFromFaucet: async () => {} }, {} as never, calls),
    ).rejects.toThrow('did not succeed')
    expect(client.sendTransactionSync).toHaveBeenCalledWith(
      expect.objectContaining({ nonceKey: 0n, throwOnReceiptRevert: true }),
    )
  })
  test('concurrent SDK preparations retain protocol nonces', async () => {
    const client = signingClient()
    const requests = await Promise.all([
      guardedTransactionRequest(client, calls),
      guardedTransactionRequest(client, calls),
    ])
    const prepared = await Promise.all(
      requests.map((request) =>
        client.prepareTransactionRequest({
          ...request,
          gas: 100_000n,
          maxFeePerGas: 20_000_000_000n,
          maxPriorityFeePerGas: 0n,
        }),
      ),
    )
    for (const [index, request] of prepared.entries()) {
      expect(request.nonceKey).toBe(0n)
      expect(request.nonce).toBe(7)
      await expect(
        requests[index]!.account.signTransaction(request as never, {
          serializer: client.chain.serializers.transaction,
        }),
      ).resolves.toMatch(/^0x/)
      expect(() =>
        requests[index]!.account.signTransaction({ ...request, chainId: 1 } as never, {
          serializer: client.chain.serializers.transaction,
        }),
      ).toThrow('signing chain')
    }
  })
})

function signingClient(
  fill?: Record<string, unknown>,
  network: { chainId: number; feeToken?: Address | undefined } = { chainId: 42431 },
) {
  return createTempoClient({
    account: privateKeyToAccount(`0x${'1'.repeat(64)}`),
    chain: configuredTempoNetworkChain({
      id: 'signing-test',
      ...network,
      rpcUrl: 'https://rpc.invalid',
    }),
    transport: custom({
      request: async ({ method, params }) => {
        if (method === 'eth_fillTransaction' && fill)
          return {
            raw: '0x',
            tx: {
              ...params[0],
              type: '0x76',
              chainId: `0x${network.chainId.toString(16)}`,
              nonce: '0x7',
              nonceKey: '0x0',
              gas: '0x186a0',
              maxFeePerGas: '0x4a817c800',
              maxPriorityFeePerGas: '0x0',
              ...fill,
            },
          }
        if (method === 'eth_getTransactionCount') return '0x7'
        if (method === 'eth_chainId') return `0x${network.chainId.toString(16)}`
        throw new Error(`Unexpected RPC method: ${method}`)
      },
    }),
  })
}
