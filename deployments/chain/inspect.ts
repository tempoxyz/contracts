import { getAddress, type Address, type PublicClient } from 'viem'

/** Supplies the latest block time, e.g. to bound an oracle report's age. */
export type LatestBlockClient = { getBlock: () => Promise<{ timestamp: bigint }> }

/** A live binding that disagrees with the expected deployment, as opposed to a failed read. */
export class InspectionMismatchError extends Error {
  override name = 'InspectionMismatchError'
}

export function equalAddress(actual: Address, expected: Address, label: string) {
  if (getAddress(actual) !== getAddress(expected)) {
    throw new InspectionMismatchError(`${label} is ${actual}, expected ${expected}`)
  }
}

/** Requires nonempty runtime code at every labeled address. */
export async function requireCode(
  client: Pick<PublicClient, 'getCode'>,
  addresses: Record<string, Address>,
) {
  await Promise.all(
    Object.entries(addresses).map(async ([label, address]) => {
      const code = await client.getCode({ address })
      if (!code || code === '0x') throw new Error(`No runtime code at ${label} ${address}`)
    }),
  )
}
