import { createServer } from 'node:http'
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { createPublicClient, http, pad, type Hex } from 'viem'
import { describe, expect, it } from 'vitest'
import * as Safety from './targets-safety.js'

const account = '0x1111111111111111111111111111111111111111'
const portal = '0x2222222222222222222222222222222222222222'

describe('childEnvironment', () => {
  it('passes only plumbing and explicit inputs, never ambient authority or execution settings', () => {
    expect(
      Safety.childEnvironment(
        { DEPLOYER_PK: 'explicit' },
        {
          PATH: '/bin',
          HOME: '/home/test',
          EARN_ACCESS_ADMIN_PRIVATE_KEY: 'secret',
          ZONE_ADMIN_PRIVATE_KEY: 'secret',
          AWS_SESSION_TOKEN: 'secret',
          DEPLOYER_PK: 'ambient',
          NODE_OPTIONS: '--require untrusted',
          FOUNDRY_PROFILE: 'untrusted',
          FOUNDRY_FFI: 'true',
          OUT: 'shared',
        },
      ),
    ).toEqual({ PATH: '/bin', HOME: '/home/test', DEPLOYER_PK: 'explicit' })
  })
})

describe('withReport', () => {
  it('isolates overlapping outputs even when the other invocation fails after writing', () => {
    const root = mkdtempSync(resolve(tmpdir(), 'bridge-test-'))
    try {
      const result = Safety.withReport(root, (first) => {
        writeFileSync(first, JSON.stringify({ program: account }))
        expect(() =>
          Safety.withReport(root, (second) => {
            expect(second).not.toBe(first)
            writeFileSync(second, JSON.stringify({ program: portal }))
            throw new Error('broadcast failed')
          }),
        ).toThrow('broadcast failed')
        return Safety.readReport(first)
      })
      expect(result).toEqual({ program: account })
      expect(readdirSync(resolve(root, 'reports'))).toEqual([])
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
  it('does not reuse a missing report from a different successful invocation', () => {
    const root = mkdtempSync(resolve(tmpdir(), 'bridge-test-'))
    try {
      Safety.withReport(root, (out) => writeFileSync(out, '{}'))
      expect(() => Safety.withReport(root, Safety.readReport)).toThrow()
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

describe('assertReportBinding and saveRecord', () => {
  it('rejects each mismatched or missing echoed input and keeps the old record', () => {
    const expected = {
      factory: account,
      spenderId: `0x${'aa'.repeat(32)}`,
      zoneId: 3,
      routerFactory: portal,
    }
    const root = mkdtempSync(resolve(tmpdir(), 'bridge-test-'))
    const path = resolve(root, 'target.json')
    try {
      Safety.saveRecord(path, { old: true })
      for (const field of Object.keys(expected)) {
        expect(() => {
          Safety.assertReportBinding({ ...expected, [field]: undefined }, expected)
          Safety.saveRecord(path, { old: false })
        }).toThrow(field)
        expect(JSON.parse(readFileSync(path, 'utf8'))).toEqual({ old: true })
      }
      Safety.assertReportBinding(expected, expected)
      Safety.saveRecord(path, expected)
      expect(JSON.parse(readFileSync(path, 'utf8'))).toEqual(expected)
      expect(readdirSync(root)).toEqual(['target.json'])
      expect(existsSync(path)).toBe(true)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

describe('matchesRuntime', () => {
  it('requires exact reviewed runtime and complete immutable bindings, including repeated copies', () => {
    const object = `0x60${'00'.repeat(64)}61` as Hex
    const artifact = {
      deployedBytecode: {
        object,
        immutableReferences: {
          '1': [
            { start: 1, length: 32 },
            { start: 33, length: 32 },
          ],
        },
      },
    }
    const code = `0x60${pad(account).slice(2).repeat(2)}61` as Hex
    expect(Safety.matchesRuntime(code, artifact, [account])).toBe(true)
    expect(Safety.matchesRuntime(code, artifact, [portal])).toBe(false)
    expect(Safety.matchesRuntime(code, artifact)).toBe(false)
    expect(
      Safety.matchesRuntime(`0x60${pad(account).slice(2)}${pad(portal).slice(2)}61`, artifact, [
        account,
      ]),
    ).toBe(false)
    expect(Safety.matchesRuntime(`${code.slice(0, -2)}62` as Hex, artifact, [account])).toBe(false)
    expect(Safety.matchesRuntime(undefined, artifact, [account])).toBe(false)
    expect(Safety.matchesRuntime('0x', artifact, [account])).toBe(false)
    expect(
      Safety.matchesRuntime(
        code,
        { deployedBytecode: { ...artifact.deployedBytecode, linkReferences: { unresolved: {} } } },
        [account],
      ),
    ).toBe(false)
  })
  it('does not wildcard implementation bytes for factories without immutables', () => {
    expect(Safety.matchesRuntime('0x6001', { deployedBytecode: { object: '0x6001' } })).toBe(true)
    expect(Safety.matchesRuntime('0x6002', { deployedBytecode: { object: '0x6001' } })).toBe(false)
  })
})

describe('safeControl', () => {
  it.each(['owners', 'threshold'])(
    'distinguishes unavailable %s reads from proven wrong ownership',
    async (failed) => {
      await expect(
        Safety.safeControl({
          account,
          safe: portal,
          readOwners: async () => {
            if (failed === 'owners') throw new Error('RPC secret body')
            return [account]
          },
          readThreshold: async () => {
            if (failed === 'threshold') throw new Error('RPC secret body')
            return 1n
          },
        }),
      ).rejects.toThrow('no ownership conclusion was reached')
    },
  )
  it('accepts the sole owner and refuses successfully read incompatible authority', async () => {
    await expect(
      Safety.safeControl({
        account,
        safe: portal,
        readOwners: async () => [account],
        readThreshold: async () => 1n,
      }),
    ).resolves.toBeUndefined()
    await expect(
      Safety.safeControl({
        account,
        safe: portal,
        readOwners: async () => [portal],
        readThreshold: async () => 1n,
      }),
    ).rejects.toThrow('not the sole owner')
    await expect(
      Safety.safeControl({
        account,
        safe: portal,
        readOwners: async () => [account],
        readThreshold: async () => 2n,
      }),
    ).rejects.toThrow('not the sole owner')
  })
})

describe('routerTransition', () => {
  it('hands both exclusive role transitions to the admin, naming only the router', () => {
    expect(
      Safety.routerTransition({
        router: account,
        portal,
        gatewayOpen: false,
        accessEnforced: true,
        accountRole: true,
        gatewayRole: false,
      }),
    ).toContain(`setAllowedAccount(${account}, false), then setGateway(${account}, true)`)
    expect(
      Safety.routerTransition({
        router: account,
        portal,
        gatewayOpen: true,
        accessEnforced: true,
        accountRole: false,
        gatewayRole: true,
      }),
    ).toContain(`setGateway(${account}, false), then setAllowedAccount(${account}, true)`)
    expect(
      Safety.routerTransition({
        router: account,
        portal,
        gatewayOpen: true,
        accessEnforced: false,
        accountRole: false,
        gatewayRole: true,
      }),
    ).toBeUndefined()
    expect(
      Safety.routerTransition({
        router: account,
        portal,
        gatewayOpen: false,
        accessEnforced: true,
        accountRole: false,
        gatewayRole: false,
      }),
    ).toBeUndefined()
  })
})

describe('sendFailure', () => {
  it.each([502, 504, 200])(
    'recognizes real viem JSON-RPC error wrapping at HTTP %s',
    async (status) => {
      const server = createServer(async (request, response) => {
        let body = ''
        for await (const chunk of request) body += chunk
        response.writeHead(status, { 'content-type': 'application/json' })
        response.end(
          JSON.stringify({
            jsonrpc: '2.0',
            id: JSON.parse(body).id,
            error: { code: -32000, message: 'gateway failure' },
          }),
        )
      })
      await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
      try {
        const address = server.address()
        if (!address || typeof address === 'string') throw new Error('no listener')
        const client = createPublicClient({
          transport: http(`http://127.0.0.1:${address.port}`, { retryCount: 0 }),
        })
        const error = await client.getBlockNumber().catch((error: unknown) => error)
        expect(Safety.sendFailure(error)).toEqual({
          transient: status !== 200,
          cutShort: status !== 200,
        })
      } finally {
        await new Promise<void>((resolve, reject) =>
          server.close((error) => (error ? reject(error) : resolve())),
        )
      }
    },
  )
})

describe('target provenance', () => {
  it('rejects a registered foreign clone even when the factory registry agrees with the record', async () => {
    const fixture = provenanceFixture()
    fixture.program.clone = portal
    fixture.reads[`${fixture.program.factory}:getSpenderAddress`] = portal
    await expect(Provenance.assertClone(fixture.client, fixture.program)).rejects.toThrow(
      'not the canonical',
    )
  })
  it('rejects missing or substituted canonical clone code', async () => {
    const fixture = provenanceFixture()
    fixture.codes[fixture.program.clone] = '0x6001'
    await expect(Provenance.assertClone(fixture.client, fixture.program)).rejects.toThrow(
      'pinned beacon proxy',
    )
  })

  it('accepts only reviewed runtimes with all program, clone, factory, mode and portal bindings', async () => {
    const fixture = provenanceFixture()
    await expect(
      Provenance.assertProgram(fixture.client, fixture.program, 3, fixture.artifacts, portal),
    ).resolves.toBeUndefined()
  })
  it.each(['routerFactory', 'cardFactory', 'provider', 'program'] as const)(
    'rejects unreviewed %s code even if membership calls return true',
    async (field) => {
      const fixture = provenanceFixture()
      fixture.codes[fixture.program[field]] = '0x6002'
      await expect(
        Provenance.assertProgram(fixture.client, fixture.program, 3, fixture.artifacts, portal),
      ).rejects.toThrow(/runtime/)
    },
  )
  it('rejects registry drift before the recorded clone is used for a governance send', async () => {
    const fixture = provenanceFixture()
    fixture.reads[`${fixture.program.factory}:getSpenderAddress`] = portal
    await expect(Provenance.assertClone(fixture.client, fixture.program)).rejects.toThrow(
      'no governance call was sent',
    )
  })
  it('rejects a different exact-mode prediction before deployment', async () => {
    const fixture = provenanceFixture()
    fixture.reads[`${fixture.program.routerFactory}:predict`] = portal
    await expect(
      Provenance.assertRouter(fixture.client, fixture.program, 3, false),
    ).rejects.toThrow('exact single-spender')
  })
  it.each(['PROVIDER', 'PAYOUT_TARGET', 'ROUTER_FACTORY'] as const)(
    'does not accept swapped %s immutable semantics',
    async (field) => {
      const fixture = provenanceFixture()
      fixture.reads[`${fixture.program.program}:${field}`] = portal
      await expect(
        Provenance.assertProgram(fixture.client, fixture.program, 3, fixture.artifacts),
      ).rejects.toThrow('binding mismatch')
    },
  )
  it('refuses a membership-only card program with a different prediction', async () => {
    const fixture = provenanceFixture()
    fixture.reads[`${fixture.program.cardFactory}:predict`] = portal
    await expect(
      Provenance.assertProgram(fixture.client, fixture.program, 3, fixture.artifacts),
    ).rejects.toThrow('CardFactory does not bind')
  })
  it('refuses a router bound to another canonical portal', async () => {
    const fixture = provenanceFixture()
    fixture.reads[`${fixture.program.router}:portal`] = account
    await expect(
      Provenance.assertProgram(fixture.client, fixture.program, 3, fixture.artifacts, portal),
    ).rejects.toThrow('different Zone portal')
  })
})

import * as Provenance from './targets-provenance.js'
import type { Program, PublicClient } from './targets.js'

function provenanceFixture() {
  const address = (n: number) => `0x${n.toString(16).padStart(40, '0')}` as const
  const program: Program = {
    factory: address(10),
    clone: address(11),
    program: address(12),
    provider: address(13),
    cardFactory: address(14),
    router: address(15),
    routerFactory: address(16),
    spenderId: `0x${'bb'.repeat(32)}`,
    settlement: address(17),
  }
  program.clone = Provenance.canonicalBridgeClone(program.factory, program.spenderId)
  const artifact = (values: readonly Hex[]) => ({
    deployedBytecode: {
      object: `0x60${'00'.repeat(values.length * 32)}61` as Hex,
      immutableReferences: Object.fromEntries(
        values.map((_, index) => [String(index), [{ start: 1 + index * 32, length: 32 }]]),
      ),
    },
  })
  const runtime = (values: readonly Hex[]) =>
    `0x60${values.map((value) => pad(value).slice(2)).join('')}61` as Hex
  const cardFactory = [program.routerFactory]
  const provider = [program.factory, program.spenderId, program.clone]
  const spender = [program.provider, program.routerFactory, program.clone]
  const artifacts = {
    cards: {
      ZoneRouterFactory: artifact([]),
      CardFactory: artifact(cardFactory),
      BridgeProvider: artifact(provider),
      CardSpender: artifact(spender),
    },
    router: { ZoneRouterFactory: artifact([]) },
  }
  const codes: Record<string, Hex> = {
    [program.routerFactory]: runtime([]),
    [program.cardFactory]: runtime(cardFactory),
    [program.provider]: runtime(provider),
    [program.program]: runtime(spender),
  }
  codes[program.clone] =
    '0x363d3d373d3d363d602036600436635c60da1b60e01b36527fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50545afa5036515af43d6000803e604d573d6000fd5b3d6000f3'
  const reads: Record<string, unknown> = {
    [`${program.factory}:getSpenderAddress`]: program.clone,
    [`${program.routerFactory}:predict`]: program.router,
    [`${program.routerFactory}:isRouter`]: true,
    [`${program.cardFactory}:ROUTER_FACTORY`]: program.routerFactory,
    [`${program.cardFactory}:predict`]: program.program,
    [`${program.cardFactory}:isDeployed`]: true,
    [`${program.provider}:FACTORY`]: program.factory,
    [`${program.provider}:SPENDER_ID`]: program.spenderId,
    [`${program.provider}:CLONE`]: program.clone,
    [`${program.program}:PROVIDER`]: program.provider,
    [`${program.program}:PAYOUT_TARGET`]: program.clone,
    [`${program.program}:ROUTER_FACTORY`]: program.routerFactory,
    [`${program.router}:portal`]: portal,
  }
  const client = {
    getCode: async ({ address }: { address: string }) => codes[address],
    readContract: async ({
      address,
      functionName,
      args,
    }: {
      address: string
      functionName: string
      args?: readonly unknown[]
    }) => {
      if (address === program.routerFactory && functionName === 'predict')
        expect(args).toEqual([Provenance.spendMode(program.program, 3)])
      const key = `${address}:${functionName}`
      if (!(key in reads)) throw new Error(`unexpected read ${key}`)
      return reads[key]
    },
  } as unknown as PublicClient
  return { program, client, codes, reads, artifacts }
}

import { RpcRequestError, keccak256 } from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { tempoModerato } from 'viem/tempo/chains'
import { Account } from 'viem/tempo'
import { sendL1Sync, type WalletClient } from './targets.js'

describe('sendL1Sync', () => {
  it('preserves the scoped access-key signature envelope instead of signing as its raw key', async () => {
    const key = generatePrivateKey()
    const scoped = Account.fromSecp256k1(key, { access: account })
    const fixture = sendingFixture(502, {}, scoped as never)
    await sendL1Sync(fixture.wallet, fixture.client, fixture.calls)
    const options = { serializer: tempoModerato.serializers.transaction }
    const expected = await scoped.signTransaction(fixture.prepared[0] as never, options)
    expect(fixture.sent[0]).toBe(expected)
    const unscoped = await privateKeyToAccount(key).signTransaction(
      fixture.prepared[0] as never,
      options,
    )
    expect(fixture.sent[0]).not.toBe(unscoped)
  })

  it.each([502, 504])(
    'reconciles a JSON-RPC HTTP %s response by the exact signed hash without another signature',
    async (status) => {
      const fixture = sendingFixture(status)
      const result = await sendL1Sync(fixture.wallet, fixture.client, fixture.calls)
      expect(result.recovered).toBe(true)
      expect(fixture.signed).toHaveLength(1)
      expect(fixture.sent).toHaveLength(1)
      expect(fixture.lookedUp).toEqual([keccak256(fixture.sent[0]!)])
      expect(fixture.prepared[0]).toMatchObject({
        nonceKey: 0n,
        nonce: 7,
        chainId: tempoModerato.id,
        calls: fixture.calls,
      })
      const before = fixture.prepared[0]!.validBefore as number
      expect(before).toBeGreaterThan(Math.floor(Date.now() / 1000))
      expect(before).toBeLessThanOrEqual(Math.floor(Date.now() / 1000) + 300)
    },
  )
  it.each([
    { nonceKey: 7n },
    { validBefore: undefined },
    { validBefore: Math.floor(Date.now() / 1000) + 3600 },
    { calls: [] },
  ])('rejects RPC-substituted signing fields before producing bytes: %s', async (changed) => {
    const fixture = sendingFixture(502, changed)
    await expect(sendL1Sync(fixture.wallet, fixture.client, fixture.calls)).rejects.toThrow()
    expect(fixture.signed).toHaveLength(0)
    expect(fixture.sent).toHaveLength(0)
  })
})

function sendingFixture(
  status: number,
  changed: Record<string, unknown> = {},
  signer = privateKeyToAccount(generatePrivateKey()),
) {
  const prepared: Record<string, unknown>[] = []
  const signed: Hex[] = []
  const sent: Hex[] = []
  const lookedUp: Hex[] = []
  const wallet = {
    account: {
      ...signer,
      signTransaction: async (...parameters: Parameters<typeof signer.signTransaction>) => {
        const raw = await signer.signTransaction(...parameters)
        signed.push(raw)
        return raw
      },
    },
    chain: tempoModerato,
    prepareTransactionRequest: async (request: Record<string, unknown>) => {
      const value = {
        ...request,
        gas: 100_000n,
        maxFeePerGas: 20_000_000_000n,
        maxPriorityFeePerGas: 0n,
        ...changed,
      }
      prepared.push(value)
      return value
    },
    request: async ({ params }: { params: [Hex] }) => {
      sent.push(params[0])
      throw new RpcRequestError({
        body: { method: 'eth_sendRawTransactionSync', params },
        error: { code: -32000, message: 'gateway failure' },
        status,
        url: 'https://rpc.invalid',
      })
    },
  } as unknown as WalletClient
  const client = {
    getTransactionCount: async () => 7,
    getTransaction: async ({ hash }: { hash: Hex }) => {
      lookedUp.push(hash)
      return { hash }
    },
    waitForTransactionReceipt: async ({ hash }: { hash: Hex }) => ({
      status: 'success',
      transactionHash: hash,
    }),
  } as unknown as PublicClient
  return {
    wallet,
    client,
    signed,
    sent,
    lookedUp,
    prepared,
    calls: [{ to: portal, data: '0x1234' }] as const,
  }
}
