import { getAddress, type Address, type PublicClient } from 'viem'
import { describe, expect, it, vi } from 'vitest'

import type { EarnStack } from '../../core/stack.js'
import { assertAccessRemovalSafe, requiredAccessMembers } from './membership.js'

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
        return { open: true }
      }),
    } as unknown as Client

    await expect(assertAccessRemovalSafe(client, deployment, target)).rejects.toThrow(
      `open async claim ${requestId}`,
    )
  })
})
