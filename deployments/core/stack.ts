import type { Address, Hex, PublicClient } from 'viem'

import { earnEngineBindingAbi, earnFeesAbi, earnVaultAbi } from '../abis/index.js'
import type { DeploymentAddressKey, OptionalPeriphery } from './components.js'
import {
  engineDefinitions,
  engineKinds,
  readEngineVenue,
  type Engine,
  type EngineKind,
  type PeripheryContract,
} from '../modules/engines/index.js'
import { parseFactoryRelease, type EarnFactoryRelease } from './releases.js'
import { equalAddress } from '../chain/inspect.js'
import { slices, type SliceCapabilityKey, type SliceStackFields } from '../modules/slices.js'
import {
  array,
  checksummedAddress,
  exactKeys,
  literal,
  nonemptyString,
  nonnegativeInteger,
  object,
  parseMode,
  tip403PolicyId,
  unique,
  url,
} from './parse.js'

export type ModeAvailability = 'available' | 'unverified' | 'blocked' | 'unavailable'

/** Whether a stack's mode may be used, and why not when it may not. */
export type ModeConfiguration = {
  availability: ModeAvailability
  reason?: string | undefined
}

export type TokenMetadata = {
  name: string
  symbol: string
  decimals: number
}

/**
 * Deposit, which every stack offers, then the actions its engine declares in `Engine.capabilities`,
 * before the capabilities slices add.
 */
const coreCapabilityKeys = [
  'deposit',
  'inKindDeposit',
  'redeem',
  'boundedRedeem',
  'exactWithdraw',
  'asyncRedeem',
] as const satisfies readonly ('deposit' | keyof Engine['capabilities'])[]

/** Every capability a stack advertises, in record order: core's, then each slice's. */
export const capabilityKeys = [
  ...coreCapabilityKeys,
  ...slices.flatMap((slice) => Object.keys(slice.capabilities ?? {})),
] as ((typeof coreCapabilityKeys)[number] | SliceCapabilityKey)[]

export type DeploymentCapabilities = Record<(typeof capabilityKeys)[number], boolean>

export type { EngineKind }

export type DeploymentContracts = {
  asset: Address
  earnShare: Address
  earnVault: Address
  earnFees: Address
  engine: Address
  factories?: EarnFactoryRelease | undefined
  venue: Address
  /**
   * Engine-specific contracts beside the engine and venue, keyed by the names
   * `engineDefinitions[engineKind].periphery` declares; absent when the engine declares none.
   */
  periphery?: Readonly<Record<string, Address>> | undefined
} & SliceStackFields<'contracts'>

/** Operational roles plus the optional periphery the profile's components deployed. */
export type DeploymentOperations = OptionalPeriphery & {
  owner: Address
  /** Immutable deployment-time owner for engines and optional periphery after operator rotation. */
  deploymentOwner?: Address | undefined
  revenueShareRecipient: Address
  factory: Address
  accessAdministrator?: Address | undefined
}

export type DeploymentAccess =
  | { kind: 'open' }
  | {
      kind: 'tip403-whitelist'
      transferPolicyId: string
    }

export type DeploymentNetwork = {
  name: string
  chainId: number
  rpcUrl: string
  /** Explorer base URL; absent on a chain with no explorer, such as a local one. */
  explorerUrl?: string | undefined
  pathUsd: Address
  tip20Factory: Address
} & SliceStackFields<'network'>

export type DeploymentMetadata = {
  sourceCommit: string
  sourceTreeDirty: boolean
  generatedAt: string
  deployedAtBlock: string
  transactions: Hex[]
}

/**
 * One deployed Earn stack on one network, built from its profile, generated record, and live reads. Operational consumers (E2E, localnet, tooling) use this directly; its
 * capability-owned network, contract, and mode fields come from the registered slices.
 */
export type EarnStack = {
  id: string
  label: string
  status: 'live-demo' | 'unavailable'
  engineKind: EngineKind
  network: DeploymentNetwork
  contracts: DeploymentContracts
  expectedMetadata: {
    asset: TokenMetadata
    earnShare: TokenMetadata
    venue: TokenMetadata
  }
  modes: { public: ModeConfiguration } & SliceStackFields<'modes'>
  capabilities: DeploymentCapabilities
  access: DeploymentAccess
  operations: DeploymentOperations
  metadata: DeploymentMetadata
}

