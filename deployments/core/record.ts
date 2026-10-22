import type { Address } from 'viem'

import { deploymentActions, type EarnDeploymentActionId } from './plan.js'
import { isHostedDeploymentChain } from '../chain/tempo.js'
import { deploymentSteps } from '../modules/index.js'
import { slices, type SliceTargets } from '../modules/slices.js'
import {
  deploymentAddressComponents,
  deploymentAddressKeys,
  externalAddressKeys,
  hasRuntimeCode,
  intentComponents,
  peripheryComponents,
  type DeploymentAddressKey,
  type IntentComponent,
} from './components.js'
import {
  address,
  decimalString,
  exactKeys,
  isBytes32,
  literal,
  nonemptyString,
  nonnegativeInteger,
  object,
} from './parse.js'
import {
  componentDeploymentIntentHashes,
  deploymentIntentHash,
  profileDeploymentSalt,
  profileFactoryDeploymentId,
  type ComponentIntentHashes,
  type EarnDeploymentProfile,
} from './profile.js'
import { parseFactoryRelease, sameFactoryRelease, type EarnFactoryRelease } from './releases.js'

/** The chain, and each capability's external identity, a deployment record is bound to. */
export type DeploymentTarget = {
  chainId: number
  genesisHash: `0x${string}`
} & SliceTargets

/** One capability's identity in a target, by its slice's key. */
function targetIdentity(target: DeploymentTarget, key: string) {
  return (target as Readonly<Record<string, unknown>>)[key]
}

/** The recorded addresses that must have runtime bytecode. */
export function runtimeCodeAddressKeysFor(addresses: DeploymentAddresses) {
  return deploymentAddressKeys.filter((key) => {
    const address = addresses[key]
    return address !== undefined && hasRuntimeCode(key, address)
  })
}

/** The capability-owned keys of a deployment target. */
const targetSlices = slices.flatMap((slice) =>
  slice.target ? [{ ...slice.target, component: slice.target.component as IntentComponent }] : [],
)

/** Builds a deployment target from the L1 genesis and each capability's discovered identity. */
export function deploymentTarget(
  profile: EarnDeploymentProfile,
  genesisHash: `0x${string}`,
  outputs: Record<string, Address>,
): DeploymentTarget {
  const target: Record<string, unknown> = { chainId: profile.chainId, genesisHash }
  for (const slice of targetSlices) {
    const value = slice.discover(profile, outputs)
    if (value !== undefined) target[slice.key] = value
  }
  return target as DeploymentTarget
}

export type DeploymentAddresses = Partial<Record<DeploymentAddressKey, Address>>
export type CompletedDeploymentAction = {
  completedAt: string
  verification: 'broadcast' | 'chain'
  transactions: `0x${string}`[]
}

export type DeploymentSource = {
  factoryDeploymentId: `0x${string}` | null
  commit: `0x${string}` | null
  treeDirty: boolean | null
  foundryVersion: string | null
  contractVerification: 'pending' | 'verified' | 'not-applicable'
  verifierUrl: string | null
  contracts: Partial<Record<DeploymentAddressKey, ContractSourceVerification>>
}

export type ContractSourceVerification =
  | { kind: 'source'; name: string; match: SourceMatch; sourceInputsHash: `0x${string}` }
  | {
      kind: 'erc1967-proxy'
      name: 'ERC1967Proxy'
      match: SourceMatch
      sourceInputsHash: `0x${string}`
      implementation: Address
      implementationCodeHash: `0x${string}`
    }
  | {
      kind: 'minimal-proxy'
      implementation: Address
      implementationCodeHash: `0x${string}`
    }
  | { kind: 'protocol-native'; factory: Address }

export type SourceMatch = 'exact_match' | 'match'

export type EarnDeploymentRecord = {
  version: 4
  deploymentId: string
  deployer: Address
  owner: Address
  factories: EarnFactoryRelease
  deploymentIntentHash: string
  componentDeploymentIntentHashes: ComponentIntentHashes
  target: DeploymentTarget
  assetDecimals: number
  deploymentBlock: string
  generatedAt: string
  source: DeploymentSource
  runtimeCodeHashes: Partial<Record<DeploymentAddressKey, `0x${string}`>>
  addresses: DeploymentAddresses
  actions: Partial<Record<EarnDeploymentActionId, CompletedDeploymentAction>>
}

/**
 * Whether two targets name the same chain and capability identities. A capability whose component
 * is being reconciled may move to a new identity on the same chain.
 */
export function sameDeploymentTarget(
  left: DeploymentTarget,
  right: DeploymentTarget,
  reconciling: ReadonlySet<IntentComponent> = new Set(),
) {
  return (
    left.chainId === right.chainId &&
    left.genesisHash.toLowerCase() === right.genesisHash.toLowerCase() &&
    targetSlices.every(
      (slice) =>
        reconciling.has(slice.component) ||
        slice.same(targetIdentity(left, slice.key), targetIdentity(right, slice.key)),
    )
  )
}

