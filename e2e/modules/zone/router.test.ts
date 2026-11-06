import { describe, expect, it } from 'vitest'
import { getAddress, stringify, zeroAddress, type Address } from 'viem'
import type { DeploymentPublicClient, E2eContext, E2eStack } from '../../harness/context.js'
import { routerIntegrity, validateRouter } from './router.js'

const router: Address = '0x0000000000000000000000000000000000000001'
const asset: Address = '0x0000000000000000000000000000000000000002'
const privateAsset: Address = '0x0000000000000000000000000000000000000003'
const earnShare: Address = '0x0000000000000000000000000000000000000004'
const earnVault: Address = '0x0000000000000000000000000000000000000005'
const portal: Address = '0x0000000000000000000000000000000000000006'
const pool: Address = '0x0000000000000000000000000000000000000007'
const oracle: Address = '0x0000000000000000000000000000000000000008'

const temporaryAllowances = [
  ['vault asset to EarnVault', asset, earnVault],
  ['EarnShare to EarnVault', earnShare, earnVault],
  ['private asset to source Portal', privateAsset, portal],
  ['EarnShare to source Portal', earnShare, portal],
  ['vault asset to conversion pool', asset, pool],
  ['private asset to conversion pool', privateAsset, pool],
] as const

describe('validateRouter', () => {
  it.each([false, true])(
    'accepts one-unit preexisting donations (same asset: %s)',
    async (sameAsset) => {
      const { client, deployment, balances } = routerFixture({ sameAsset })
      for (const token of [asset, privateAsset, earnShare]) balances.set(token, 1n)
      await expect(validateRouter(client, deployment)).resolves.toBeUndefined()
    },
  )

  it.each(temporaryAllowances)(
    'rejects a residual allowance: %s',
    async (label, token, spender) => {
      const { client, deployment, allowances } = routerFixture()
      allowances.set(allowanceKey(token, spender), 1n)
      await expect(validateRouter(client, deployment)).rejects.toThrow(
        `EarnRouter retains an allowance at rest: ${label}`,
      )
    },
  )

  it('checks vault and Portal allowances without a conversion pool', async () => {
    const { client, deployment, allowanceReads } = routerFixture({ sameAsset: true })
    await validateRouter(client, deployment)
    expect(allowanceReads).toEqual([
      allowanceKey(asset, earnVault),
      allowanceKey(earnShare, earnVault),
      allowanceKey(asset, portal),
      allowanceKey(earnShare, portal),
    ])
  })

  it('refuses to skip Portal allowance checks when its binding is missing', async () => {
    const { client, deployment } = routerFixture()
    delete deployment.network.zone
    await expect(validateRouter(client, deployment)).rejects.toThrow(
      'EarnRouter has no source Portal',
    )
  })

  it('still rejects an unsupported flow', async () => {
    const { client, deployment, flows } = routerFixture()
    flows[3] = true
    await expect(validateRouter(client, deployment)).rejects.toThrow(
      'EarnRouter advertises an unknown flow',
    )
  })

  it('still enforces conversion liquidity', async () => {
    const { client, deployment, liquidity } = routerFixture()
    liquidity.deposit = 1n
    await expect(validateRouter(client, deployment)).rejects.toThrow(
      'private deposits need at least',
    )
  })

  it('does nothing for a deployment without a router', async () => {
    const { client, deployment, reads } = routerFixture()
    delete deployment.contracts.earnRouter
    await expect(validateRouter(client, deployment)).resolves.toBeUndefined()
    expect(reads).toEqual([])
  })
})

