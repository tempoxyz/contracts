import {
  getAddress,
  keccak256,
  sha256,
  stringToBytes,
  zeroAddress,
  type Address,
  type Hex,
} from 'viem'

import { hostedEnvironments, isHostedDeploymentChain } from '../chain/tempo.js'
import {
  engineDefinitions,
  engineKinds,
  type EngineKind,
  type FactoryEngineKind,
} from '../modules/engines/index.js'
import type { CoreDeployParams, PrivilegedPrincipal } from '../modules/module.js'
import { slices, type SliceAuthoredFields, type SliceProfileFields } from '../modules/slices.js'
import type { PeripheryComponent } from './components.js'
import {
  address,
  array,
  bps,
  canonicalJson,
  decimalString,
  exactKeys,
  literal,
  nonemptyString,
  object,
  positiveInteger,
} from './parse.js'
import {
  engineFactoryAddress,
  unresolvedFactoryRelease,
  type EarnFactoryRelease,
} from './releases.js'
import { capabilityKeys, type DeploymentCapabilities } from './stack.js'

/**
 * The authored stack intent: the core fields parsed here plus every slice's fields, each owned and
 * hashed by its capability (`modules/slices.ts` registers them).
 */
export type EarnDeploymentProfile = CoreProfile & SliceProfileFields

/** The profile fields core parses and hashes itself; every slice may read them. */
export type CoreProfile = {
  /** Deterministic onchain deployment revision for this profile ID. */
  version: number
  id: string
  chainId: number
  deployer: Address
  owner: Address
  /** Runtime-resolved shared release; omitted from authored JSON and persisted in deployment state. */
  factories: EarnFactoryRelease
  /** Internal parse provenance; omitted from authored and generated JSON. */
  ownerExplicit?: boolean
  /** A reviewed, deployed engine, or a venue the engine's shared factory provisions an engine for. */
  engine: { kind: EngineKind; address: Address } | { kind: FactoryEngineKind; venue: Address }
  core: {
    migrationMode: 'UserOnly' | 'OperatorEnabled'
    emergencyGuardian: Address | null
    asyncJanitor: Address | null
    fees: {
      fixed: Array<{ recipient: Address; rateBps: number }>
      protectedFixed?: {
        recipient: Address
        rateBps: number
        distributor: Address
        updateDelaySeconds: string
      }
      excess?: { recipient: Address; annualTargetRateBps: number; rateBps: number }
    }
  }
}

/** Profile fields the core intent hashes cover directly. */
type CoreProfileField =
  | 'version'
  | 'id'
  | 'chainId'
  | 'deployer'
  | 'owner'
  | 'factories'
  | 'engine'
  | 'core'

/** Compiles only when `Fields` has exactly the `Expected` keys. */
function intentFields<Fields, Expected extends PropertyKey>(
  _exact: [Exclude<keyof Fields, Expected>, Exclude<Expected, keyof Fields>] extends [never, never]
    ? true
    : never,
) {}

// A new core field must be hashed by core, or it silently escapes the hashes; slices hash their own.
intentFields<Omit<CoreProfile, 'ownerExplicit'>, CoreProfileField>(true)

/** Parses the only authored deployment input. RPCs, keys, receipts, and derived addresses stay out. */
export function parseEarnDeploymentProfile(
  value: unknown,
  options: {
    allowEphemeralChain?: boolean
    deployer?: Address
    factories?: EarnFactoryRelease
  } = {},
): EarnDeploymentProfile {
  const root = object(value, 'profile.json')
  exactKeys(
    root,
    'profile.json',
    ['version', 'id', 'chainId', 'engine'],
    ['owner', 'core', ...slices.flatMap((slice) => slice.authoredKeys)],
  )
  const chainId = positiveInteger(root.chainId, 'profile.json.chainId')
  if (!isHostedDeploymentChain(chainId) && options.allowEphemeralChain !== true) {
    const hosted = Object.values(hostedEnvironments)
      .map((environment) => `${environment.id} ${environment.chainId}`)
      .join(' or ')
    throw new Error(`profile.json.chainId must be a hosted Tempo chain: ${hosted}`)
  }
  const engine = parseEngine(object(root.engine, 'profile.json.engine'))
  const coreValue = root.core === undefined ? {} : object(root.core, 'profile.json.core')
  if (root.core !== undefined && Object.keys(coreValue).length === 0) {
    throw new Error('profile.json.core must be omitted when it has no configuration')
  }
  const factories = options.factories ?? unresolvedFactoryRelease()
  const deployer = options.deployer ?? zeroAddress
  const ownerExplicit = root.owner !== undefined
  const profile: EarnDeploymentProfile = {
    version: positiveInteger(root.version, 'profile.json.version'),
    id: slug(root.id, 'profile.json.id'),
    chainId,
    deployer,
    owner: ownerExplicit ? address(root.owner, 'profile.json.owner') : deployer,
    factories,
    ownerExplicit,
    engine,
    core: parseCore(coreValue),
    ...(Object.assign(
      {},
      ...slices.map((slice) => slice.parse(root, chainId)),
    ) as SliceProfileFields),
  }
  validateFees(profile)
  for (const slice of slices) slice.validate?.(profile)
  return profile
}