const recordKeys = [
  'version',
  'deploymentId',
  'deployer',
  'owner',
  'factories',
  'deploymentIntentHash',
  'componentDeploymentIntentHashes',
  'target',
  'assetDecimals',
  'deploymentBlock',
  'generatedAt',
  'source',
  'runtimeCodeHashes',
  'addresses',
  'actions',
] as const

export function parseEarnDeploymentRecord(
  value: unknown,
  profile: EarnDeploymentProfile,
  path = 'deployment record',
  options: { allowPeripheryMismatch?: boolean } = {},
): EarnDeploymentRecord {
  const source = object(value, path)
  exactKeys(source, path, recordKeys)
  const recordedComponents = parseComponentIntentHashes(
    source.componentDeploymentIntentHashes,
    `${path}.componentDeploymentIntentHashes`,
  )
  const changedComponents = changedIntentComponents(recordedComponents, profile)
  // Only deployment may reconcile a record in place, and only its periphery components.
  const mayReconcilePeriphery =
    options.allowPeripheryMismatch === true &&
    !changedComponents.has('core') &&
    !changedComponents.has('engine')
  if (!mayReconcilePeriphery && changedComponents.size > 0)
    mismatch(`${path}.componentDeploymentIntentHashes`)
  const targetChanged = targetSlices.some((slice) => changedComponents.has(slice.component))
  // Unknown keys own no component; the supported-key checks below reject them.
  const changedAddress = (key: DeploymentAddressKey) =>
    Object.hasOwn(deploymentAddressComponents, key) &&
    changedComponents.has(deploymentAddressComponents[key])
  // Unknown keys are not periphery actions; the planned-action check below rejects them.
  const changedAction = (key: string) =>
    deploymentSteps
      .find((step) => step.id === key)
      ?.intent.some((component) => changedComponents.has(component)) ?? false

  const expect = (field: string, matches: boolean) => {
    if (!matches) mismatch(`${path}.${field}`)
  }
  expect('version', source.version === 4)
  expect('deploymentId', source.deploymentId === profile.id)
  expect('deployer', address(source.deployer, `${path}.deployer`) === profile.deployer)
  expect('owner', address(source.owner, `${path}.owner`) === profile.owner)
  expect(
    'factories',
    sameFactoryRelease(
      parseFactoryRelease(source.factories, `${path}.factories`),
      profile.factories,
    ),
  )
  if (!mayReconcilePeriphery)
    expect('deploymentIntentHash', source.deploymentIntentHash === deploymentIntentHash(profile))
  const target = parseTarget(source.target, `${path}.target`, profile, targetChanged)
  const assetDecimals = nonnegativeInteger(source.assetDecimals, `${path}.assetDecimals`)
  expect('assetDecimals', assetDecimals <= 255)

  const expectedAddresses = new Set(deploymentAddressKeysForProfile(profile))
  const recorded = (key: DeploymentAddressKey) => expectedAddresses.has(key) || changedAddress(key)
  const addresses: DeploymentAddresses = {}
  for (const [key, entry] of Object.entries(object(source.addresses, `${path}.addresses`))) {
    if (!deploymentAddressKeys.includes(key as DeploymentAddressKey)) {
      throw new Error(`${path}.addresses.${key} is not a supported deployment address`)
    }
    if (!recorded(key as DeploymentAddressKey)) {
      throw new Error(`${path}.addresses.${key} is not used by profile ${profile.id}`)
    }
    addresses[key as DeploymentAddressKey] = address(entry, `${path}.addresses.${key}`)
  }
  for (const key of expectedAddresses) {
    if (!addresses[key] && !changedAddress(key))
      throw new Error(`${path}.addresses.${key} is required by profile ${profile.id}`)
  }
  if (!targetChanged) {
    for (const slice of targetSlices)
      slice.checkAddresses?.(addresses, targetIdentity(target, slice.key), path)
  }

  const plannedActions = new Set<string>(deploymentActions(profile).map((action) => action.id))
  const actions: EarnDeploymentRecord['actions'] = {}
  for (const [key, entry] of Object.entries(object(source.actions, `${path}.actions`))) {
    if (!plannedActions.has(key) && !changedAction(key)) {
      throw new Error(`${path}.actions.${key} is not used by profile ${profile.id}`)
    }
    actions[key as EarnDeploymentActionId] = parseCompletedAction(entry, `${path}.actions.${key}`)
  }
  for (const key of plannedActions) {
    if (!actions[key as EarnDeploymentActionId] && !changedAction(key))
      throw new Error(`${path}.actions.${key} is required by profile ${profile.id}`)
  }

  const runtimeCodeHashes: EarnDeploymentRecord['runtimeCodeHashes'] = {}
  for (const [key, hash] of Object.entries(
    object(source.runtimeCodeHashes, `${path}.runtimeCodeHashes`),
  )) {
    if (!recorded(key as DeploymentAddressKey) || !isBytes32(hash))
      throw new Error(`${path}.runtimeCodeHashes.${key} is invalid`)
    runtimeCodeHashes[key as DeploymentAddressKey] = hash
  }
  for (const key of runtimeCodeAddressKeysFor(addresses).filter(recorded)) {
    if (!runtimeCodeHashes[key]) throw new Error(`${path}.runtimeCodeHashes.${key} is required`)
  }

  return {
    version: 4,
    deploymentId: profile.id,
    deployer: profile.deployer,
    owner: profile.owner,
    factories: profile.factories,
    deploymentIntentHash: deploymentIntentHash(profile),
    componentDeploymentIntentHashes: recordedComponents,
    target,
    assetDecimals,
    deploymentBlock: decimalString(source.deploymentBlock, `${path}.deploymentBlock`),
    generatedAt: nonemptyString(source.generatedAt, `${path}.generatedAt`),
    source: parseDeploymentSource(source.source, `${path}.source`, profile, changedAddress),
    runtimeCodeHashes,
    addresses,
    actions,
  }
}

