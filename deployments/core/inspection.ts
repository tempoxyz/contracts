import { zeroHash, type Address, type PublicClient } from 'viem'
import { Abis } from 'viem/tempo'

import { earnFactoryAbi } from '../abis/index.js'
import { inspectEngineBindings, readEngineBinding } from '../modules/earn/engines/index.js'
import { equalAddress, requireCode, type LatestBlockClient } from '../chain/inspect.js'
import { capabilityModules } from '../../deployments/modules/index.js'
import { requiredOutput, type InspectionReport } from '../../deployments/modules/module.js'
import {
  engineAddress,
  deploysEngine,
  earnFactoryDeployParams,
  engineOwnerAccepted,
  profileEngineFactory,
  profileFactoryDeploymentId,
  type EarnDeploymentProfile,
} from './profile.js'
import { inspectStackBinding } from './stack.js'

/**
 * Performs the complete, shared post-deployment inspection used by deploy and verify. Binding
 * mismatches throw; mutable capability readiness is reported without failing inspection.
 */
export async function inspectEarnDeployment(
  client: Pick<PublicClient, 'getCode' | 'readContract'> & LatestBlockClient,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
  factoryDeploymentId: `0x${string}` | null = profileFactoryDeploymentId(profile),
): Promise<InspectionReport> {
  if (!factoryDeploymentId) {
    throw new Error('Factory deployment ID is required for deployment inspection')
  }
  const engine = engineAddress(profile, outputs)
  const vault = requiredOutput(outputs, 'earnVault')
  const share = requiredOutput(outputs, 'earnShare')
  const fees = requiredOutput(outputs, 'earnFees')
  const asset = requiredOutput(outputs, 'asset')

  await requireCode(client, { engine, vault, share, fees })
  await inspectStackBinding(client, {
    asset,
    engine,
    earnVault: vault,
    earnShare: share,
    earnFees: fees,
    engineKind: profile.engine.kind,
    venue: 'venue' in profile.engine ? profile.engine.venue : undefined,
  })
  // The stack binding above proved the engine is bound to `vault`, whose operator this reads.
  const { owner, vaultOperator } = await readEngineBinding(client, engine)
  await inspectEngineBindings(client, profile.engine.kind, engine)
  if (!engineOwnerAccepted(profile, owner, vaultOperator)) {
    throw new Error(
      `Engine owner is ${owner}, expected ${profile.owner} or EarnVault operator ${vaultOperator}`,
    )
  }

  const issuerRole = await client.readContract({
    address: share,
    abi: Abis.tip20,
    functionName: 'ISSUER_ROLE',
  })
  const [vaultIsIssuer, ownerIsAdministrator, factoryIsAdministrator, vaultIsAdministrator] =
    await Promise.all([
      client.readContract({
        address: share,
        abi: Abis.tip20,
        functionName: 'hasRole',
        args: [vault, issuerRole],
      }),
      client.readContract({
        address: share,
        abi: Abis.tip20,
        functionName: 'hasRole',
        args: [profile.owner, zeroHash],
      }),
      client.readContract({
        address: share,
        abi: Abis.tip20,
        functionName: 'hasRole',
        args: [profile.factories.earn, zeroHash],
      }),
      client.readContract({
        address: share,
        abi: Abis.tip20,
        functionName: 'hasRole',
        args: [vault, zeroHash],
      }),
    ])
  if (!vaultIsIssuer) throw new Error('EarnVault does not hold the EarnShare issuer role')
  if (ownerIsAdministrator)
    throw new Error('Earn operator retained EarnShare administrator authority')
  if (factoryIsAdministrator)
    throw new Error('EarnFactory retained EarnShare administrator authority')
  if (vaultIsAdministrator)
    throw new Error('EarnVault unexpectedly holds EarnShare administrator authority')

  await inspectFactoryPredictions(client, profile, outputs, engine, factoryDeploymentId)
  // Every capability's inspection, in registry order: binding mismatches throw, readiness is reported.
  const reports: Array<InspectionReport | undefined> = []
  for (const module of capabilityModules)
    reports.push(await module.inspect?.(client, profile, outputs))
  return Object.assign({}, ...reports) as InspectionReport
}

async function inspectFactoryPredictions(
  client: Pick<PublicClient, 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
  engine: Address,
  deploymentId: `0x${string}`,
) {
  if (deploysEngine(profile)) {
    const factory = profileEngineFactory(profile)
    const predicted = await factory.predictEngine(client, factory.address, {
      deploymentId,
      venue: profile.engine.venue,
      owner: profile.deployer,
    })
    equalAddress(predicted, engine, 'predicted engine')
  }

  const params = earnFactoryDeployParams(profile, engine, deploymentId)
  const [predictedShare, predictedFees] = await Promise.all([
    client.readContract({
      address: profile.factories.earn,
      abi: earnFactoryAbi,
      functionName: 'predictEarnShare',
      args: [params],
    }),
    client.readContract({
      address: profile.factories.earn,
      abi: earnFactoryAbi,
      functionName: 'predictEarnFees',
      args: [params],
    }),
  ])
  equalAddress(predictedShare, requiredOutput(outputs, 'earnShare'), 'predicted EarnShare')
  equalAddress(predictedFees, requiredOutput(outputs, 'earnFees'), 'predicted EarnFees')
}