function hash(value: unknown) {
  return sha256(stringToBytes(canonicalJson(value))).slice(2)
}

/** Merges each slice's contribution, in slice order. */
function sliceFields(contribution: (slice: (typeof slices)[number]) => object | undefined) {
  return Object.assign({}, ...slices.map(contribution)) as Record<string, unknown>
}

/** Hashes normalized onchain deployment intent; offchain economics are excluded. */
export function deploymentIntentHash(profile: EarnDeploymentProfile) {
  const deployment = profileDeploymentSalt(profile)
  return hash({
    version: profile.version,
    id: profile.id,
    chainId: profile.chainId,
    deployer: profile.deployer,
    owner: profile.owner,
    factories: profile.factories,
    engine: profile.engine,
    core: profile.core,
    ...sliceFields((slice) => slice.deploymentIntent(profile, deployment)),
  })
}

export type ComponentIntentHashes = { core: string; engine: string } & Record<
  PeripheryComponent,
  string | null
>

/** Hashes each intent component independently so a periphery change never touches core custody. */
export function componentDeploymentIntentHashes(
  profile: EarnDeploymentProfile,
): ComponentIntentHashes {
  const deployment = profileDeploymentSalt(profile)
  const periphery = Object.fromEntries(
    slices.flatMap((slice) =>
      Object.entries(slice.components ?? {}).map(([component, preimage]) => {
        const value = preimage(profile, deployment)
        return [component, value === null ? null : hash(value)]
      }),
    ),
  ) as Record<PeripheryComponent, string | null>
  return {
    core: hash({
      version: profile.version,
      id: profile.id,
      chainId: profile.chainId,
      deployer: profile.deployer,
      owner: profile.owner,
      core: profile.core,
      factory: profile.factories.earn,
      ...sliceFields((slice) => slice.coreIntent?.(profile)),
    }),
    engine: hash({
      deployment,
      engine: profile.engine,
      ...(deploysEngine(profile) ? { factory: profileEngineFactory(profile).address } : {}),
    }),
    ...periphery,
  }
}

/** Reconstructs the semantic authored JSON without runtime-derived deployment identity. */
export function authoredProfile(profile: EarnDeploymentProfile) {
  const fees = profile.core.fees
  const hasFees =
    fees.fixed.length > 0 || fees.protectedFixed !== undefined || fees.excess !== undefined
  const authoredFees = {
    ...(fees.fixed.length > 0 ? { fixed: fees.fixed } : {}),
    ...(fees.protectedFixed ? { protectedFixed: fees.protectedFixed } : {}),
    ...(fees.excess ? { excess: fees.excess } : {}),
  }
  const core = {
    ...(profile.core.migrationMode === 'OperatorEnabled'
      ? { migrationMode: 'OperatorEnabled' as const }
      : {}),
    ...(profile.core.emergencyGuardian
      ? { emergencyGuardian: profile.core.emergencyGuardian }
      : {}),
    ...(profile.core.asyncJanitor ? { asyncJanitor: profile.core.asyncJanitor } : {}),
    ...(hasFees ? { fees: authoredFees } : {}),
  }
  return {
    version: profile.version,
    id: profile.id,
    chainId: profile.chainId,
    ...(profile.ownerExplicit ? { owner: profile.owner } : {}),
    engine: profile.engine,
    ...(Object.keys(core).length > 0 ? { core } : {}),
    ...(sliceFields((slice) => slice.authored(profile)) as SliceAuthoredFields),
  }
}

