import type { Address, Hex, PublicClient } from 'viem'

type ReadClient = Pick<PublicClient, 'readContract'>

/** One engine-specific contract a stack records beside its engine and venue. */
export type PeripheryContract = {
  /** Key in `DeploymentContracts.periphery`. */
  name: string
  /** Display name, prefixed with the engine label in UI copy. */
  label: string
  /** The contract may be absent from a stack, e.g. an inactive Veda Queue. */
  optional?: true
}

/** The stack contracts an engine reads to quote. */
export type EngineStack = { asset: Address; engine: Address; venue: Address }

/** Live deposit readiness an engine reports beyond its immutable bindings; never a guarantee. */
export type EngineReadiness = {
  scope: 'deposit'
  status: 'ready' | 'blocked'
  blockers: string[]
  warnings: string[]
}

/**
 * Everything tooling, localnet, E2E, and the app know about one engine kind, so they look it up
 * instead of branching on the kind. Each kind is one `defineEngine` module in this directory,
 * registered once in `index.ts`. Reads use only `viem` and generated ABIs, so the browser entry can
 * import every engine.
 */
export type Engine = {
  /** Short product name, e.g. in UI copy. */
  label: string
  /** The Earn engine contract. */
  engineContract: string
  /** Solidity source of `engineContract`, for source verification. */
  engineSource: string
  /** The venue the engine holds shares of. */
  venueLabel: string
  /** One-line description of the venue, e.g. in the app topology. */
  venueDetail: string
  /**
   * Engine-specific contracts a stack records in `contracts.periphery`, in display order. Catalog
   * parsing accepts exactly these names; the engine's own module reads them through a typed view.
   */
  periphery: readonly PeripheryContract[]
  /** Contract that solves queued exits, when the engine queues them. */
  exitSolver?: string | undefined
  /** Actions a stack over this engine advertises beyond deposit, which every stack offers. */
  capabilities: {
    /** Existing venue shares can enter Earn without redeeming to the asset. */
    inKindDeposit: boolean
    /** EarnShare redeems for the asset immediately. */
    redeem: boolean
    /** Immediate redemption with a minimum-assets bound. */
    boundedRedeem: boolean
    /** Immediate withdrawal of an exact asset amount. */
    exactWithdraw: boolean
    /** Exits may queue and settle later through the venue's withdrawal queue. */
    asyncRedeem: boolean
  }
  /**
   * Present when the lifecycle can provision the engine from a venue through a shared factory; a
   * profile can then name `engine.venue` instead of a reviewed, deployed `engine.address`.
   */
  factory?: EngineFactory | undefined
  /** The venue a deployed engine holds shares of, read from the engine itself. */
  readVenue(client: ReadClient, engine: Address): Promise<Address>
  /** The `contracts.periphery` a deployed engine reports, when the kind declares periphery. */
  readPeriphery?(client: ReadClient, engine: Address): Promise<Record<string, Address>>
  /**
   * Binding inspection beyond the shared stack checks; mismatches throw. `ready` also requires live
   * deposit readiness, while `bindings` reports it when the engine has one.
   */
  inspectBindings?(
    client: Pick<PublicClient, 'getCode' | 'readContract'>,
    engine: Address,
    mode: 'ready' | 'bindings',
  ): Promise<EngineReadiness | undefined>
  /** Engine shares a deposit of `assets` mints at the current state; EarnVault converts them. */
  quoteDeposit(client: ReadClient, stack: EngineStack, assets: bigint): Promise<bigint>
}

/** The shared factory that provisions one engine kind from a venue. */
export type EngineFactory = {
  /** The factory contract. */
  contract: string
  /** Solidity source of `contract`. */
  source: string
  /**
   * The factory's key in a shared release, `profile.factories`, and committed records. It also names
   * the release entry point and the pending runtime hash (`<releaseKey>Factory`).
   */
  releaseKey: string
  /** `path:Contract` of the Foundry script the `deploy-engine` step runs. */
  deployScript: string
  /** Calldata for `deployScript`'s typed `run(Input)`. */
  deployInput(input: EngineDeployInput): Hex
  /** Calldata for `deployScript`'s release entry point `<releaseKey>Factory(uint256 expectedChainId)`. */
  releaseInput(expectedChainId: bigint): Hex
  /** The engine the factory deploys for this input, whether or not it exists yet. */
  predictEngine(
    client: ReadClient,
    factory: Address,
    input: Pick<EngineDeployInput, 'deploymentId' | 'venue' | 'owner'>,
  ): Promise<Address>
  /** ABI-encoded constructor arguments of a factory-deployed engine, for source verification. */
  engineConstructorArgs(input: Pick<EngineDeployInput, 'venue' | 'owner'>): Hex
  /** The asset a venue accepts, which the provisioned engine adopts. */
  venueAsset(client: ReadClient, venue: Address): Promise<Address>
}

export type EngineDeployInput = {
  expectedChainId: bigint
  deploymentId: Hex
  factory: Address
  venue: Address
  /** Holds the unbound engine until binding transfers it to `finalOwner`. */
  owner: Address
  finalOwner: Address
  /** Pending-state path the script writes its outputs to. */
  outputPath: string
}

/** Declares an engine module, keeping its literal factory release key for the release types. */
export function defineEngine<const Definition extends Engine>(engine: Definition) {
  return engine
}

/** The `<releaseKey>Factory` entry point name, also the factory's key in serialized release hashes. */
export function factoryReleaseEntryPoint<const Key extends string>(factory: { releaseKey: Key }) {
  return `${factory.releaseKey}Factory` as const
}

/**
 * The step that deploys a factory's shared release: its `deployScript`'s `<releaseKey>Factory`
 * entry point, one CREATE of the ownerless factory.
 */
export function factoryReleaseStep(factory: EngineFactory, expectedChainId: bigint) {
  return {
    name: `${factory.deployScript.split(':')[1]}.${factoryReleaseEntryPoint(factory)}`,
    target: factory.deployScript,
    calldata: factory.releaseInput(expectedChainId),
  }
}