/** A recorded address of a stack: a core or capability contract, or optional periphery. */
export function stackAddress(stack: EarnStack, key: DeploymentAddressKey): Address | undefined {
  const contracts: Readonly<Record<string, unknown>> = stack.contracts
  const operations: Readonly<Record<string, unknown>> = stack.operations
  return (contracts[key] ?? operations[key]) as Address | undefined
}

/** The browser-safe network of a stack: no factory or operational addresses. */
export type PublicNetwork = Omit<DeploymentNetwork, 'tip20Factory'>

/**
 * The browser-safe view of one stack. It allowlists what a browser may read: no operational roles,
 * deployment provenance, or E2E fixture. Its network is shared by every stack in a catalog.
 */
export type PublicEarnStack = Pick<
  EarnStack,
  'id' | 'engineKind' | 'contracts' | 'expectedMetadata' | 'modes' | 'capabilities' | 'access'
> & {
  /** One-sentence description shown with the stack. */
  description: string
}

/** The browser-safe stacks deployed on one network. */
export type PublicStackCatalog = {
  network: PublicNetwork
  defaultStackId: string
  stacks: PublicEarnStack[]
}

/** Stack fields that never leave operational tooling. */
const operationalKeys = ['operations', 'metadata'] as const

type StackSection = 'network' | 'contracts' | 'modes'

/** The optional keys every slice adds to one stack section, in registry order. */
function sliceStackKeys(section: StackSection) {
  return slices.flatMap((slice) => Object.keys(slice.stack?.[section] ?? {}))
}

/** Parses every slice's optional fields of one stack section, in registry order. */
function parseSliceStackFields(
  section: StackSection,
  value: Record<string, unknown>,
  path: string,
) {
  return Object.fromEntries(
    slices.flatMap((slice) =>
      Object.entries(slice.stack?.[section] ?? {}).map(([key, parse]) => [
        key,
        value[key] === undefined ? undefined : parse(value[key], `${path}.${key}`),
      ]),
    ),
  )
}

/**
 * Parses the browser-safe stacks deployed on one network. It refuses operational data and URL
 * credentials, and applies every slice's rules, such as a privately routed stack's router.
 */
export function parsePublicStackCatalog(value: unknown, path = 'catalog'): PublicStackCatalog {
  const catalog = object(value, path)
  exactKeys(catalog, path, ['network', 'defaultStackId', 'stacks'])
  const network = parseNetwork(catalog.network, `${path}.network`)
  const stacks = array(catalog.stacks, `${path}.stacks`).map((stack, index) =>
    parseStack(stack, `${path}.stacks[${index}]`),
  )
  unique(
    stacks.map((stack) => stack.id),
    'stack id',
  )
  for (const stack of stacks) validateStack(stack, network)
  const defaultStackId = nonemptyString(catalog.defaultStackId, `${path}.defaultStackId`)
  if (!stacks.some((stack) => stack.id === defaultStackId)) {
    throw new Error(`Unknown default stack: ${defaultStackId}`)
  }
  return { network, defaultStackId, stacks }
}

/** Allowlists the browser-safe fields of an operational stack. */
export function publicStack(stack: EarnStack, description: string): PublicEarnStack {
  return {
    id: stack.id,
    description,
    engineKind: stack.engineKind,
    contracts: stack.contracts,
    expectedMetadata: stack.expectedMetadata,
    modes: stack.modes,
    capabilities: stack.capabilities,
    access: stack.access,
  }
}

function parseNetwork(value: unknown, path: string): PublicNetwork {
  const network = object(value, path)
  exactKeys(
    network,
    path,
    ['name', 'chainId', 'rpcUrl', 'pathUsd'],
    ['explorerUrl', ...sliceStackKeys('network')],
  )
  return {
    name: nonemptyString(network.name, `${path}.name`),
    chainId: nonnegativeInteger(network.chainId, `${path}.chainId`),
    rpcUrl: url(network.rpcUrl, `${path}.rpcUrl`),
    explorerUrl:
      network.explorerUrl === undefined
        ? undefined
        : url(network.explorerUrl, `${path}.explorerUrl`),
    pathUsd: checksummedAddress(network.pathUsd, `${path}.pathUsd`),
    ...parseSliceStackFields('network', network, path),
  }
}