/** Human-readable preimage used for every deterministic factory deployment ID. */
export function profileDeploymentSalt(profile: Pick<EarnDeploymentProfile, 'id' | 'version'>) {
  return `${profile.id}:v${profile.version}`
}

export function profileFactoryDeploymentId(profile: Pick<EarnDeploymentProfile, 'id' | 'version'>) {
  return keccak256(stringToBytes(profileDeploymentSalt(profile)))
}

/**
 * The exact `EarnFactory.DeployParams` a profile's core is deployed with; the core step passes it to
 * the factory and inspection uses it to predict the deployed addresses.
 */
export function earnFactoryDeployParams(
  profile: EarnDeploymentProfile,
  engine: Address,
  deploymentId: Hex = profileFactoryDeploymentId(profile),
) {
  const protectedFee = profile.core.fees.protectedFixed
  const fixed = [
    ...(protectedFee && protectedFee.rateBps !== 0
      ? [{ account: protectedFee.recipient, rateBps: protectedFee.rateBps }]
      : []),
    ...profile.core.fees.fixed.map((fee) => ({ account: fee.recipient, rateBps: fee.rateBps })),
  ]
  const feeAt = (index: number) => fixed[index] ?? { account: zeroAddress, rateBps: 0 }
  const excess = profile.core.fees.excess
  const sliceDeployParams: CoreDeployParams = Object.assign(
    {},
    ...slices.map((slice) => slice.coreDeployParams?.(profile)),
  )
  return {
    deploymentId,
    engine,
    owner: profile.owner,
    controls: {
      emergencyGuardian: profile.core.emergencyGuardian ?? zeroAddress,
      asyncJanitor: profile.core.asyncJanitor ?? zeroAddress,
      maxManagedAssets: 0n,
      migrationMode: profile.core.migrationMode === 'OperatorEnabled' ? 1 : 0,
    },
    distributorConfig: {
      distributor: protectedFee?.distributor ?? zeroAddress,
      updateDelay: Number(protectedFee?.updateDelaySeconds ?? '0'),
    },
    fees: {
      fixedFeeCount: fixed.length,
      fixedFees: [feeAt(0), feeAt(1), feeAt(2), feeAt(3)],
      excess: {
        enabled: excess !== undefined,
        account: excess?.recipient ?? zeroAddress,
        annualTargetRateBps: excess?.annualTargetRateBps ?? 0,
        excessFeeRateBps: excess?.rateBps ?? 0,
      },
    },
    // A slice binds an EarnFactory input core does not own, such as the EarnShare transfer policy.
    transferPolicyId: sliceDeployParams.transferPolicyId ?? 0n,
  } as const
}

function parseEngine(value: Record<string, unknown>): EarnDeploymentProfile['engine'] {
  const kind = literal(value.kind, 'profile.json.engine.kind', engineKinds)
  // Only an engine with a shared factory can be provisioned from a venue.
  if (value.address !== undefined || !engineDefinitions[kind].factory) {
    exactKeys(value, 'profile.json.engine', ['kind', 'address'])
    return { kind, address: address(value.address, 'profile.json.engine.address') }
  }
  exactKeys(value, 'profile.json.engine', ['kind', 'venue'])
  return {
    kind: kind as FactoryEngineKind,
    venue: address(value.venue, 'profile.json.engine.venue'),
  }
}

export function deploysEngine(profile: EarnDeploymentProfile): profile is EarnDeploymentProfile & {
  engine: Extract<EarnDeploymentProfile['engine'], { venue: Address }>
} {
  return 'venue' in profile.engine
}

/** The shared factory, and its address in the profile's release, that provisions the engine. */
export function profileEngineFactory(
  profile: EarnDeploymentProfile & {
    engine: Extract<EarnDeploymentProfile['engine'], { venue: Address }>
  },
) {
  const factory = engineDefinitions[profile.engine.kind].factory
  if (!factory) throw new Error(`${profile.engine.kind} engines are not factory-provisioned`)
  return { ...factory, address: engineFactoryAddress(profile.factories, factory) }
}

