import { getAddress, type Address } from 'viem'

import type { PrivateTransaction } from '../../deployments/catalog.js'

/** Reads the connected account's registered Earn balances through the Worker. */
export async function readBalances(options: read.Options): Promise<Map<Address, bigint>> {
  const { balances } = (await read('balances', options)) as {
    balances: { amount: string; token: Address }[]
  }
  return new Map(balances.map(({ amount, token }) => [getAddress(token), BigInt(amount)]))
}

/** Reads the connected account's newest private Zone transactions through the Worker. */
export async function readTransactions(options: read.Options): Promise<PrivateTransaction[]> {
  const { transactions } = (await read('transactions', options)) as {
    transactions: PrivateTransaction[]
  }
  return transactions
}

/**
 * Posts one Zone read to the same-origin Worker, which validates the request, reads only the
 * deployment's registered tokens, and validates the Tempo API response. The browser checks only
 * that the response answers for the requested account.
 */
async function read(kind: 'balances' | 'transactions', options: read.Options) {
  const response = await fetch(
    `/api/environments/${encodeURIComponent(options.environmentId)}/zones/${options.zone.id}/${kind}`,
    {
      body: JSON.stringify({ account: options.account, deploymentId: options.deploymentId }),
      headers: { 'Content-Type': 'application/json' },
      method: 'POST',
    },
  )
  const body = (await response.json().catch(() => undefined)) as
    | { account?: unknown; error?: unknown }
    | undefined
  if (!response.ok) {
    throw new Error(
      typeof body?.error === 'string'
        ? body.error
        : `Zone ${kind} request failed with status ${response.status}.`,
    )
  }
  if (
    typeof body?.account !== 'string' ||
    getAddress(body.account) !== getAddress(options.account)
  ) {
    throw new Error(`The Zone ${kind} response belongs to a different account.`)
  }
  return body
}

declare namespace read {
  type Options = {
    account: Address
    deploymentId: string
    environmentId: string
    zone: { id: number }
  }
}
