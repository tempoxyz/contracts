import {
  InspectionMismatchError,
  inspectStackBinding,
  type EngineKind,
  type PublicEarnStack,
} from '@tempoxyz/earn/deployments'
import { erc20Abi, getAddress, type PublicClient } from 'viem'
import { Abis } from 'viem/tempo'

import type { CatalogStack } from '../../deployments/catalog.js'
import { privateRouteAsset } from '../../deployments/tokens.js'
import * as AccessVerification from './AccessVerification.js'
import * as VedaVerification from './VedaVerification.js'

type Client = Pick<PublicClient, 'getChainId' | 'readContract'>

/** A verified deployment, or the user-facing issues that keep its writes disabled. */
export type VerificationResult =
  | { status: 'verified' }
  | { status: 'mismatch' | 'unavailable'; issues: string[] }

/** App verification beyond the shared stack bindings for the engine kinds that need it. */
const engineVerification: Partial<Record<EngineKind, typeof VedaVerification.verify>> = {
  veda: VedaVerification.verify,
}

const unavailable: VerificationResult = {
  status: 'unavailable',
  issues: ['Deployment verification reads are temporarily unavailable.'],
}

/**
 * Verifies one registered deployment through account-free chain reads. The immutable stack
 * bindings come from the shared inspector; a mismatch is an issue, a failed read is unavailable.
 */
export async function verifyDeployment(
  client: Client,
  chainId: number,
  deployment: CatalogStack,
): Promise<VerificationResult> {
  let actualChainId: number
  try {
    actualChainId = await client.getChainId()
  } catch {
    return unavailable
  }
  if (actualChainId !== chainId) {
    return {
      status: 'unavailable',
      issues: [`Expected chain ${chainId}, received ${actualChainId}.`],
    }
  }

  try {
    const { contracts, expectedMetadata } = deployment
    const issues: string[] = []
    try {
      await inspectStackBinding(client, {
        asset: contracts.asset,
        engine: contracts.engine,
        earnVault: contracts.earnVault,
        earnShare: contracts.earnShare,
        earnFees: contracts.earnFees,
        engineKind: deployment.engineKind,
        venue: contracts.venue,
      })
    } catch (error) {
      if (!(error instanceof InspectionMismatchError)) throw error
      issues.push(`Deployment bindings do not verify: ${error.message}.`)
    }
    const privateAsset = privateRouteAsset(deployment)
    const [assetDecimals, earnShareDecimals, isAccountingAligned, privateAssetDecimals] =
      await Promise.all([
        client.readContract({ address: contracts.asset, abi: erc20Abi, functionName: 'decimals' }),
        client.readContract({
          address: contracts.earnShare,
          abi: erc20Abi,
          functionName: 'decimals',
        }),
        client.readContract({
          address: contracts.earnVault,
          abi: Abis.earnVault,
          functionName: 'isAccountingAligned',
        }),
        privateAsset
          ? client.readContract({ address: privateAsset, abi: erc20Abi, functionName: 'decimals' })
          : undefined,
      ])
    if (privateAssetDecimals !== deployment.privateAssetMetadata?.decimals) {
      issues.push('Private asset decimals do not match the catalog.')
    }
    if (assetDecimals !== expectedMetadata.asset.decimals) {
      issues.push('Asset decimals do not match the registry.')
    }
    if (earnShareDecimals !== expectedMetadata.earnShare.decimals) {
      issues.push('EarnShare decimals do not match the registry.')
    }
    if (!isAccountingAligned) {
      issues.push('EarnVault reports that supply and engine backing are not aligned.')
    }
    if (issues.length === 0)
      await engineVerification[deployment.engineKind]?.(client, deployment, issues)
    await AccessVerification.verify(client, deployment, issues)

    return issues.length > 0 ? { status: 'mismatch', issues } : { status: 'verified' }
  } catch {
    return unavailable
  }
}

/** Rechecks the mutable EarnVault state immediately before a public write. */
export async function readPublicWriteState(
  client: Pick<PublicClient, 'readContract'>,
  deployment: PublicEarnStack,
) {
  const [engine, isAccountingAligned] = await Promise.all([
    client.readContract({
      address: deployment.contracts.earnVault,
      abi: Abis.earnVault,
      functionName: 'engine',
    }),
    client.readContract({
      address: deployment.contracts.earnVault,
      abi: Abis.earnVault,
      functionName: 'isAccountingAligned',
    }),
  ])
  return { engineMatches: getAddress(engine) === deployment.contracts.engine, isAccountingAligned }
}
