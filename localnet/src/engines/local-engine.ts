import type { TokenMetadata } from '@tempoxyz/earn/deployments'
import type { EarnDeploymentProfile } from '@tempoxyz/earn/deployments/operations'
import { isAddressEqual, type Address, type Hex, type PublicClient } from 'viem'

import type * as Foundry from '../foundry.js'
import type { Fixtures } from '../deployment/fixtures.js'

export type ReadClient = Pick<PublicClient, 'readContract'>

/**
 * The localnet behavior of one engine kind: the venue it provisions, how a localized profile names
 * it, and the token metadata of its stack.
 */
export type LocalEngine = {
  /**
   * Deploys the venue fixtures, and the engine when the profile binds an existing one. Other
   * fixtures its `validate` or consumers need are returned by name in `engineFixtures`.
   */
  provision(context: ProvisionContext): Promise<LocalVenue>
  /** Checks the provisioned fixtures' bindings beyond what the shared stack inspection reads. */
  validate?(client: ReadClient, venue: LocalVenue & { baseAsset: Address }): Promise<void>
  /** The profile engine that targets the provisioned venue or engine. */
  profileEngine(target: Address): EarnDeploymentProfile['engine']
  /** EarnShare and venue token metadata of the local stack. */
  metadata: { earnShare: TokenMetadata; venue: TokenMetadata }
  /**
   * How `provision` supports a persistent hosted test chain, checked before anything is signed, or
   * `false` when it is local only. `overPathUsd` provisions over canonical PATHUSD instead of the
   * disposable stablecoin pair, and `engineConstructorArgs` reads back the constructor arguments of
   * a provisioned engine for its source verification.
   */
  hostedFixture:
    | false
    | {
        overPathUsd: boolean
        engineConstructorArgs?(client: ReadClient, engine: Address): Promise<Hex>
      }
}

export type ProvisionContext = {
  baseAsset: Address
  /** The stablecoin funder; absent when the fixtures use an existing base asset. */
  funder?: Address | undefined
  /** A test fixture on a persistent hosted chain rather than the disposable local one. */
  persistent: boolean
  deploy(step: Foundry.Step): Promise<Foundry.Deployment>
  /**
   * Deploys as the engine's setup owner, a funded local account separate from the deployer, so the
   * lifecycle stops at the `bind-core` handoff that localnet then satisfies as that owner. Only a
   * disposable chain has one.
   */
  deployAsEngineOwner(step: Foundry.Step): Promise<Foundry.Deployment>
  run(step: Foundry.Step): Promise<Foundry.Receipt>
  /** The pool inventory of each token, which `fundInventory` mints. */
  inventory: bigint
  /** Mints the shared pool inventory of `token` to `receiver`. */
  fundInventory(token: Address, receiver: Address, label: string): Promise<void>
}

export type LocalVenue = Pick<Fixtures, 'vault' | 'engine' | 'engineFixtures'>

export function expectAddress(actual: Address, expected: Address, label: string) {
  if (!isAddressEqual(actual, expected)) {
    throw new Error(`${label} is ${actual}, expected ${expected}`)
  }
}
