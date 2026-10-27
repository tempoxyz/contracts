import type { Abi, Address, createPublicClient, Hex, PublicClient } from 'viem'

import type { DeploymentAddressKey, IntentComponent } from '../core/components.js'
import type { CoreProfile, EarnDeploymentProfile } from '../core/profile.js'
import type {
  DeploymentAccess,
  DeploymentContracts,
  DeploymentNetwork,
  DeploymentOperations,
  EarnStack,
} from '../core/stack.js'
import type { profileStack } from '../core/profile-stack.js'
import type { AuthorityDependencies, AuthorityOptions } from '../../deployments/modules/signer.js'
import type { LatestBlockClient } from '../chain/inspect.js'

/** The core profile fields plus one slice's own fields: everything a slice reads. */
export type SliceProfile<Fields extends object> = CoreProfile & Fields

/** Each recorded address a slice declares, mapped to the intent component that owns it. */
type AddressComponents = Readonly<Record<string, string>>

/** Parses one optional field of a published stack; absent fields are never parsed. */
type StackFieldParser = (value: unknown, path: string) => unknown

/**
 * One capability's browser-safe declarations, registered in `modules/slices.ts`: its part of the
 * authored profile and intent hashes, its recorded addresses and record target, the capabilities
 * it advertises, and its fields of a published stack. Core composes every registered slice in
 * registry order and never names one; a slice never imports the envelope at runtime.
 */
export type ProfileSlice<Fields extends object = object> = {
  /** Authored root keys the slice parses; each may be omitted from `profile.json`. */
  readonly authoredKeys: readonly string[]
  parse(root: Record<string, unknown>, chainId: number): Fields
  /** Reconstructs the slice's authored JSON. */
  authored(profile: SliceProfile<Fields>): Record<string, unknown>
  /** Fields the slice adds to the whole-profile deployment intent hash. */
  deploymentIntent(profile: SliceProfile<Fields>, deployment: string): Record<string, unknown>
  /** Fields the slice adds to the `core` component because core deployment consumes them. */
  coreIntent?(profile: SliceProfile<Fields>): Record<string, unknown>
  /** The `EarnFactory.DeployParams` inputs the slice decides; see `earnFactoryDeployParams`. */
  coreDeployParams?(profile: SliceProfile<Fields>): CoreDeployParams
  /**
   * Intent components the slice owns, in record order, each with its hashed preimage, or `null`
   * when the profile does not configure it.
   */
  readonly components?: Readonly<
    Record<string, (profile: SliceProfile<Fields>, deployment: string) => unknown>
  >
  /** Recorded addresses the slice discovers rather than deploys; recorded before core's. */
  readonly externalAddresses?: AddressComponents
  /** Recorded addresses the slice deploys and places in its own stack fields. */
  readonly addresses?: AddressComponents
  /** Recorded addresses the slice deploys that travel as `OptionalPeriphery`. */
  readonly periphery?: AddressComponents
  /** Whether a recorded address is a protocol precompile, authenticated without runtime bytecode. */
  codeless?(key: string, address: Address): boolean
  /** The slice's key of the deployment record's target identity. */
  readonly target?: TargetSlice<string, unknown, Fields>
  /** Capabilities the slice advertises, in record order, and whether a profile enables each. */
  readonly capabilities?: Readonly<Record<string, (profile: SliceProfile<Fields>) => boolean>>
  /** The slice's optional fields of a published stack, in serialized order, and their rules. */
  readonly stack?: {
    readonly network?: Readonly<Record<string, StackFieldParser>>
    readonly contracts?: Readonly<Record<string, StackFieldParser>>
    readonly modes?: Readonly<Record<string, StackFieldParser>>
    /** Cross-field rules over a parsed stack and its network; `fail` throws. */
    validate?(
      stack: {
        capabilities: Readonly<Record<string, boolean>>
        contracts: Readonly<Record<string, unknown>>
        modes: Readonly<Record<string, unknown>>
      },
      network: Readonly<Record<string, unknown>>,
      fail: (reason: string) => never,
    ): void
  }
  /** Cross-field validation over the parsed profile. */
  validate?(profile: SliceProfile<Fields>): void
  /** Privileged roles the slice's fields assign, each with its label, when the profile configures it. */
  privilegedPrincipals?(profile: SliceProfile<Fields>): readonly PrivilegedPrincipal[]
}

/** One privileged role and the address a profile assigns it. */
export type PrivilegedPrincipal = readonly [role: string, address: Address]

/** `EarnFactory.DeployParams` inputs a slice may set; core defaults each to zero. */
export type CoreDeployParams = { transferPolicyId?: bigint }

