import {
  createPublicClient,
  erc20Abi,
  getAddress,
  toHex,
  type Address,
  type Client,
  type Hex,
  type PublicClient,
} from 'viem'
import { Abis, Addresses } from 'viem/tempo'

import { configuredRpcTransport, rpcConfiguration } from '../chain/runtime.js'
import { configuredTempoNetworkChain, hostedEnvironment } from '../chain/tempo.js'
import { capabilityModules } from '../../deployments/modules/index.js'
import { requiredOutput, type StackSlice } from '../../deployments/modules/module.js'
import { engineDefinitions } from '../modules/earn/engines/index.js'
import {
  loadEarnProfileBundle,
  loadReviewedDeploymentIdentity,
  resolveProfilePath,
} from './bundle.js'
import { optionalPeriphery } from './components.js'
import {
  deploysEngine,
  engineAddress,
  profileCapabilities,
  type EarnDeploymentProfile,
} from './profile.js'
import type { EarnDeploymentRecord } from './record.js'
import type { ReviewedDeploymentIdentity } from './releases.js'
import { inspectStackBinding, readCurrentEngine, type EarnStack } from './stack.js'

/**
 * Builds the stack of one deployed profile from its generated record and live reads. Nothing is
 * inherited from a checked-in manifest: token metadata, venue, engine periphery, operator, and
 * access administrator are read from the chain the record targets. A test fixture is the caller's
 * to attach.
 */
export async function profileStack(options: profileStack.Options): Promise<EarnStack> {
  const { client, environment, profile, record } = options
  const [chainId, genesis] = await Promise.all([
    client.getChainId(),
    client.getBlock({ blockNumber: 0n }),
  ])
  if (chainId !== profile.chainId || chainId !== record.target.chainId)
    throw new Error('RPC chain ID does not match the profile and generated deployment record')
  if (!genesis.hash || genesis.hash.toLowerCase() !== record.target.genesisHash.toLowerCase())
    throw new Error('RPC genesis hash does not match the generated deployment record')
  const outputs = record.addresses as Record<string, Address>
  const asset = requiredOutput(outputs, 'asset')
  const earnShare = requiredOutput(outputs, 'earnShare')
  const earnVault = requiredOutput(outputs, 'earnVault')
  const earnFees = requiredOutput(outputs, 'earnFees')
  const creationEngine = engineAddress(profile, outputs)
  const { engine, engineKind, venue } = await readCurrentEngine(client, {
    creationEngine,
    engineKind: profile.engine.kind,
    asset,
    earnVault,
  })
  if (engine !== creationEngine && profile.core.migrationMode !== 'OperatorEnabled')
    throw new Error('Profile does not allow operator engine migration')
  await inspectStackBinding(client, {
    asset,
    engine,
    earnVault,
    earnShare,
    earnFees,
    engineKind,
    venue:
      engine === creationEngine && 'venue' in profile.engine ? profile.engine.venue : undefined,
  })
  const [operator, periphery, slices, capabilities] = await Promise.all([
    // The current transferable operator, not the deployment owner the record names.
    client.readContract({ address: earnVault, abi: Abis.earnVault, functionName: 'operator' }),
    engineDefinitions[engineKind].readPeriphery?.(client, engine),
    Promise.all(capabilityModules.map((module) => module.stack?.(options))),
    engineDefinitions[engineKind].readCapabilities?.(client, engine),
  ])
  // Each capability's fields, merged in module order into their places in the stack.
  const slice = <Key extends keyof StackSlice>(key: Key) =>
    Object.assign({}, ...slices.map((entry) => entry?.[key])) as NonNullable<StackSlice[Key]>
  const access = slices.find((entry) => entry?.access)?.access
  if (!access) throw new Error(`Profile ${profile.id} has no access capability`)
  const [assetMetadata, earnShareMetadata, venueMetadata] = await Promise.all(
    [asset, earnShare, venue].map((token) => tokenMetadata(client, token)),
  )
  const revenueShareRecipient =
    profile.core.fees.excess?.recipient ??
    (profile.core.fees.protectedFixed?.rateBps
      ? profile.core.fees.protectedFixed.recipient
      : undefined) ??
    profile.core.fees.fixed[0]?.recipient ??
    profile.owner
  return {
    id: profile.id,
    label: profile.id,
    status: 'live-demo',
    engineKind,
    network: {
      name: environment.id,
      chainId: profile.chainId,
      rpcUrl: environment.tempoRpcUrl,
      explorerUrl: environment.explorerUrl,
      pathUsd: getAddress(Addresses.pathUsd),
      tip20Factory: getAddress(Addresses.tip20Factory),
      ...slice('network'),
    },
    contracts: {
      asset,
      earnShare,
      earnVault,
      earnFees,
      ...slice('contracts'),
      engine,
      creationEngine,
      venue,
      ...(periphery ? { periphery } : {}),
      ...(deploysEngine(profile) ? { factories: profile.factories } : {}),
    },
    expectedMetadata: {
      asset: assetMetadata!,
      earnShare: earnShareMetadata!,
      venue: venueMetadata!,
    },
    modes: {
      public: { availability: 'available' },
      ...slice('modes'),
    },
    capabilities: {
      ...profileCapabilities(profile),
      ...engineDefinitions[engineKind].capabilities,
      ...capabilities,
    },
    access,
    operations: {
      owner: getAddress(operator),
      deploymentOwner: profile.owner,
      revenueShareRecipient,
      factory: profile.factories.earn,
      ...optionalPeriphery(outputs),
      ...slice('operations'),
    },
    metadata: {
      sourceCommit: record.source.commit ?? 'unrecorded',
      sourceTreeDirty: record.source.treeDirty ?? true,
      generatedAt: record.generatedAt,
      deployedAtBlock: toHex(BigInt(record.deploymentBlock)),
      transactions: [
        ...new Set(Object.values(record.actions).flatMap((action) => action.transactions)),
      ],
    },
  }
}

