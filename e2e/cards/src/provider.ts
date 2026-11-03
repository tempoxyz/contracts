// The card provider seam of the card E2E. The run (run.ts) is the same for every provider: it starts a
// Tempo L1 and Zone, spends publicly through the provider's CardSpender and privately through a
// Spend-mode ZoneRouter that lists that program as its spender, and checks what Tempo guarantees. A provider supplies only
// what is its own: its contracts and program (deploy), where its spends pay (destinations), and its own
// back office for the money once it lands (settle).
import type { Address, Hex } from 'viem'
import type { PrivateKeyAccount } from 'viem/accounts'

import type { PublicClient, WalletClient } from './clients.js'

/** A destination a spend pays, with the provider-specific evidence its program reads. */
export type Destination = { address: Address; hint: bigint; label: string }

export type Deployed = {
  /** The program's CardSpender: the public spend entry point and the router's spender. */
  program: Address
  /** The program's provider contract (its ICardProvider). */
  provider: Address
  router: Address
  routerFactory: Address
  /** A TIP-20 with a transfer policy, to launch the Zone with. */
  zoneToken: Address
  earn?: { vault: Address; earnShare: Address }
  /** Where a public spend from the cardholder's account pays. */
  publicDestination: Destination
  /** Where a private spend pays. It must not name the cardholder. */
  privateDestination: Destination
  /** A provider destination a private spend must not reach, so the spend bounces back into the Zone. */
  refusedPrivateDestination: Destination
}

export type Context = {
  l1Public: PublicClient
  l1Wallet(account: PrivateKeyAccount): WalletClient
  step(n: number, text: string): void
  cardholder: PrivateKeyAccount
  token: Address
  /** What each destination received from this run's spends. */
  funded: Map<Address, bigint>
}

export interface CardProvider {
  name: string
  /** L1 accounts the provider needs funded with gas before `deploy`. */
  accounts: PrivateKeyAccount[]
  /** Deploys the provider's own contracts, its provider contract and a CardSpender over it. */
  deploy(input: {
    rpcUrl: string
    deployerPk: Hex
    cardholder: Address
    zoneId: number
    earn: boolean
  }): Deployed
  /** Runs the provider's own handling of the funded destinations, with its own checks. */
  settle(ctx: Context, deployed: Deployed, firstStep: number): Promise<number>
}