export function configuredEngineAddress(profile: EarnDeploymentProfile) {
  return 'address' in profile.engine ? profile.engine.address : undefined
}

/** The profile's existing engine, or the one its engine step deployed. */
export function engineAddress(profile: EarnDeploymentProfile, outputs: Record<string, Address>) {
  const engine = configuredEngineAddress(profile) ?? outputs.engine
  if (!engine) throw new Error('deployment output engine is required')
  return engine
}

/** Every privileged role the profile assigns: core's, then each registered slice's. */
export function privilegedPrincipals(profile: EarnDeploymentProfile): PrivilegedPrincipal[] {
  const { core } = profile
  const assigned: [string, Address | null | undefined][] = [
    ['owner', profile.owner],
    ['emergency guardian', core.emergencyGuardian],
    ['async janitor', core.asyncJanitor],
    ...core.fees.fixed.map(({ recipient }, index): [string, Address] => [
      `fixed fee recipient ${index}`,
      recipient,
    ]),
    ['protected fee recipient', core.fees.protectedFixed?.recipient],
    ['fee distributor', core.fees.protectedFixed?.distributor],
    ['excess fee recipient', core.fees.excess?.recipient],
  ]
  return [
    ...assigned.flatMap(([role, address]) => (address ? [[role, address] as const] : [])),
    ...slices.flatMap((slice) => slice.privilegedPrincipals?.(profile) ?? []),
  ]
}

/** Capabilities a stack deployed from the profile advertises, in `capabilityKeys` order. */
export function profileCapabilities(profile: EarnDeploymentProfile): DeploymentCapabilities {
  const advertised: Partial<DeploymentCapabilities> = {
    deposit: true,
    ...engineDefinitions[profile.engine.kind].capabilities,
    ...Object.fromEntries(
      slices.flatMap((slice) =>
        Object.entries(slice.capabilities ?? {}).map(([key, enabled]) => [key, enabled(profile)]),
      ),
    ),
  }
  return Object.fromEntries(
    capabilityKeys.map((key) => [key, advertised[key] ?? false]),
  ) as DeploymentCapabilities
}

function parseCore(value: Record<string, unknown>): EarnDeploymentProfile['core'] {
  exactKeys(
    value,
    'profile.json.core',
    [],
    ['migrationMode', 'emergencyGuardian', 'asyncJanitor', 'fees'],
  )
  if (value.migrationMode === 'UserOnly') {
    throw new Error('profile.json.core.migrationMode UserOnly is the default and must be omitted')
  }
  return {
    migrationMode:
      value.migrationMode === undefined
        ? 'UserOnly'
        : literal(value.migrationMode, 'profile.json.core.migrationMode', [
            'OperatorEnabled',
          ] as const),
    emergencyGuardian:
      value.emergencyGuardian === undefined
        ? null
        : address(value.emergencyGuardian, 'profile.json.core.emergencyGuardian'),
    asyncJanitor:
      value.asyncJanitor === undefined
        ? null
        : address(value.asyncJanitor, 'profile.json.core.asyncJanitor'),
    fees: value.fees === undefined ? { fixed: [] } : parseFees(value.fees),
  }
}

function parseFees(source: unknown): EarnDeploymentProfile['core']['fees'] {
  const value = object(source, 'profile.json.core.fees')
  exactKeys(value, 'profile.json.core.fees', [], ['fixed', 'protectedFixed', 'excess'])
  const fixed = (
    value.fixed === undefined ? [] : array(value.fixed, 'profile.json.core.fees.fixed')
  ).map((entry, index) =>
    parseFixedFee(
      object(entry, `profile.json.core.fees.fixed[${index}]`),
      `profile.json.core.fees.fixed[${index}]`,
    ),
  )
  const protectedFixed =
    value.protectedFixed === undefined
      ? undefined
      : parseProtectedFixed(object(value.protectedFixed, 'profile.json.core.fees.protectedFixed'))
  if (fixed.length + (protectedFixed ? 1 : 0) > 4)
    throw new Error('profile.json.core.fees supports at most four fixed recipients in total')
  const excess =
    value.excess === undefined
      ? undefined
      : parseExcess(object(value.excess, 'profile.json.core.fees.excess'))
  if (fixed.length === 0 && !protectedFixed && !excess) {
    throw new Error('profile.json.core.fees must be omitted when no fees are configured')
  }
  return { fixed, ...(protectedFixed ? { protectedFixed } : {}), ...(excess ? { excess } : {}) }
}