/** One optional key of the deployment target, owned by the slice whose component it follows. */
export type TargetSlice<Key extends string, Value, Fields extends object> = {
  key: Key
  component: string
  /** Builds the value from discovered outputs; `undefined` when the profile does not configure it. */
  discover(profile: SliceProfile<Fields>, outputs: Record<string, Address>): Value | undefined
  /**
   * Parses a recorded value, which with `profile` must be exactly what the profile expects; without
   * it, as for a record whose component is being reconciled, only its shape is checked.
   */
  parse(value: unknown, path: string, profile?: SliceProfile<Fields>): Value | undefined
  same(left: Value | undefined, right: Value | undefined): boolean
  /** Rejects recorded addresses that disagree with the recorded target. */
  checkAddresses?(
    addresses: Readonly<Partial<Record<string, Address>>>,
    value: Value | undefined,
    path: string,
  ): void
}

/**
 * The Node lifecycle hooks of one capability, registered in `modules/index.ts`. The core lifecycle
 * runs each hook for every registered module in registry order; a capability's steps are
 * registered there separately because their execution order interleaves capabilities.
 */
export type CapabilityModule = {
  /** Read-only checks before any key is consumed. */
  preflight?(client: PublicClient, profile: EarnDeploymentProfile): Promise<void>
  /** Live external addresses the capability uses but does not deploy, merged into outputs. */
  discover?(options: DiscoveryOptions): Promise<Record<string, Address> | undefined>
  /**
   * The external chain `discover` verifies under `requireLive`. `pnpm earn verify --skip-<flag>`
   * discovers it without that check, verifies everything else, and reports `<label>: not verified`.
   */
  liveCheck?: {
    flag: string
    label: string
    /** Whether the profile configures the chain, so the flag applies. */
    applies(profile: EarnDeploymentProfile): boolean
  }
  /** Resume-cache output keys that are discovery metadata rather than recorded addresses. */
  metadataOutput?(key: string): boolean
  /**
   * Principals a protected EarnShare must whitelist beyond step-created access members, such as a
   * Zone's Portal and sequencers.
   */
  accessPrincipals?(profile: EarnDeploymentProfile, outputs: Record<string, Address>): Address[]
  /** The same principals of a deployed stack, read live. */
  stackAccessPrincipals?(
    client: Pick<PublicClient, 'readContract'>,
    stack: EarnStack,
  ): Promise<Address[]>
  /** Post-deployment inspection beyond the core stack; binding mismatches throw. */
  inspect?(
    client: Pick<PublicClient, 'getCode' | 'readContract'> & LatestBlockClient,
    profile: EarnDeploymentProfile,
    outputs: Record<string, Address>,
  ): Promise<InspectionReport | undefined>
  /** The capability's fields of a deployed profile's `EarnStack`, from its record and live reads. */
  stack?(options: profileStack.Options): Promise<StackSlice>
}

/**
 * A `pnpm earn <name>` subcommand a capability operates, registered in `modules/commands.ts` so
 * Node-only command code stays off the module registry the operations entry loads.
 */
export type CapabilityCommand = {
  name: string
  usage: string
  run(argv: readonly string[], output: Pick<Console, 'log' | 'warn'>): Promise<void>
}

export type DiscoveryOptions = {
  environment: NodeJS.ProcessEnv
  profile: EarnDeploymentProfile
  rpcUrl: string
  /** Whether discovery must also reach and verify live external chains. */
  requireLive: boolean
}

/** Mutable readiness one capability reports; JSON-safe, and never an inspection failure. */
export type CapabilityReadiness = {
  /** What is ready or blocked, such as `Router conversion`. */
  label: string
  status: 'ready' | 'blocked'
  blockers: string[]
  /** Further facts, in print order; `null` is unknown. */
  details?: Readonly<Record<string, string | null>>
}

/** Live readiness reported by inspection, keyed by a name each reporting capability chooses. */
export type InspectionReport = Readonly<Record<string, CapabilityReadiness>>

export type StackSlice = {
  network?: Partial<DeploymentNetwork>
  contracts?: Partial<DeploymentContracts>
  modes?: Partial<EarnStack['modes']>
  access?: DeploymentAccess
  operations?: Partial<DeploymentOperations>
}

export type ChainClient = ReturnType<typeof createPublicClient>

/** Who executes a step, and the environment variable that holds that signer's key. */
export type StepAuthority = {
  id: string
  /** Who must act when the step is handed off. */
  label: string
  signer: string
}

/** The deployer, which runs every Foundry step. */
export const deployerAuthority = {
  id: 'deployer',
  label: 'deployer',
  signer: 'DEPLOYER_PRIVATE_KEY',
} as const satisfies StepAuthority

type BaseStep<Id extends string, Authority extends StepAuthority> = {
  id: Id
  authority: Authority
  summary: string
  /**
   * `deployment` steps produce the immutable record; `activation` steps reconcile mutable external
   * readiness against an already published record.
   */
  phase: 'deployment' | 'activation'
  /** Intent this step's result depends on; a change to any of them invalidates the step. */
  intent: readonly IntentComponent[]
  enabled(profile: EarnDeploymentProfile): boolean
  /** Whether the step's exact desired state is already present onchain. */
  satisfied(
    client: ChainClient,
    profile: EarnDeploymentProfile,
    outputs: Record<string, Address>,
  ): Promise<boolean>
}

