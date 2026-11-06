import {
  createPublicClient,
  custom,
  decodeFunctionData,
  encodeFunctionResult,
  getAddress,
  zeroAddress,
  type Address,
  type Hex,
  type PublicClient,
} from 'viem'
import { Abis, Addresses } from 'viem/tempo'
import { describe, expect, it, vi } from 'vitest'

import type { EarnStack } from '../../../core/stack.js'
import {
  assertAccessRemovalSafe,
  requiredAccessMembers,
  setAccessEligibility,
} from './membership.js'

type Client = Parameters<typeof assertAccessRemovalSafe>[0]
const address = (value: number): Address => getAddress(`0x${value.toString(16).padStart(40, '0')}`)

/** A protected public stack with only the fields access membership reads. */
function protectedDeployment() {
  return {
    id: 'protected',
    network: { name: 'moderato', chainId: 42431 },
    contracts: {
      asset: address(1),
      earnShare: address(2),
      earnVault: address(3),
      earnFees: address(4),
      engine: address(5),
      venue: address(6),
    },
    access: { kind: 'tip403-whitelist', transferPolicyId: '469' },
    operations: {
      owner: address(7),
      revenueShareRecipient: address(8),
      factory: address(9),
      accessAdministrator: address(7),
    },
    metadata: { deployedAtBlock: '0x1d15897' },
  } as unknown as EarnStack
}

describe('access removal safety', () => {
  it('rejects every required protocol member before querying async claims', async () => {
    const deployment = protectedDeployment()
    const distributor = getAddress('0x000000000000000000000000000000000000d157')
    const treasury = getAddress('0x0000000000000000000000000000000000007ea5')
    deployment.operations!.earnMerkleRewardDistributor = distributor
    const feeRecipients = [address(0xf1), address(0xf2)]
    const excessRecipient = address(0xf3)
    const client = {
      getLogs: vi.fn(),
      readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
        if (functionName === 'treasury') return treasury
        if (functionName === 'currentFeeConfigId') return 2n
        if (functionName === 'feeConfig') {
          return {
            fixedFeeCount: 2,
            fixedFees: [
              ...feeRecipients.map((account) => ({ account, rateBps: 100 })),
              { account: address(0xff), rateBps: 0 },
              { account: address(0xff), rateBps: 0 },
            ],
            excess: { enabled: true, account: excessRecipient },
          }
        }
        return undefined
      }),
    } as unknown as Client & Pick<PublicClient, 'getLogs'>

    const required = await requiredAccessMembers(client, deployment)
    // Removing the distributor or its treasury would block reward payouts, and removing any current
    // fee recipient would block its claims.
    expect(required).toEqual(
      expect.arrayContaining([
        deployment.contracts.earnFees,
        distributor,
        treasury,
        ...feeRecipients,
        excessRecipient,
      ]),
    )
    expect(required).not.toContain(address(0xff))
    for (const member of required) {
      await expect(assertAccessRemovalSafe(client, deployment, member)).rejects.toThrow(
        'Refusing to remove required protocol address',
      )
    }
    expect(client.getLogs).not.toHaveBeenCalled()
  })

  it('rejects removal while an async claim to the account remains open', async () => {
    const deployment = protectedDeployment()
    const target = getAddress('0x000000000000000000000000000000000000bEEF')
    const requestId = `0x${'ab'.repeat(32)}` as const
    const client = {
      getBlockNumber: vi.fn().mockResolvedValue(BigInt(deployment.metadata.deployedAtBlock!)),
      getLogs: vi.fn().mockResolvedValue([{ args: { requestId } }]),
      readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
        if (functionName === 'currentFeeConfigId') return 1n
        if (functionName === 'feeConfig') {
          return { fixedFeeCount: 0, fixedFees: [], excess: { enabled: false } }
        }
        return { open: true, receiver: target }
      }),
    } as unknown as Client

    await expect(assertAccessRemovalSafe(client, deployment, target)).rejects.toThrow(
      `open async claim ${requestId}`,
    )
  })
})