function parseFixedFee(value: Record<string, unknown>, path: string) {
  exactKeys(value, path, ['recipient', 'rateBps'])
  return {
    recipient: address(value.recipient, `${path}.recipient`),
    rateBps: bps(value.rateBps, `${path}.rateBps`),
  }
}

function parseProtectedFixed(value: Record<string, unknown>) {
  exactKeys(value, 'profile.json.core.fees.protectedFixed', [
    'recipient',
    'rateBps',
    'distributor',
    'updateDelaySeconds',
  ])
  const rateBps = bps(value.rateBps, 'profile.json.core.fees.protectedFixed.rateBps')
  const recipient =
    rateBps === 0 && value.recipient === zeroAddress
      ? zeroAddress
      : address(value.recipient, 'profile.json.core.fees.protectedFixed.recipient')
  if (rateBps === 0 && recipient !== zeroAddress)
    throw new Error('profile.json.core.fees.protectedFixed zero rate requires a zero recipient')
  const fee = { recipient, rateBps }
  const updateDelaySeconds = uint40(
    value.updateDelaySeconds,
    'profile.json.core.fees.protectedFixed.updateDelaySeconds',
  )
  if (updateDelaySeconds === '0')
    throw new Error('profile.json.core.fees.protectedFixed.updateDelaySeconds must be nonzero')
  return {
    ...fee,
    distributor: address(value.distributor, 'profile.json.core.fees.protectedFixed.distributor'),
    updateDelaySeconds,
  }
}

function parseExcess(value: Record<string, unknown>) {
  exactKeys(value, 'profile.json.core.fees.excess', ['recipient', 'annualTargetRateBps', 'rateBps'])
  const rateBps = bps(value.rateBps, 'profile.json.core.fees.excess.rateBps')
  if (rateBps === 0) throw new Error('profile.json.core.fees.excess.rateBps must be nonzero')
  return {
    recipient: address(value.recipient, 'profile.json.core.fees.excess.recipient'),
    annualTargetRateBps: bps(
      value.annualTargetRateBps,
      'profile.json.core.fees.excess.annualTargetRateBps',
    ),
    rateBps,
  }
}

function validateFees(profile: EarnDeploymentProfile) {
  const protectedFee = profile.core.fees.protectedFixed
  if (protectedFee?.rateBps === 0 && profile.core.fees.fixed.length > 0)
    throw new Error(
      'profile.json.core.fees: configure operator fixed fees after deploying a zero-rate distributor',
    )
  const totalFixed =
    profile.core.fees.fixed.reduce((sum, fee) => sum + fee.rateBps, 0) +
    (protectedFee?.rateBps ?? 0)
  if (totalFixed > 10_000)
    throw new Error('profile.json.core.fees fixed rates may not exceed 10000 bps in total')
}

function slug(value: unknown, path: string) {
  const result = nonemptyString(value, path)
  if (!/^[a-z0-9][a-z0-9-]*$/.test(result)) throw new Error(`${path} must be a lowercase slug`)
  return result
}
function uint40(value: unknown, path: string) {
  const result = decimalString(value, path)
  if (BigInt(result) > 1_099_511_627_775n) throw new Error(`${path} must fit uint40`)
  return result
}
/**
 * Whether a bound engine's owner is the profile owner or its EarnVault's current operator. Deployment
 * leaves both roles with the profile owner, and a completed handoff moves both to the same account,
 * so the authored and recorded owner stays unchanged after customers accept. An engine owner that
 * matches neither, including an accepted engine without an accepted operator, still fails.
 */
export function engineOwnerAccepted(
  profile: EarnDeploymentProfile,
  owner: Address,
  vaultOperator: Address | undefined,
) {
  const current = getAddress(owner)
  if (current === profile.owner) return true
  return (
    vaultOperator !== undefined && current !== zeroAddress && current === getAddress(vaultOperator)
  )
}