/**
 * The record target: the profile's chain plus each capability's identity, which only needs a valid
 * shape while its component is being reconciled.
 */
function parseTarget(
  value: unknown,
  path: string,
  profile: EarnDeploymentProfile,
  reconciling: boolean,
): DeploymentTarget {
  const target = object(value, path)
  exactKeys(
    target,
    path,
    ['chainId', 'genesisHash'],
    targetSlices.map((slice) => slice.key),
  )
  if (target.chainId !== profile.chainId || !isBytes32(target.genesisHash)) mismatch(path)
  for (const slice of targetSlices)
    slice.parse(target[slice.key], `${path}.${slice.key}`, reconciling ? undefined : profile)
  return target as DeploymentTarget
}

/** The source provenance each contract kind records; every other created contract is `source`. */
const contractKinds: Partial<Record<DeploymentAddressKey, ContractSourceVerification['kind']>> = {
  earnVault: 'erc1967-proxy',
  earnFees: 'minimal-proxy',
  earnShare: 'protocol-native',
}

/**
 * Recorded source provenance: the profile's factory deployment ID, and verifier results for every
 * created contract once a hosted chain verifies them. A hosted record may be published as
 * `pending` first; a local chain's is always `not-applicable`.
 */
function parseDeploymentSource(
  value: unknown,
  path: string,
  profile: EarnDeploymentProfile,
  changedAddress: (key: DeploymentAddressKey) => boolean,
): DeploymentSource {
  const source = object(value, path)
  exactKeys(source, path, [
    'factoryDeploymentId',
    'commit',
    'treeDirty',
    'foundryVersion',
    'contractVerification',
    'verifierUrl',
    'contracts',
  ])
  const factoryDeploymentId = source.factoryDeploymentId
  if (
    !isBytes32(factoryDeploymentId) ||
    factoryDeploymentId.toLowerCase() !== profileFactoryDeploymentId(profile).toLowerCase()
  ) {
    throw new Error(
      `${path}.factoryDeploymentId does not match profile deployment ${profileDeploymentSalt(profile)}`,
    )
  }
  const nullable = <T>(field: string, valid: (entry: unknown) => boolean) => {
    const entry = source[field]
    if (entry !== null && !valid(entry)) mismatch(`${path}.${field}`)
    return entry as T | null
  }
  const parsed: DeploymentSource = {
    factoryDeploymentId,
    commit: nullable<`0x${string}`>(
      'commit',
      (entry) => typeof entry === 'string' && /^0x[0-9a-fA-F]{40}$/.test(entry),
    ),
    treeDirty: nullable<boolean>('treeDirty', (entry) => typeof entry === 'boolean'),
    foundryVersion: nullable<string>('foundryVersion', (entry) => typeof entry === 'string'),
    contractVerification: literal(source.contractVerification, `${path}.contractVerification`, [
      'pending',
      'verified',
      'not-applicable',
    ] as const),
    verifierUrl: nullable<string>(
      'verifierUrl',
      (entry) => typeof entry === 'string' && entry.length > 0,
    ),
    contracts: parseContractVerifications(source.contracts, `${path}.contracts`),
  }
  const hosted = isHostedDeploymentChain(profile.chainId)
  const contracts = parsed.contracts
  if (parsed.contractVerification !== 'verified') {
    if (
      parsed.verifierUrl !== null ||
      Object.keys(contracts).length > 0 ||
      hosted !== (parsed.contractVerification === 'pending')
    )
      mismatch(path)
    return parsed
  }
  const verified = (key: DeploymentAddressKey) => !externalAddressKeys.includes(key)
  const expected = deploymentAddressKeysForProfile(profile).filter(verified)
  const keys = Object.keys(contracts) as DeploymentAddressKey[]
  if (
    !hosted ||
    parsed.verifierUrl === null ||
    keys.some((key) => !verified(key) || (!expected.includes(key) && !changedAddress(key))) ||
    expected.some((key) => !contracts[key] && !changedAddress(key)) ||
    keys.some((key) => contracts[key]!.kind !== (contractKinds[key] ?? 'source')) ||
    Object.keys(contractKinds).some((key) => !contracts[key as DeploymentAddressKey])
  )
    mismatch(path)
  return parsed
}

