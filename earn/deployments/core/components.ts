import type { Address } from 'viem'

import {
  slices,
  type OptionalPeripheryKey,
  type PeripheryComponent,
  type SliceAddressComponent,
  type SliceAddressKey,
} from '../modules/slices.js'

export type { OptionalPeripheryKey, PeripheryComponent }

export const peripheryComponents = slices.flatMap((slice) =>
  Object.keys(slice.components ?? {}),
) as PeripheryComponent[]

/**
 * The independently hashed parts of deployment intent; see `componentDeploymentIntentHashes`.
 * `core` and `engine` are always present; the rest are `null` when the profile omits them.
 */
export const intentComponents = ['core', 'engine', ...peripheryComponents] as const

export type IntentComponent = 'core' | 'engine' | PeripheryComponent

/** Compiles only when no slice address names an undeclared intent component. */
function declaredComponents<Undeclared>(_none: [Undeclared] extends [never] ? true : never) {}
declaredComponents<Exclude<SliceAddressComponent, IntentComponent>>(true)

/** Addresses the core component records: the asset it is bound to and the contracts it deploys. */
const coreAddressComponents = {
  asset: 'core',
  engine: 'engine',
  earnFees: 'core',
  earnShare: 'core',
  earnVault: 'core',
} as const

export type DeploymentAddressKey = keyof typeof coreAddressComponents | SliceAddressKey

/** One address map of every slice, in registry order. */
function sliceAddresses(field: 'externalAddresses' | 'addresses' | 'periphery') {
  return Object.assign({}, ...slices.map((slice) => slice[field])) as Record<
    string,
    IntentComponent
  >
}

/**
 * Every recorded deployment address and the intent component that owns it, in record order:
 * discovered external identities, core, then each slice's deployed contracts. An address is
 * recorded exactly when its component is configured, and reused on resume only while that
 * component's intent hash is unchanged.
 */
export const deploymentAddressComponents = {
  ...sliceAddresses('externalAddresses'),
  ...coreAddressComponents,
  ...sliceAddresses('addresses'),
  ...sliceAddresses('periphery'),
} as Readonly<Record<DeploymentAddressKey, IntentComponent>>

export const deploymentAddressKeys = Object.keys(
  deploymentAddressComponents,
) as DeploymentAddressKey[]

/** Addresses the deployment uses but does not create, so they carry no source verification. */
export const externalAddressKeys = [
  'asset',
  ...Object.keys(sliceAddresses('externalAddresses')),
] as DeploymentAddressKey[]

/** Whether a recorded address must have runtime bytecode; protocol precompiles have none. */
export function hasRuntimeCode(key: DeploymentAddressKey, address: Address) {
  return !slices.some((slice) => slice.codeless?.(key, address))
}

/**
 * Contracts optional components deploy beside the core stack that no capability places in its own
 * stack fields; they travel together as `OptionalPeriphery`.
 */
export type OptionalPeriphery = { [K in OptionalPeripheryKey]?: Address | undefined }

export const optionalPeripheryKeys = Object.keys(
  sliceAddresses('periphery'),
) as OptionalPeripheryKey[]

/** The optional periphery present in a set of recorded or operational addresses. */
export function optionalPeriphery(
  addresses: Readonly<Partial<Record<string, Address | undefined>>>,
): OptionalPeriphery {
  return Object.fromEntries(
    optionalPeripheryKeys.flatMap((key) => {
      const address = addresses[key]
      return address ? [[key, address]] : []
    }),
  )
}