/** A step a Foundry script executes with the deployer key. */
export type FoundryStep<Id extends string = string> = BaseStep<Id, typeof deployerAuthority> & {
  execution: 'foundry'
  /**
   * The Foundry project beside `earn/` that compiles and runs the script and the contract it
   * creates, such as `router`, which builds with solc; Earn's own project when omitted.
   */
  project?: string
  /** `path:Contract` of the script, or the profile's script when it depends on the profile. */
  script: string | ((profile: EarnDeploymentProfile) => string)
  /** Calldata for the script's typed `run(Input)`; Forge receives it with `--sig`. */
  input(profile: EarnDeploymentProfile, outputs: Record<string, Address>, outputPath: string): Hex
  /**
   * Set for a large CREATE, whose transaction needs Forge's raw gas estimate: a 200% multiplier can
   * exceed Tempo's 30M transaction cap even when the deployment itself fits comfortably. Only
   * localnet's batched Forge call applies it; `pnpm earn deploy` runs Forge's default estimate.
   */
  rawGasEstimate?: true
  /**
   * The contract this step creates, recorded under `output` and source-verified against the step's
   * creation transaction. Core and engine outputs (proxies, protocol-native, or factory-made) are
   * classified by source verification itself.
   */
  source?: {
    output: DeploymentAddressKey
    /** `path:Name` of the Solidity contract. */
    contract: string
    constructorArgs(profile: EarnDeploymentProfile, outputs: Record<string, Address>): Hex
    /** Set when the contract moves EarnShare or the asset, so a protected EarnShare must whitelist it. */
    accessMember?: AccessMember
  }
}

/**
 * A step-created access member. When it moves EarnShare or the asset to or from other accounts,
 * `principals` must be whitelisted too: each is named by its zero-argument address getter on `abi`,
 * read onchain from a deployed stack, and resolved from the profile when planning.
 */
export type AccessMember =
  | true
  | {
      abi: Abi
      principals: Readonly<Record<string, (profile: EarnDeploymentProfile) => Address>>
    }

/** A step an external authority completes, executed here only when its signer is available. */
export type AuthorityStep<
  Id extends string = string,
  Authority extends StepAuthority = StepAuthority,
> = BaseStep<Id, Authority> & {
  execution: 'authority'
  handoffSummary: string
  handoff(profile: EarnDeploymentProfile, outputs: Record<string, Address>): string
  /**
   * Whether the configured signer can execute the step; by default, whether the authority's signer
   * key is set. `proven` is the result of `probeSigner`, when the step has one and planning ran it.
   */
  signerAvailable?(
    profile: EarnDeploymentProfile,
    environment: Readonly<Record<string, string | undefined>>,
    proven: boolean,
  ): boolean
  /** Proves with read-only calls that the configured signer holds this step's authority. */
  probeSigner?(options: {
    environment: NodeJS.ProcessEnv
    profile: EarnDeploymentProfile
    rpcUrl: string
  }): Promise<boolean>
  execute(
    options: AuthorityOptions,
    dependencies: AuthorityDependencies,
  ): Promise<{ transactions: Hex[] } | undefined>
}

export type DeploymentStep = FoundryStep | AuthorityStep

/** Declares a Foundry step, keeping its literal ID for the registry's action-ID type. */
export function defineFoundryStep<const Id extends string>(step: FoundryStep<Id>) {
  return step
}

/** The `path:Contract` a Foundry step runs for one profile. */
export function foundryScript(step: FoundryStep, profile: EarnDeploymentProfile) {
  return typeof step.script === 'string' ? step.script : step.script(profile)
}

/** Declares an authority step, keeping its literal ID and authority for the registry's types. */
export function defineAuthorityStep<const Id extends string, const Authority extends StepAuthority>(
  step: AuthorityStep<Id, Authority>,
) {
  return step
}

/** Whether the environment can execute an authority step itself rather than hand it off. */
export function stepSignerAvailable(
  step: AuthorityStep,
  profile: EarnDeploymentProfile,
  environment: Readonly<Record<string, string | undefined>>,
  proven: boolean,
) {
  return step.signerAvailable
    ? step.signerAvailable(profile, environment, proven)
    : Boolean(environment[step.authority.signer]?.trim())
}

export function requiredOutput(outputs: Record<string, Address>, key: string) {
  const value = outputs[key]
  if (!value) throw new Error(`deployment output ${key} is required`)
  return value
}

export function required<T>(value: T | undefined, label: string): T {
  if (value === undefined) throw new Error(`${label} is required`)
  return value
}

/** Whether every named output exists and has code. */
export async function deployedOutputs(
  client: ChainClient,
  outputs: Record<string, Address>,
  keys: readonly string[],
) {
  for (const key of keys) {
    const value = outputs[key]
    if (!value) return false
    const code = await client.getCode({ address: value })
    if (!code || code === '0x') return false
  }
  return true
}