describe('routerIntegrity', () => {
  it('preserves exact donated baselines including the private input without fixture assets', async () => {
    const { context } = routerFixture()
    const before = await routerIntegrity(context)
    expect(before).toMatchObject({
      vaultAssetBalance: 2n,
      privateAssetBalance: 3n,
      earnShareBalance: 4n,
      privateAsset,
    })
    expect(before?.allowances).toEqual(
      temporaryAllowances.map(([, token, spender]) => ({ token, spender, allowance: 0n })),
    )
    expect(stringify(await routerIntegrity(context))).toBe(stringify(before))
  })

  it.each([
    ['vault asset residue', asset, 1n],
    ['vault asset deficit', asset, -1n],
    ['private asset residue', privateAsset, 1n],
    ['private asset deficit', privateAsset, -1n],
    ['EarnShare residue', earnShare, 1n],
    ['EarnShare deficit', earnShare, -1n],
  ] as const)('exposes %s to the harness exact comparison', async (_label, token, delta) => {
    const { context, balances } = routerFixture()
    const baseline = await routerIntegrity(context)
    balances.set(token, balances.get(token)! + delta)
    expect(stringify(await routerIntegrity(context))).not.toBe(stringify(baseline))
  })

  it.each(temporaryAllowances)(
    'refuses even a preexisting allowance: %s',
    async (label, token, spender) => {
      const { context, allowances } = routerFixture()
      allowances.set(allowanceKey(token, spender), 1n)
      await expect(routerIntegrity(context)).rejects.toThrow(
        `EarnRouter retains an allowance at rest: ${label}`,
      )
    },
  )

  it('uses the vault asset as the private balance for same-asset routes', async () => {
    const { context, allowanceReads } = routerFixture({ sameAsset: true })
    const snapshot = await routerIntegrity(context)
    expect(snapshot).toMatchObject({
      vaultAssetBalance: 2n,
      privateAssetBalance: 2n,
      earnShareBalance: 4n,
      privateAsset: asset,
      pool: zeroAddress,
    })
    expect(allowanceReads).toHaveLength(4)
    expect(allowanceReads.every((key) => !key.endsWith(`:${zeroAddress}`))).toBe(true)
  })

  it('retains admission checks without comparing legitimate pool inventory movement', async () => {
    const { context, liquidity } = routerFixture()
    const baseline = await routerIntegrity(context)
    liquidity.deposit -= 1n
    liquidity.redeem += 1n
    expect(await routerIntegrity(context)).toEqual(baseline)
    liquidity.admitted = false
    expect(await routerIntegrity(context)).not.toEqual(baseline)
  })

  it('does nothing for a deployment without a router', async () => {
    const { context, reads } = routerFixture()
    delete context.contracts.earnRouter
    expect(await routerIntegrity(context)).toBeUndefined()
    expect(reads).toEqual([])
  })
})

function allowanceKey(token: Address, spender: Address) {
  return `${getAddress(token)}:${getAddress(spender)}`
}

/** Deterministic contract reads only; no RPC connection, signing, or transaction submission. */
function routerFixture(options: { sameAsset?: boolean } = {}) {
  const balances = new Map<Address, bigint>([
    [asset, 2n],
    [privateAsset, 3n],
    [earnShare, 4n],
  ])
  const allowances = new Map<string, bigint>()
  const reads: string[] = []
  const allowanceReads: string[] = []
  const flows = [true, true, false, false]
  const liquidity = {
    paused: false,
    admitted: true,
    atPar: true,
    deposit: 2_000_000n,
    redeem: 2_000_000n,
  }
  const client = {
    getBlock: async () => ({ timestamp: 1000n }),
    readContract: async (call: {
      address: Address
      functionName: string
      args?: readonly unknown[]
    }) => {
      reads.push(call.functionName)
      switch (call.functionName) {
        case 'pool':
          return options.sameAsset ? zeroAddress : pool
        case 'privateAsset':
          return options.sameAsset ? asset : privateAsset
        case 'supportsFlow':
          return flows[Number(call.args?.[0])]
        case 'liquidityStatus':
          return [
            liquidity.paused,
            liquidity.admitted,
            liquidity.atPar,
            liquidity.deposit,
            liquidity.redeem,
          ]
        case 'oracle':
          return oracle
        case 'maxOracleAge':
          return 60n
        case 'latestPrice':
          return [1_000_000n, 1000n]
        case 'balanceOf': {
          if (call.args?.[0] !== router) throw new Error('Unexpected balance owner')
          const balance = balances.get(getAddress(call.address))
          if (balance === undefined) throw new Error('Unexpected balance token')
          return balance
        }
        case 'allowance': {
          if (call.args?.[0] !== router) throw new Error('Unexpected allowance owner')
          const key = allowanceKey(call.address, call.args[1] as Address)
          allowanceReads.push(key)
          return allowances.get(key) ?? 0n
        }
        default:
          throw new Error(`Unexpected read: ${call.functionName}`)
      }
    },
  } as unknown as DeploymentPublicClient
  const deployment = {
    contracts: { asset, earnShare, earnVault, earnRouter: router },
    network: { zone: { portal } },
    capabilities: { privateRouting: true },
    modes: {},
  } as E2eStack
  // Hosted deployments may have neither fixture tokens nor a separate alternate asset.
  const context = {
    deployment,
    contracts: deployment.contracts,
    assets: { base: asset, alternate: asset },
    l1Public: client,
  } as E2eContext
  return {
    client,
    deployment,
    context,
    balances,
    allowances,
    reads,
    allowanceReads,
    flows,
    liquidity,
  }
}
