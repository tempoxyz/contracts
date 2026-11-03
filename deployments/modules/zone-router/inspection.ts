import { getAddress, zeroAddress, type Address, type PublicClient } from 'viem'

import { zoneRouterAbi, zoneRouterFactoryAbi } from '../../abis/index.js'
import { InspectionMismatchError, equalAddress } from '../../chain/inspect.js'
import { inspectRouterBinding } from '../earn/zone-router/inspection.js'
import type { ZoneRouterMode } from './profile.js'

/** A `ZoneRouter` the profile expects: its factory, its exact mode, and the stack it converts into. */
export type ExpectedZoneRouter = {
  router: Address
  factory: Address
  mode: ZoneRouterMode
  /** The profile's EarnShare and vault asset, which an Earn mode binds; ignored otherwise. */
  earnShare: Address
  vaultAsset: Address
}

/**
 * Checks that `factory` deployed `router` for exactly `mode` (`isRouter` and `predict`) and that every
 * immutable the router reports matches the mode: Zone, ops, spenders in order, and the Earn binding
 * with its pool orientation, or no binding at all. Mismatches throw `InspectionMismatchError`.
 */
export async function inspectZoneRouterBinding(
  client: Pick<PublicClient, 'readContract'>,
  expected: ExpectedZoneRouter,
) {
  const { router, factory, mode } = expected
  const [deployed, predicted, enabledOps, spenders] = await Promise.all([
    client.readContract({
      address: factory,
      abi: zoneRouterFactoryAbi,
      functionName: 'isRouter',
      args: [router],
    }),
    client.readContract({
      address: factory,
      abi: zoneRouterFactoryAbi,
      functionName: 'predict',
      args: [mode],
    }),
    client.readContract({ address: router, abi: zoneRouterAbi, functionName: 'enabledOps' }),
    client.readContract({ address: router, abi: zoneRouterAbi, functionName: 'spenders' }),
  ])
  if (!deployed) {
    throw new InspectionMismatchError(
      `ZoneRouterFactory ${factory} did not deploy router ${router}`,
    )
  }
  equalAddress(predicted, router, 'router for the profile mode')
  if (enabledOps !== mode.enabledOps) {
    throw new InspectionMismatchError(`Router ops are ${enabledOps}, expected ${mode.enabledOps}`)
  }
  if (
    spenders.length !== mode.spenders.length ||
    spenders.some((spender, index) => getAddress(spender) !== getAddress(mode.spenders[index]!))
  ) {
    throw new InspectionMismatchError(
      `Router spenders are [${spenders.join(', ')}], expected [${mode.spenders.join(', ')}]`,
    )
  }
  // Zone, vault, private asset, and route; a mode without Earn ops binds zero for each.
  const earns = getAddress(mode.earnVault) !== zeroAddress
  await inspectRouterBinding(client, {
    router,
    zoneId: mode.zoneId,
    earnVault: mode.earnVault,
    earnShare: earns ? expected.earnShare : zeroAddress,
    vaultAsset: earns ? expected.vaultAsset : zeroAddress,
    privateAsset: mode.privateAsset,
    route: { pool: mode.pool, customerId: mode.customerId },
  })
}
