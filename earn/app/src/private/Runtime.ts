import { earnRouterAbi } from '@tempoxyz/contracts/abis'
import {
  InspectionMismatchError,
  inspectRouterBinding,
  type PublicEarnStack,
  type ZoneConfiguration,
} from '@tempoxyz/contracts/deployments'
import { discoverZone, missingZoneTokens } from '@tempoxyz/contracts/tempo/zone'
import { getAddress, type Address, type PublicClient } from 'viem'

import type * as Zone from './Zone.js'

type Deployment = PublicEarnStack
type RegisteredZone = ZoneConfiguration

/**
 * Verifies the authenticated Zone, scoped router, and enabled token bindings. The EarnVault's
 * immutable asset and EarnShare are already covered by deployment verification, which writes need.
 */
export async function verify(options: verify.Options) {
  const { deployment, earnRouter, l1Client, zone, zoneClient } = options
  const mode = deployment.modes.private
  if (!mode || mode.availability !== 'available') {
    throw new Error(mode?.reason ?? 'Private mode is not available for this deployment.')
  }
  const zoneTokens = [
    ['EarnShare', deployment.contracts.earnShare],
    ['private asset', mode.privateAsset],
  ] as const
  const [[notEnabled], [notActive], supportsDeposit, supportsRedeem, supportsOtherFlow] =
    await Promise.all([
      missingZoneTokens(l1Client, zone.portal, zoneTokens),
      missingZoneTokens(l1Client, zone.portal, zoneTokens, { depositsActive: true }),
      l1Client.readContract({
        address: earnRouter,
        abi: earnRouterAbi,
        functionName: 'supportsFlow',
        args: [0],
      }),
      l1Client.readContract({
        address: earnRouter,
        abi: earnRouterAbi,
        functionName: 'supportsFlow',
        args: [1],
      }),
      l1Client.readContract({
        address: earnRouter,
        abi: earnRouterAbi,
        functionName: 'supportsFlow',
        args: [2],
      }),
    ])
  await verifyZoneIdentity({ l1Client, zone, zoneClient })
  await inspectRouterBinding(l1Client, {
    router: earnRouter,
    zoneId: zone.id,
    earnVault: deployment.contracts.earnVault,
    earnShare: deployment.contracts.earnShare,
    vaultAsset: deployment.contracts.asset,
    privateAsset: mode.privateAsset,
  }).catch((error: unknown) => {
    if (!(error instanceof InspectionMismatchError)) throw error
    throw new Error(`EarnRouter does not match the deployment registry: ${error.message}.`)
  })
  if (!supportsDeposit || !supportsRedeem || supportsOtherFlow) {
    throw new Error('EarnRouter does not support the closed-loop deposit and redeem flows.')
  }

  if (notEnabled) throw new Error(`The Zone has not enabled the ${notEnabled}.`)
  if (notActive) throw new Error(`The Zone is not accepting deposits for the ${notActive}.`)
}

export declare namespace verify {
  type Options = {
    deployment: Deployment
    earnRouter: Address
    l1Client: Pick<PublicClient, 'readContract'>
    zone: RegisteredZone
    zoneClient: Zone.Client
  }
}

function compareAddress(label: string, expected: Address, actual: Address) {
  if (getAddress(expected) !== getAddress(actual)) {
    throw new Error(`${label} does not match the deployment registry.`)
  }
}

async function verifyZoneIdentity(options: {
  l1Client: Pick<PublicClient, 'readContract'>
  zone: RegisteredZone
  zoneClient: Zone.Client
}) {
  const { l1Client, zone, zoneClient } = options
  const identity = await discoverZone({ l1Client, zoneClient, zoneId: zone.id })
  if (identity.id !== zone.id || identity.chainId !== zone.chainId) {
    throw new Error('Authenticated Zone identity does not match the deployment registry.')
  }
  compareAddress('Zone Portal', zone.portal, identity.portal)
  compareAddress('Zone Messenger', zone.messenger, identity.messenger)
  if (
    identity.sequencers.length !== zone.sequencers.length ||
    identity.sequencers.some(
      (sequencer, index) => getAddress(sequencer) !== getAddress(zone.sequencers[index]!),
    )
  ) {
    throw new Error('Zone sequencers do not match the deployment registry.')
  }
}