function parseStack(value: unknown, path: string): PublicEarnStack {
  const stack = object(value, path)
  for (const key of operationalKeys) {
    if (key in stack) throw new Error(`${path}.${key} is not public`)
  }
  exactKeys(stack, path, [
    'id',
    'description',
    'engineKind',
    'contracts',
    'expectedMetadata',
    'modes',
    'capabilities',
    'access',
  ])
  const contracts = object(stack.contracts, `${path}.contracts`)
  exactKeys(
    contracts,
    `${path}.contracts`,
    ['asset', 'earnShare', 'earnVault', 'earnFees', 'engine', 'venue'],
    [...sliceStackKeys('contracts'), 'factories', 'periphery'],
  )
  const expected = object(stack.expectedMetadata, `${path}.expectedMetadata`)
  exactKeys(expected, `${path}.expectedMetadata`, ['asset', 'earnShare', 'venue'])
  const modes = object(stack.modes, `${path}.modes`)
  exactKeys(modes, `${path}.modes`, ['public'], sliceStackKeys('modes'))
  const engineKind = literal(stack.engineKind, `${path}.engineKind`, engineKinds)
  return {
    id: nonemptyString(stack.id, `${path}.id`),
    description: nonemptyString(stack.description, `${path}.description`),
    engineKind,
    contracts: {
      asset: checksummedAddress(contracts.asset, `${path}.contracts.asset`),
      earnShare: checksummedAddress(contracts.earnShare, `${path}.contracts.earnShare`),
      earnVault: checksummedAddress(contracts.earnVault, `${path}.contracts.earnVault`),
      earnFees: checksummedAddress(contracts.earnFees, `${path}.contracts.earnFees`),
      ...parseSliceStackFields('contracts', contracts, `${path}.contracts`),
      engine: checksummedAddress(contracts.engine, `${path}.contracts.engine`),
      factories:
        contracts.factories === undefined
          ? undefined
          : parseFactoryRelease(
              contracts.factories,
              `${path}.contracts.factories`,
              checksummedAddress,
            ),
      venue: checksummedAddress(contracts.venue, `${path}.contracts.venue`),
      periphery: parsePeriphery(
        contracts.periphery,
        `${path}.contracts.periphery`,
        engineDefinitions[engineKind].periphery,
      ),
    },
    expectedMetadata: {
      asset: parseTokenMetadata(expected.asset, `${path}.expectedMetadata.asset`),
      earnShare: parseTokenMetadata(expected.earnShare, `${path}.expectedMetadata.earnShare`),
      venue: parseTokenMetadata(expected.venue, `${path}.expectedMetadata.venue`),
    },
    modes: {
      public: parseMode(modes.public, `${path}.modes.public`),
      ...parseSliceStackFields('modes', modes, `${path}.modes`),
    },
    capabilities: parseCapabilities(stack.capabilities, `${path}.capabilities`),
    access: parseDeploymentAccess(stack.access, `${path}.access`),
  }
}

/** Parses a published stack's access: open, or one reusable TIP-403 whitelist. */
function parseDeploymentAccess(value: unknown, path: string): DeploymentAccess {
  const access = object(value, path)
  const kind = literal(access.kind, `${path}.kind`, ['open', 'tip403-whitelist'] as const)
  if (kind === 'open') {
    exactKeys(access, path, ['kind'])
    return { kind }
  }
  exactKeys(access, path, ['kind', 'transferPolicyId'])
  return {
    kind,
    transferPolicyId: tip403PolicyId(access.transferPolicyId, `${path}.transferPolicyId`),
  }
}

function parseTokenMetadata(value: unknown, path: string): TokenMetadata {
  const metadata = object(value, path)
  exactKeys(metadata, path, ['name', 'symbol', 'decimals'])
  const decimals = nonnegativeInteger(metadata.decimals, `${path}.decimals`)
  if (decimals > 255) throw new Error(`${path}.decimals must be at most 255`)
  return {
    name: nonemptyString(metadata.name, `${path}.name`),
    symbol: nonemptyString(metadata.symbol, `${path}.symbol`),
    decimals,
  }
}

function parseCapabilities(value: unknown, path: string): DeploymentCapabilities {
  const capabilities = object(value, path)
  exactKeys(capabilities, path, capabilityKeys)
  return Object.fromEntries(
    capabilityKeys.map((key) => [key, boolean(capabilities[key], `${path}.${key}`)]),
  ) as DeploymentCapabilities
}

