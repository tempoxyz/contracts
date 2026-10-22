import type { EngineKind } from '@tempoxyz/earn/deployments'
import type {
  DeploymentAccess,
  EarnDeploymentActionId,
  EarnDeploymentProfile,
  EngineFactory,
  OptionalPeriphery,
} from '@tempoxyz/earn/deployments/operations'
import type { Address, Hex } from 'viem'

import type { ConversionPool, Fixtures } from './fixtures.js'

export type { EngineKind }
export type AccessKind = DeploymentAccess['kind']

/** Also carries the optional periphery the profile's components deployed. */
export type State = OptionalPeriphery & {
  version: 1
  engineKind: EngineKind
  /** The localized profile the shared lifecycle deployed; its settings define this stack. */
  earnProfile: EarnDeploymentProfile
  chainId: number
  deployedAtBlock: bigint
  transactions: Hex[]
  zoneId: number
  zoneChainId: number
  zonePortal: Address
  zoneMessenger: Address
  zoneSequencer: Address
  tip20Factory: Address
  pathUsd: Address
  baseAsset: Address
  /**
   * `DemoStablecoinFunder`: sole issuer of `baseAsset` and `alternateAsset`. Its permissionless
   * `fund(token, receiver, amount)` mints either token; see `demoStablecoinFunderAbi` in `@tempoxyz/earn/abis`.
   */
  stablecoinFixture: Address
  /** The profile owner: EarnVault operator and final engine owner. */
  owner: Address
  revenueShareRecipient: Address
  alternateAsset: Address
  factory: Address
  vault: Address
  engine: Address
  earnShare: Address
  earnVault: Address
  earnFees: Address
  /** Present when the profile configures a Zone router. */
  earnRouter?: Address
  /** Disposable DirectPropAMM pool that converts `alternateAsset` and `baseAsset` at par. */
  earnRouterPool: RouterPool
  /** Engine-specific fixtures beside the venue and engine; see `LocalEngine.provision`. */
  engineFixtures: Readonly<Record<string, Address>>
  accessAdministrator: Address
  access: DeploymentAccess
  /** Present when the environment was started with `sameAssetRoute`. */
  sameAssetRoute?: SameAssetRoute
}

/**
 * A second Earn stack whose vault asset is PATHUSD, with a `SingleZoneEarnRouter` that deposits and
 * redeems PATHUSD directly: no pool, zero customer ID. It shares the environment's factory, access
 * policy, and Zone. Its EarnVault, EarnFees, and router are policy members, and its EarnShare is
 * enabled on the Portal and mirrored on the Zone before consumers run.
 */
export type SameAssetRoute = {
  /** PATHUSD: both the router's private asset and the EarnVault asset. */
  asset: Address
  /** Local Simple ERC-4626 venue over PATHUSD. */
  vault: Address
  engine: Address
  earnShare: Address
  earnVault: Address
  earnFees: Address
  earnRouter: Address
}

export type RouterPool = ConversionPool & {
  customerId: Hex
  /** Initial pool inventory of each pair token. */
  inventory: bigint
}

/** Local fixtures and the shared factory release; Earn stacks are deployed by `create`. */
export type Base = Omit<Fixtures, 'stablecoins' | 'routerPool'> & {
  engineKind: EngineKind
  stablecoins: NonNullable<Fixtures['stablecoins']>
  routerPool: ConversionPool
  /** Every engine kind's shared factory, in registry order. */
  engineFactories: readonly { factory: EngineFactory; address: Address }[]
  factory: Address
  /** PATHUSD venue for `State.sameAssetRoute`. */
  sameAssetVault?: Address | undefined
}

/** Lifecycle actions completed for one localized profile. */
export type ProfileDeployment = {
  profile: EarnDeploymentProfile
  outputs: Record<string, Address>
  actions: Partial<Record<EarnDeploymentActionId, { transactions: Hex[] }>>
}

export type Result = {
  profiles: ProfileDeployment[]
  /** Policy transactions on the local access policy. */
  accessTransactions: number
  state: State
}
