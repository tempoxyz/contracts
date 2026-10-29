import type { PublicEarnStack } from '@tempoxyz/contracts/deployments'
import { erc20Abi, type Address, type PublicClient } from 'viem'

import { balanceTokens, privateBalanceTokens } from '../../deployments/tokens.js'
import type * as Zone from './Zone.js'

export type Snapshot = {
  privateEarnShares: bigint
  privateTokens: Map<Address, bigint>
  /** Public Tempo balances of the tokens the account can move into the Zone. */
  publicFunding: Map<Address, bigint>
}

/** Reads the public funding balances and private balances for one account. */
export async function read(options: read.Options): Promise<Snapshot> {
  const tokens = balanceTokens(options.deployment)
  const [publicFunding, privateBalances] = await Promise.all([
    Promise.all(
      options.fundingTokens.map((token) =>
        options.l1Client.readContract({
          address: token,
          abi: erc20Abi,
          functionName: 'balanceOf',
          args: [options.account],
        }),
      ),
    ),
    options.readPrivateBalances?.() ?? directPrivateBalances(options),
  ])
  return {
    privateEarnShares: requiredBalance(privateBalances, options.deployment.contracts.earnShare),
    privateTokens: new Map(tokens.map((token) => [token, requiredBalance(privateBalances, token)])),
    publicFunding: new Map(
      options.fundingTokens.map((token, index) => [token, publicFunding[index]!]),
    ),
  }
}

async function directPrivateBalances(options: read.Options) {
  const tokens = privateBalanceTokens(options.deployment)
  const balances = await Promise.all(
    tokens.map((token) => balance(options.zoneClient, token, options.account)),
  )
  return new Map(tokens.map((token, index) => [token, balances[index] ?? 0n]))
}

function requiredBalance(balances: Map<Address, bigint>, token: Address) {
  for (const [address, balance] of balances) {
    if (address.toLowerCase() === token.toLowerCase()) return balance
  }
  throw new Error(`Private balance response omitted registered token ${token}.`)
}

export declare namespace read {
  type Options = {
    account: Address
    deployment: PublicEarnStack
    fundingTokens: readonly Address[]
    l1Client: Pick<PublicClient, 'readContract'>
    readPrivateBalances?: (() => Promise<Map<Address, bigint>>) | undefined
    zoneClient: Zone.Client
  }
}

/** Reads one private TIP-20 balance. */
export function balance(client: Zone.Client, token: Address, account: Address) {
  return client.readContract({
    address: token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [account],
  })
}
