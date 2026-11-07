import { createServer } from 'node:http'
import {
  decodeFunctionData,
  encodeFunctionResult,
  erc20Abi,
  erc4626Abi,
  getAddress,
  toFunctionSelector,
  type Address,
  type Hex,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { describe, expect, test } from 'vitest'

import { earnFeesAbi, earnVaultAbi, erc4626EngineAbi } from '../abis/index.js'
import { depositEarnProfile } from './deposit.js'
import { parseEarnDeploymentProfile } from './profile.js'
import type { EarnDeploymentRecord } from './record.js'

const address = (n: number) => getAddress(`0x${n.toString(16).padStart(40, '0')}`)
const [engine, vault, share, fees, asset, venue, owner, migratedEngine, migratedVenue] = Array.from(
  { length: 9 },
  (_, i) => address(i + 1),
) as [Address, Address, Address, Address, Address, Address, Address, Address, Address]
const genesisHash = `0x${'11'.repeat(32)}` as const
const profile = parseEarnDeploymentProfile(
  {
    version: 1,
    id: 'deposit-binding',
    chainId: 42431,
    owner,
    engine: { kind: 'erc4626', venue },
    core: { migrationMode: 'OperatorEnabled' },
  },
  { deployer: owner },
)
const record = {
  target: { chainId: profile.chainId, genesisHash },
  addresses: { engine, earnVault: vault, earnShare: share, earnFees: fees, asset },
  assetDecimals: 6,
  source: { contractVerification: 'verified' },
} as EarnDeploymentRecord

function options(rpcUrl: string) {
  return { account: owner, assets: '1', broadcast: false, environment: {}, profile, record, rpcUrl }
}

describe('depositEarnProfile', () => {
  test('refuses funding a verification-pending record before any RPC or key access', async () => {
    await expect(
      depositEarnProfile({
        broadcast: true,
        record: { source: { contractVerification: 'pending' } },
      } as never),
    ).rejects.toThrow('Source verification must be complete before funding')
  })

  test.each([false, true])(
    'rejects a creation engine bound to a different authored venue before quoting or funding (broadcast=%s)',
    async (broadcast) => {
      const rpc = await depositRpc({ venue: migratedVenue })
      try {
        const privateKey = generatePrivateKey()
        await expect(
          depositEarnProfile({
            ...options(rpc.url),
            broadcast,
            account: privateKeyToAccount(privateKey).address,
            environment: { DEPLOYER_PRIVATE_KEY: privateKey },
          }),
        ).rejects.toThrow(`engine venue is ${migratedVenue}, expected ${venue}`)
        expect(rpc.methods).not.toContain('eth_blockNumber')
        expect(rpc.methods).not.toContain('eth_sendRawTransaction')
      } finally {
        await rpc.close()
      }
    },
  )

  test('previews the unchanged engine at its authored venue', async () => {
    const rpc = await depositRpc()
    try {
      await expect(depositEarnProfile(options(rpc.url))).resolves.toMatchObject({
        state: 'preview',
        expectedEarnShares: '1000000',
      })
      expect(rpc.quotes).toEqual([venue])
    } finally {
      await rpc.close()
    }
  })

  test('quotes the live venue after an operator-enabled migration without requiring the original venue', async () => {
    const rpc = await depositRpc({ engine: migratedEngine, venue: migratedVenue })
    try {
      await expect(depositEarnProfile(options(rpc.url))).resolves.toMatchObject({
        state: 'preview',
        expectedEarnShares: '1000000',
      })
      expect(rpc.quotes).toEqual([migratedVenue])
    } finally {
      await rpc.close()
    }
  })

  test('requires the profile as well as the vault to allow operator migration', async () => {
    const rpc = await depositRpc({ engine: migratedEngine, venue: migratedVenue })
    try {
      await expect(
        depositEarnProfile({
          ...options(rpc.url),
          profile: { ...profile, core: { ...profile.core, migrationMode: 'UserOnly' } },
        }),
      ).rejects.toThrow('Profile does not allow operator engine migration')
      expect(rpc.quotes).toEqual([])
    } finally {
      await rpc.close()
    }
  })

  test('rejects a changed engine when the vault disallows operator migration', async () => {
    const rpc = await depositRpc({ engine: migratedEngine, venue: migratedVenue, mode: 0 })
    try {
      await expect(depositEarnProfile(options(rpc.url))).rejects.toThrow(
        'EarnVault current engine changed without OperatorEnabled migration',
      )
      expect(rpc.quotes).toEqual([])
    } finally {
      await rpc.close()
    }
  })

  test('accepts an adopted engine without an authored venue but rejects a substituted record engine', async () => {
    const rpc = await depositRpc()
    const adopted = { ...profile, engine: { kind: profile.engine.kind, address: engine } }
    try {
      await expect(
        depositEarnProfile({ ...options(rpc.url), profile: adopted }),
      ).resolves.toMatchObject({ state: 'preview' })
      const before = rpc.methods.length
      await expect(
        depositEarnProfile({
          ...options(rpc.url),
          profile: adopted,
          record: { ...record, addresses: { ...record.addresses, engine: migratedEngine } },
        }),
      ).rejects.toThrow('does not match configured engine')
      expect(rpc.methods).toHaveLength(before)
    } finally {
      await rpc.close()
    }
  })
})

async function depositRpc(current: { engine?: Address; venue?: Address; mode?: number } = {}) {
  const activeEngine = current.engine ?? engine
  const activeVenue = current.venue ?? venue
  const methods: string[] = []
  const quotes: Address[] = []
  const abi = [...earnVaultAbi, ...earnFeesAbi, ...erc4626EngineAbi, ...erc20Abi, ...erc4626Abi]
  const values: Record<string, unknown> = {
    [`${vault}.engine`]: activeEngine,
    [`${vault}.asset`]: asset,
    [`${vault}.earnShare`]: share,
    [`${vault}.earnFees`]: fees,
    [`${vault}.engineMigrationMode`]: current.mode ?? 1,
    [`${vault}.depositsPaused`]: false,
    [`${vault}.remainingDepositCapacity`]: 100_000_000n,
    [`${vault}.totalEarnShares`]: 10_000_000n,
    [`${vault}.engineShares`]: 10_000_000n,
    [`${activeEngine}.asset`]: asset,
    [`${activeEngine}.earnVault`]: vault,
    [`${activeEngine}.vault`]: activeVenue,
    [`${fees}.earnVault`]: vault,
    [`${fees}.earnShare`]: share,
    [`${fees}.previewAccruedFees`]: {
      totalFeeEarnShares: 0n,
      activeAssets: 10_000_000n,
      positiveAccrualAssets: 0n,
      fixedFeeAssets: 0n,
      excessFeeAssets: 0n,
      totalFeeAssets: 0n,
      preFeeValuePerEarnShare: 0n,
      postFeeValuePerEarnShare: 0n,
      targetValuePerEarnShare: 0n,
      allocationCount: 0,
      allocations: Array.from({ length: 5 }, () => ({
        account: owner,
        feeAssets: 0n,
        feeEarnShares: 0n,
      })),
    },
    [`${asset}.symbol`]: 'USD',
    [`${asset}.decimals`]: 6,
    [`${asset}.balanceOf`]: 100_000_000n,
    [`${share}.symbol`]: 'EarnUSD',
    [`${share}.decimals`]: 6,
    [`${activeVenue}.previewDeposit`]: 1_000_000n,
  }
  const server = createServer(async (request, response) => {
    let body = ''
    for await (const chunk of request) body += chunk.toString()
    const { id, method, params } = JSON.parse(body)
    methods.push(method)
    response.setHeader('Content-Type', 'application/json')
    try {
      const result = (() => {
        if (method === 'eth_chainId') return '0xa5bf'
        if (method === 'eth_getBlockByNumber')
          return { hash: genesisHash, number: '0x0', timestamp: '0x0', transactions: [] }
        if (method === 'eth_getCode') return '0x01'
        if (method === 'eth_blockNumber') return '0x1'
        if (method !== 'eth_call') throw new Error(`Unexpected RPC method ${method}`)
        const target = getAddress(params[0].to)
        const data = params[0].data as Hex
        const { functionName, args } = decodeFunctionData({ abi, data })
        const key = `${target}.${functionName}`
        if (functionName === 'previewDeposit') quotes.push(target)
        const value =
          functionName === 'supportsInterface'
            ? args?.[0] === toFunctionSelector('depositInKind(uint256,address)')
            : values[key]
        if (value === undefined) throw new Error(`Unexpected contract read ${key}`)
        return encodeFunctionResult({ abi, functionName, result: value } as never)
      })()
      response.end(JSON.stringify({ jsonrpc: '2.0', id, result }))
    } catch (error) {
      response.end(
        JSON.stringify({
          jsonrpc: '2.0',
          id,
          error: { code: -32601, message: error instanceof Error ? error.message : String(error) },
        }),
      )
    }
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const bound = server.address()
  if (!bound || typeof bound === 'string') throw new Error('Test RPC has no listening port')
  return {
    methods,
    quotes,
    url: `http://127.0.0.1:${bound.port}`,
    close: () =>
      new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      ),
  }
}