// These are deterministic RPC-boundary fixtures, not a native TIP-1022 or hosted-chain test.
const master = address(0xbeef)
const alias = getAddress('0x12345678fdfdfdfdfdfdfdfdfdfd000000000001')
const siblingAlias = getAddress('0x12345678fdfdfdfdfdfdfdfdfdfd000000000002')
const requestId = `0x${'ab'.repeat(32)}` as const

describe('access removal policy identities', () => {
  it('rejects a master used by a required fee-recipient alias', async () => {
    const client = removalClient({ feeRecipient: alias })
    await expect(assertAccessRemovalSafe(client, protectedDeployment(), master)).rejects.toThrow(
      'Refusing to remove required protocol address',
    )
    expect(client.getLogs).not.toHaveBeenCalled()
  })

  it.each([master, siblingAlias])(
    'rejects removing %s while an alias claim is open',
    async (target) => {
      const client = removalClient({ receiver: alias })
      await expect(assertAccessRemovalSafe(client, protectedDeployment(), target)).rejects.toThrow(
        `open async claim ${requestId}`,
      )
      expect(client.getLogs.mock.calls[0]![0]).not.toHaveProperty('args')
    },
  )

  it('allows an unrelated identity when an alias claim is open', async () => {
    const client = removalClient({ receiver: alias })
    await expect(
      assertAccessRemovalSafe(client, protectedDeployment(), address(0xcafe)),
    ).resolves.toBeUndefined()
  })

  it('allows removal after the alias claim closes without resolving its former receiver', async () => {
    const client = removalClient({ receiver: alias, open: false, registryMaster: zeroAddress })
    await expect(
      assertAccessRemovalSafe(client, protectedDeployment(), master),
    ).resolves.toBeUndefined()
    expect(client.registry).not.toHaveBeenCalled()
  })

  it('fails closed if an open receiver alias has no registered master', async () => {
    const client = removalClient({ receiver: alias, registryMaster: zeroAddress })
    await expect(assertAccessRemovalSafe(client, protectedDeployment(), master)).rejects.toThrow(
      'has no registered master',
    )
  })

  it('propagates registry and claim-history failures', async () => {
    const registryFailure = removalClient({ receiver: alias })
    registryFailure.registry.mockRejectedValue(new Error('registry unavailable'))
    await expect(
      assertAccessRemovalSafe(registryFailure, protectedDeployment(), master),
    ).rejects.toThrow('registry unavailable')
    const historyFailure = removalClient()
    historyFailure.getLogs.mockRejectedValue(new Error('history unavailable'))
    await expect(
      assertAccessRemovalSafe(historyFailure, protectedDeployment(), master),
    ).rejects.toThrow('history unavailable')
  })
})

describe('setAccessEligibility removal', () => {
  it.each(['alias claim', 'missing anchor'])(
    'rejects %s before asking the wallet to sign',
    async (failure) => {
      const deployment = protectedDeployment()
      if (failure === 'missing anchor') deployment.metadata.deployedAtBlock = ''
      const client = removalClient(failure === 'alias claim' ? { receiver: alias } : {})
      const request = vi.fn(async () => {
        throw new Error('Unexpected signing request')
      })
      await expect(
        setAccessEligibility({
          allowed: false,
          client,
          deployment,
          target: siblingAlias,
          wallet: { request } as unknown as Parameters<typeof setAccessEligibility>[0]['wallet'],
        }),
      ).rejects.toThrow(failure === 'alias claim' ? 'open async claim' : 'claim scan anchor')
      expect(request).not.toHaveBeenCalled()
    },
  )
})