export declare namespace profileStack {
  type Options = {
    client: Pick<PublicClient, 'getCode' | 'readContract'> &
      Client & {
        getChainId(): Promise<number>
        getBlock(options: { blockNumber: bigint }): Promise<{ hash: Hex | null }>
      }
    environment: { id: string; tempoRpcUrl: string; explorerUrl: string }
    profile: EarnDeploymentProfile
    record: EarnDeploymentRecord
  }
}

/**
 * Builds a deployed hosted profile's stack from its record and live reads on its chain: the hosted
 * environment's public RPC unless `values` configures `TEMPO_RPC_URL`. Unknown profiles require
 * independent identity passed directly or explicitly selected by `EARN_TRUSTED_DEPLOYMENT_IDENTITY`.
 */
export async function loadHostedProfileStack(
  profilePath: string,
  values: Readonly<Record<string, string | undefined>>,
  trustedIdentity?: ReviewedDeploymentIdentity,
) {
  const identityPath = values.EARN_TRUSTED_DEPLOYMENT_IDENTITY?.trim()
  const identity =
    trustedIdentity ??
    (identityPath ? loadReviewedDeploymentIdentity(resolveProfilePath(identityPath)) : undefined)
  const bundle = loadEarnProfileBundle(profilePath, identity)
  const { profile, record } = bundle
  const environment = hostedEnvironment(profile.chainId)
  if (!environment) {
    throw new Error(`Profile ${profile.id} targets chain ${profile.chainId}, not a hosted network`)
  }
  const tempo = rpcConfiguration('TEMPO', values, environment.rpcUrl)
  const client = createPublicClient({
    chain: configuredTempoNetworkChain({ ...environment, rpcUrl: tempo.url! }),
    transport: configuredRpcTransport(tempo),
  })
  const stack = await profileStack({
    client,
    environment: {
      id: environment.id,
      tempoRpcUrl: tempo.url!,
      explorerUrl: environment.explorerUrl,
    },
    profile,
    record,
  })
  return { bundle, environment, stack, tempo }
}

async function tokenMetadata(client: Pick<PublicClient, 'readContract'>, address: Address) {
  const [name, symbol, decimals] = await Promise.all([
    client.readContract({ address, abi: erc20Abi, functionName: 'name' }),
    client.readContract({ address, abi: erc20Abi, functionName: 'symbol' }),
    client.readContract({ address, abi: erc20Abi, functionName: 'decimals' }),
  ])
  return { name, symbol, decimals }
}
