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
      getLogs: vi.fn().mockResolvedValue([claimEvent('RedeemRequested', requestId)]),
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

  it('does not let an unregistered claim receiver block unrelated removals', async () => {
    const client = removalClient({ receiver: alias, registryMaster: zeroAddress })
    await expect(
      assertAccessRemovalSafe(client, protectedDeployment(), master),
    ).resolves.toBeUndefined()
    expect(client.registry).toHaveBeenCalled()
  })

  it('still refuses an unregistered removal target before querying claims', async () => {
    const client = removalClient({ registryMaster: zeroAddress })
    await expect(assertAccessRemovalSafe(client, protectedDeployment(), alias)).rejects.toThrow(
      'has no registered master',
    )
    expect(client.getLogs).not.toHaveBeenCalled()
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

/** A second stack attaching the same policy on the same chain, with its own core contracts. */
function siblingDeployment(overrides: { chainId?: number; policyId?: string } = {}) {
  const deployment = protectedDeployment()
  return {
    ...deployment,
    id: 'sibling',
    network: { ...deployment.network, chainId: overrides.chainId ?? deployment.network.chainId },
    contracts: { ...deployment.contracts, earnVault: address(0x13), earnFees: address(0x14) },
    access: { kind: 'tip403-whitelist', transferPolicyId: overrides.policyId ?? '469' },
  } as unknown as EarnStack
}

describe('access removal across stacks sharing a policy', () => {
  it.each(['earnVault', 'earnFees'] as const)(
    "rejects removing the sibling's %s through the selected stack",
    async (key) => {
      const sibling = siblingDeployment()
      const client = removalClient()
      await expect(
        assertAccessRemovalSafe(client, protectedDeployment(), sibling.contracts[key], [sibling]),
      ).rejects.toThrow('Refusing to remove required protocol address')
    },
  )

  it('rejects removing a receiver whose claim is open only on the sibling', async () => {
    const sibling = siblingDeployment()
    const client = removalClient({ receiver: master })
    client.pendingRedeem.mockImplementation(async (_id, vault) => ({
      open: vault === sibling.contracts.earnVault,
      receiver: master,
    }))
    await expect(
      assertAccessRemovalSafe(client, protectedDeployment(), master, [sibling]),
    ).rejects.toThrow(`open async claim ${requestId}`)
    expect(client.getLogs.mock.calls.map(([query]) => query.address)).toEqual([
      protectedDeployment().contracts.earnVault,
      sibling.contracts.earnVault,
    ])
  })

  it.each([
    ['another policy', { policyId: '470' }],
    ['another chain', { chainId: 4217 }],
  ])('ignores a stack on %s', async (_, overrides) => {
    const other = siblingDeployment(overrides)
    const client = removalClient()
    await expect(
      assertAccessRemovalSafe(client, protectedDeployment(), other.contracts.earnVault, [other]),
    ).resolves.toBeUndefined()
    expect(client.getLogs).toHaveBeenCalledTimes(1)
  })

  it('names the sibling stack that blocks a removal', async () => {
    const sibling = siblingDeployment()
    await expect(
      assertAccessRemovalSafe(removalClient(), protectedDeployment(), sibling.contracts.earnVault, [
        sibling,
      ]),
    ).rejects.toThrow(/for stack sibling, EarnVault 0x0+13, which shares policy 469/)
  })

  it('refuses before signing when only the sibling needs the target', async () => {
    const sibling = siblingDeployment()
    const request = vi.fn(async () => {
      throw new Error('Unexpected signing request')
    })
    await expect(
      setAccessEligibility({
        allowed: false,
        client: removalClient(),
        deployment: protectedDeployment(),
        target: sibling.contracts.earnFees,
        wallet: { request } as unknown as Parameters<typeof setAccessEligibility>[0]['wallet'],
        siblings: [sibling],
      }),
    ).rejects.toThrow('Refusing to remove required protocol address')
    expect(request).not.toHaveBeenCalled()
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

describe('access removal outstanding claim scan', () => {
  it('excludes finalized and cancelled history before reading pending state', async () => {
    const deployment = protectedDeployment()
    deployment.metadata.deployedAtBlock = '0'
    const client = removalClient({ head: 1000n, open: false })
    const logs = Array.from({ length: 500 }, (_, index) => {
      const id = claimId(index)
      return [
        claimEvent('RedeemRequested', id, BigInt(index * 2)),
        claimEvent(index % 2 ? 'RedeemFinalized' : 'RedeemCancelled', id, BigInt(index * 2 + 1)),
      ]
    }).flat()
    client.getLogs.mockResolvedValue(logs)
    await expect(assertAccessRemovalSafe(client, deployment, master)).resolves.toBeUndefined()
    expect(client.pendingRedeem).not.toHaveBeenCalled()
    const query = client.getLogs.mock.calls[0]![0]
    expect(query).toMatchObject({
      address: protectedDeployment().contracts.earnVault,
      strict: true,
      events: [
        expect.objectContaining({ name: 'RedeemRequested' }),
        expect.objectContaining({ name: 'RedeemFinalized' }),
        expect.objectContaining({ name: 'RedeemCancelled' }),
      ],
    })
    expect(query).not.toHaveProperty('args')
  })

  it('applies closure events across scan ranges before reading any pending state', async () => {
    const deployment = protectedDeployment()
    deployment.metadata.deployedAtBlock = '0'
    const client = removalClient({ head: 100_001n, open: false })
    client.getLogs
      .mockResolvedValueOnce([claimEvent('RedeemRequested', requestId, 99_999n)])
      .mockResolvedValueOnce([claimEvent('RedeemFinalized', requestId, 100_000n)])
    await expect(assertAccessRemovalSafe(client, deployment, master)).resolves.toBeUndefined()
    expect(client.pendingRedeem).not.toHaveBeenCalled()
  })

  it.each(['RedeemCancelled', 'RedeemFinalized'] as const)(
    'retains an ID requested again after %s, including within the same block',
    async (closed) => {
      const client = removalClient({ receiver: alias })
      // Deliberately unordered: lifecycle order comes from block number and log index.
      client.getLogs.mockResolvedValue([
        claimEvent('RedeemRequested', requestId, 2n, 3),
        claimEvent(closed, requestId, 2n, 2),
        claimEvent('RedeemRequested', requestId, 1n, 1),
      ])
      await expect(assertAccessRemovalSafe(client, protectedDeployment(), master)).rejects.toThrow(
        `open async claim ${requestId}`,
      )
      expect(client.pendingRedeem).toHaveBeenCalledExactlyOnceWith(
        requestId,
        protectedDeployment().contracts.earnVault,
      )
    },
  )

  it('deduplicates request IDs before checking current state', async () => {
    const client = removalClient({ receiver: address(0xcafe) })
    client.getLogs.mockResolvedValue([
      claimEvent('RedeemRequested', requestId),
      claimEvent('RedeemRequested', requestId),
    ])
    await assertAccessRemovalSafe(client, protectedDeployment(), master)
    expect(client.pendingRedeem).toHaveBeenCalledExactlyOnceWith(
      requestId,
      protectedDeployment().contracts.earnVault,
    )
  })

  it('reads outstanding claims in bounded parallel batches, not serially or all at once', async () => {
    const client = removalClient()
    const ids = Array.from({ length: 40 }, (_, index) => claimId(index))
    client.getLogs.mockResolvedValue(ids.map((id) => claimEvent('RedeemRequested', id)))
    let active = 0
    let peak = 0
    client.pendingRedeem.mockImplementation(async () => {
      active++
      peak = Math.max(peak, active)
      await new Promise((resolve) => setTimeout(resolve, 0))
      active--
      return { open: true, receiver: address(0xcafe) }
    })
    await assertAccessRemovalSafe(client, protectedDeployment(), master)
    expect(client.pendingRedeem).toHaveBeenCalledTimes(ids.length)
    expect(peak).toBeGreaterThan(1)
    expect(peak).toBeLessThanOrEqual(16)
  })

  it('checks receivers beyond the first read batch', async () => {
    const client = removalClient()
    const ids = Array.from({ length: 40 }, (_, index) => claimId(index))
    client.getLogs.mockResolvedValue(ids.map((id) => claimEvent('RedeemRequested', id)))
    client.pendingRedeem.mockImplementation(async (id) => ({
      open: true,
      receiver: id === ids.at(-1) ? alias : address(0xcafe),
    }))
    await expect(assertAccessRemovalSafe(client, protectedDeployment(), master)).rejects.toThrow(
      `open async claim ${ids.at(-1)}`,
    )
  })

  it('propagates pending-state errors instead of treating unavailable claims as closed', async () => {
    const client = removalClient({ receiver: master })
    client.pendingRedeem.mockRejectedValue(new Error('pending state unavailable'))
    await expect(assertAccessRemovalSafe(client, protectedDeployment(), master)).rejects.toThrow(
      'pending state unavailable',
    )
  })
})

function claimId(value: number): Hex {
  return `0x${value.toString(16).padStart(64, '0')}`
}

function claimEvent(
  eventName: 'RedeemRequested' | 'RedeemCancelled' | 'RedeemFinalized',
  requestId: Hex,
  blockNumber = 1n,
  logIndex = 0,
) {
  return { eventName, args: { requestId }, blockNumber, logIndex }
}

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
  const pendingRedeem = vi.fn(async (_requestId: Hex, _vault?: Address) => ({
    open: options.open ?? true,
    receiver: options.receiver ?? master,
  }))
  return {
    pendingRedeem,
    ...createPublicClient({ transport: custom({ request: registry }, { retryCount: 0 }) }),
    registry,
    getBlockNumber: vi
      .fn()
      .mockResolvedValue(options.head ?? BigInt(protectedDeployment().metadata.deployedAtBlock)),
    getLogs: vi.fn(async (_range: { address?: Address; fromBlock: bigint; toBlock: bigint }) =>
      options.receiver ? [claimEvent('RedeemRequested', requestId)] : [],
    ),
    readContract: vi.fn(
      async ({
        address: contract,
        functionName,
        args,
      }: {
        address?: Address
        functionName: string
        args?: readonly unknown[]
      }) => {
        if (functionName === 'currentFeeConfigId') return 1n
        if (functionName === 'feeConfig') {
          return {
            fixedFeeCount: options.feeRecipient ? 1 : 0,
            fixedFees: options.feeRecipient
              ? [{ account: options.feeRecipient, rateBps: 100 }]
              : [],
            excess: { enabled: false },
          }
        }
        if (functionName === 'pendingRedeem') return pendingRedeem(args![0] as Hex, contract)
        throw new Error(`Unexpected read ${functionName}`)
      },
    ),
  } as unknown as Client & {
    registry: typeof registry
    pendingRedeem: typeof pendingRedeem
    getLogs: ReturnType<
      typeof vi.fn<
        (range: { address?: Address; fromBlock: bigint; toBlock: bigint }) => Promise<unknown[]>
      >
    >
  }
}