function parseContractVerifications(value: unknown, path: string): DeploymentSource['contracts'] {
  const contracts = object(value, path)
  for (const [key, entry] of Object.entries(contracts)) {
    const contractPath = `${path}.${key}`
    if (!deploymentAddressKeys.includes(key as DeploymentAddressKey)) mismatch(contractPath)
    const contract = object(entry, contractPath)
    const kind = literal(contract.kind, `${contractPath}.kind`, [
      'source',
      'erc1967-proxy',
      'minimal-proxy',
      'protocol-native',
    ] as const)
    const hash = (field: string) => {
      if (!isBytes32(contract[field])) mismatch(`${contractPath}.${field}`)
    }
    if (kind === 'source' || kind === 'erc1967-proxy') {
      literal(contract.match, `${contractPath}.match`, ['exact_match', 'match'] as const)
      hash('sourceInputsHash')
    }
    if (kind === 'erc1967-proxy' || kind === 'minimal-proxy') {
      address(contract.implementation, `${contractPath}.implementation`)
      hash('implementationCodeHash')
    }
    if (kind === 'source') {
      exactKeys(contract, contractPath, ['kind', 'name', 'match', 'sourceInputsHash'])
      nonemptyString(contract.name, `${contractPath}.name`)
    } else if (kind === 'erc1967-proxy') {
      exactKeys(contract, contractPath, [
        'kind',
        'name',
        'match',
        'sourceInputsHash',
        'implementation',
        'implementationCodeHash',
      ])
      literal(contract.name, `${contractPath}.name`, ['ERC1967Proxy'] as const)
    } else if (kind === 'minimal-proxy') {
      exactKeys(contract, contractPath, ['kind', 'implementation', 'implementationCodeHash'])
    } else {
      exactKeys(contract, contractPath, ['kind', 'factory'])
      address(contract.factory, `${contractPath}.factory`)
    }
  }
  return contracts as DeploymentSource['contracts']
}

function parseComponentIntentHashes(value: unknown, path: string) {
  const hashes = object(value, path)
  exactKeys(hashes, path, intentComponents)
  for (const key of intentComponents) {
    const optional = (peripheryComponents as readonly IntentComponent[]).includes(key)
    if (!digest(hashes[key]) && !(optional && hashes[key] === null)) mismatch(`${path}.${key}`)
  }
  return hashes as ComponentIntentHashes
}

/** The intent components whose recorded hash differs from the profile's. */
export function changedIntentComponents(
  recorded: ComponentIntentHashes,
  profile: EarnDeploymentProfile,
) {
  const current = componentDeploymentIntentHashes(profile)
  return new Set<IntentComponent>(
    intentComponents.filter((component) => recorded[component] !== current[component]),
  )
}

/** The addresses a profile records: those whose owning intent component it configures. */
export function deploymentAddressKeysForProfile(
  profile: EarnDeploymentProfile,
): DeploymentAddressKey[] {
  const components = componentDeploymentIntentHashes(profile)
  return deploymentAddressKeys.filter(
    (key) => components[deploymentAddressComponents[key]] !== null,
  )
}

/** A completed action: verified onchain, or broadcast with the transactions that did it. */
export function parseCompletedAction(value: unknown, path: string): CompletedDeploymentAction {
  const action = object(value, path)
  const { completedAt, verification, transactions } = action
  if (
    Object.keys(action).some(
      (key) => key !== 'completedAt' && key !== 'verification' && key !== 'transactions',
    ) ||
    typeof completedAt !== 'string' ||
    completedAt.length === 0 ||
    (verification !== 'broadcast' && verification !== 'chain') ||
    !Array.isArray(transactions) ||
    (verification === 'broadcast' && transactions.length === 0) ||
    !transactions.every(isBytes32)
  )
    throw new Error(`${path} is not a completed deployment action`)
  return action as CompletedDeploymentAction
}

function digest(value: unknown): value is string {
  return typeof value === 'string' && isBytes32(`0x${value}`)
}

function mismatch(path: string): never {
  throw new Error(`Generated deployment result ${path} does not match its deployment profile`)
}