function validateStack(stack: PublicEarnStack, network: PublicNetwork) {
  const { capabilities, modes } = stack
  const fail = (reason: string): never => {
    throw new Error(`Stack ${stack.id} ${reason}`)
  }
  for (const slice of slices) slice.stack?.validate?.(stack, network, fail)
  if (capabilities.inKindDeposit && !capabilities.deposit) {
    fail('enables inKindDeposit without deposit')
  }
  if (capabilities.exactWithdraw && !capabilities.redeem) {
    fail('enables exactWithdraw without redeem')
  }
  if (capabilities.boundedRedeem && !capabilities.redeem) {
    fail('enables boundedRedeem without redeem')
  }
  if (
    modes.public.availability === 'available' &&
    !capabilities.deposit &&
    !capabilities.redeem &&
    !capabilities.exactWithdraw &&
    !capabilities.asyncRedeem
  ) {
    fail('has available public mode without a public action')
  }
}

/** Accepts exactly the periphery names the stack's engine declares, and none when it declares none. */
function parsePeriphery(
  value: unknown,
  path: string,
  contracts: readonly PeripheryContract[],
): Record<string, Address> | undefined {
  if (contracts.length === 0) {
    if (value !== undefined) throw new Error(`${path} is not supported by this engine`)
    return undefined
  }
  const periphery = object(value, path)
  exactKeys(
    periphery,
    path,
    contracts.filter((contract) => !contract.optional).map((contract) => contract.name),
    contracts.filter((contract) => contract.optional).map((contract) => contract.name),
  )
  return Object.fromEntries(
    contracts
      .filter((contract) => !contract.optional || periphery[contract.name] !== undefined)
      .map((contract) => [
        contract.name,
        checksummedAddress(periphery[contract.name], `${path}.${contract.name}`),
      ]),
  )
}

function boolean(value: unknown, path: string): boolean {
  if (typeof value !== 'boolean') throw new Error(`${path} must be a boolean`)
  return value
}

/** Immutable addresses one deployed Earn stack must bind to each other. */
export type ExpectedStack = {
  asset: Address
  engine: Address
  earnVault: Address
  earnShare: Address
  earnFees: Address
  engineKind: EngineKind
  /** The engine's venue; checked only when given. */
  venue?: Address | undefined
}

/** Checks the immutable engine, EarnVault, and EarnFees bindings of one stack. */
export async function inspectStackBinding(
  client: Pick<PublicClient, 'readContract'>,
  expected: ExpectedStack,
) {
  const { engine, earnVault, earnFees } = expected
  const [
    engineAsset,
    engineVault,
    vaultAsset,
    vaultEngine,
    vaultShare,
    vaultFees,
    feesVault,
    feesShare,
    venue,
  ] = await Promise.all([
    client.readContract({ address: engine, abi: earnEngineBindingAbi, functionName: 'asset' }),
    client.readContract({ address: engine, abi: earnEngineBindingAbi, functionName: 'earnVault' }),
    client.readContract({ address: earnVault, abi: earnVaultAbi, functionName: 'asset' }),
    client.readContract({ address: earnVault, abi: earnVaultAbi, functionName: 'engine' }),
    client.readContract({ address: earnVault, abi: earnVaultAbi, functionName: 'earnShare' }),
    client.readContract({ address: earnVault, abi: earnVaultAbi, functionName: 'earnFees' }),
    client.readContract({ address: earnFees, abi: earnFeesAbi, functionName: 'earnVault' }),
    client.readContract({ address: earnFees, abi: earnFeesAbi, functionName: 'earnShare' }),
    expected.venue ? readEngineVenue(client, expected.engineKind, engine) : undefined,
  ])
  equalAddress(engineAsset, expected.asset, 'engine asset')
  equalAddress(engineVault, earnVault, 'engine EarnVault binding')
  equalAddress(vaultAsset, expected.asset, 'EarnVault asset')
  equalAddress(vaultEngine, engine, 'EarnVault engine')
  equalAddress(vaultShare, expected.earnShare, 'EarnVault EarnShare')
  equalAddress(vaultFees, earnFees, 'EarnVault EarnFees')
  equalAddress(feesVault, earnVault, 'EarnFees EarnVault')
  equalAddress(feesShare, expected.earnShare, 'EarnFees EarnShare')
  if (expected.venue) equalAddress(venue!, expected.venue, 'engine venue')
}
