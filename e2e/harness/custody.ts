import { earnVaultAbi } from '@tempoxyz/contracts/abis'
import { erc20Abi, type Address } from 'viem'
import type { DeploymentPublicClient, E2eStack } from './context.js'
import { assert } from './support/utils.js'

/** Reports raw vault residue separately from backing, which must remain accounting-aligned. */
export async function readVaultCustody(
  client: Pick<DeploymentPublicClient, 'readContract'>,
  contracts: Pick<E2eStack['contracts'], 'asset' | 'venue' | 'earnVault'>,
) {
  const balance = (token: Address) =>
    client.readContract({
      address: token,
      abi: erc20Abi,
      functionName: 'balanceOf',
      args: [contracts.earnVault],
    })
  const [assets, venueShares, aligned] = await Promise.all([
    balance(contracts.asset),
    balance(contracts.venue),
    client.readContract({
      address: contracts.earnVault,
      abi: earnVaultAbi,
      functionName: 'isAccountingAligned',
    }),
  ])
  assert(aligned === true, 'EarnVault accounting is not aligned')
  return { assets, venueShares }
}
