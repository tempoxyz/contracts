import { getAddress, type Address, type Hex, type PublicClient } from 'viem'

import { earnEngineBindingAbi, earnFeesAbi, earnVaultAbi } from '../abis/index.js'
import type { DeploymentAddressKey, OptionalPeriphery } from './components.js'
import {
  readEngineKind,
  readEngineVenue,
  type Engine,
  type EngineKind,
} from '../modules/earn/engines/index.js'
import type { EarnFactoryRelease } from './releases.js'
import { equalAddress, requireCode } from '../chain/inspect.js'
import {
  slices,
  type SliceCapabilityKey,
  type SliceStackFields,
} from '../../deployments/modules/slices.js'

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
  /** Immutable deployment engine, distinct from the current engine after an operator migration. */
  creationEngine?: Address | undefined
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

/** Resolves current custody without replacing immutable deployment-engine provenance. */
export async function readCurrentEngine(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  expected: { creationEngine: Address; engineKind: EngineKind; asset: Address; earnVault: Address },
) {
  const engine = getAddress(
    await client.readContract({
      address: expected.earnVault,
      abi: earnVaultAbi,
      functionName: 'engine',
    }),
  )
  const migrated = engine !== getAddress(expected.creationEngine)
  if (migrated) {
    const mode = await client.readContract({
      address: expected.earnVault,
      abi: earnVaultAbi,
      functionName: 'engineMigrationMode',
    })
    if (mode !== 1)
      throw new Error('EarnVault current engine changed without OperatorEnabled migration')
  }
  await requireCode(client, { engine })
  const [asset, vault, vaultAsset] = await Promise.all([
    client.readContract({ address: engine, abi: earnEngineBindingAbi, functionName: 'asset' }),
    client.readContract({ address: engine, abi: earnEngineBindingAbi, functionName: 'earnVault' }),
    client.readContract({ address: expected.earnVault, abi: earnVaultAbi, functionName: 'asset' }),
  ])
  equalAddress(asset, expected.asset, 'current engine asset')
  equalAddress(vault, expected.earnVault, 'current engine EarnVault binding')
  equalAddress(vaultAsset, expected.asset, 'EarnVault asset')
  const engineKind = migrated ? await readEngineKind(client, engine) : expected.engineKind
  return { engine, engineKind, venue: await readEngineVenue(client, engineKind, engine) }
}