describe('access removal claim scan anchor', () => {
  it.each([undefined, null, '', '-1', 'not-a-block', '0x', '1.5'])(
    'rejects invalid anchor %s',
    async (anchor) => {
      const deployment = protectedDeployment()
      Object.assign(deployment.metadata, { deployedAtBlock: anchor })
      const client = removalClient()
      await expect(assertAccessRemovalSafe(client, deployment, master)).rejects.toThrow(
        'valid deployedAtBlock claim scan anchor',
      )
      expect(client.getLogs).not.toHaveBeenCalled()
    },
  )

  it('rejects an anchor beyond the chain head', async () => {
    const deployment = protectedDeployment()
    deployment.metadata.deployedAtBlock = '0x2'
    const client = removalClient({ head: 1n })
    await expect(assertAccessRemovalSafe(client, deployment, master)).rejects.toThrow(
      'beyond the current chain head',
    )
    expect(client.getLogs).not.toHaveBeenCalled()
  })

  it.each(['0', '0x0'])('scans from genesis for anchor %s', async (anchor) => {
    const deployment = protectedDeployment()
    deployment.metadata.deployedAtBlock = anchor
    const client = removalClient({ head: 0n, receiver: master })
    await expect(assertAccessRemovalSafe(client, deployment, master)).rejects.toThrow(
      'open async claim',
    )
    expect(client.getLogs).toHaveBeenCalledWith(
      expect.objectContaining({ fromBlock: 0n, toBlock: 0n }),
    )
  })

  it('covers the full inclusive history in bounded ranges', async () => {
    const deployment = protectedDeployment()
    deployment.metadata.deployedAtBlock = '0x0'
    const client = removalClient({ head: 200_000n })
    await expect(assertAccessRemovalSafe(client, deployment, master)).resolves.toBeUndefined()
    expect(client.getLogs.mock.calls.map(([range]) => [range.fromBlock, range.toBlock])).toEqual([
      [0n, 99_999n],
      [100_000n, 199_999n],
      [200_000n, 200_000n],
    ])
  })
})

function removalClient(
  options: {
    feeRecipient?: Address
    head?: bigint
    open?: boolean
    receiver?: Address
    registryMaster?: Address
  } = {},
) {
  const registry = vi.fn(
    async ({ method, params }: { method: string; params?: unknown[] }): Promise<Hex> => {
      if (method !== 'eth_call') throw new Error(`Unexpected registry method ${method}`)
      const call = params![0] as { to: Address; data: Hex }
      expect(getAddress(call.to)).toBe(getAddress(Addresses.addressRegistry))
      const decoded = decodeFunctionData({ abi: Abis.addressRegistry, data: call.data })
      expect(decoded.functionName).toBe('getMaster')
      expect(decoded.args).toEqual(['0x12345678'])
      return encodeFunctionResult({
        abi: Abis.addressRegistry,
        functionName: 'getMaster',
        result: options.registryMaster ?? master,
      })
    },
  )
  return {
    ...createPublicClient({ transport: custom({ request: registry }, { retryCount: 0 }) }),
    registry,
    getBlockNumber: vi
      .fn()
      .mockResolvedValue(options.head ?? BigInt(protectedDeployment().metadata.deployedAtBlock)),
    getLogs: vi.fn(async (_range: { fromBlock: bigint; toBlock: bigint }) =>
      options.receiver ? [{ args: { requestId } }] : [],
    ),
    readContract: vi.fn(async ({ functionName }: { functionName: string }) => {
      if (functionName === 'currentFeeConfigId') return 1n
      if (functionName === 'feeConfig') {
        return {
          fixedFeeCount: options.feeRecipient ? 1 : 0,
          fixedFees: options.feeRecipient ? [{ account: options.feeRecipient, rateBps: 100 }] : [],
          excess: { enabled: false },
        }
      }
      if (functionName === 'pendingRedeem')
        return { open: options.open ?? true, receiver: options.receiver }
      throw new Error(`Unexpected read ${functionName}`)
    }),
  } as unknown as Client & {
    registry: typeof registry
    getLogs: ReturnType<
      typeof vi.fn<(range: { fromBlock: bigint; toBlock: bigint }) => Promise<unknown[]>>
    >
  }
}
