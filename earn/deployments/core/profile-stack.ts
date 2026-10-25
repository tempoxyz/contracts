import {
  createPublicClient,
  erc20Abi,
  getAddress,
  toHex,
  type Address,
  type Client,
  type PublicClient,
} from 'viem'
import { Abis, Addresses } from 'viem/tempo'

import { configuredRpcTransport, rpcConfiguration } from '../chain/runtime.js'
import { configuredTempoNetworkChain, hostedEnvironment } from '../chain/tempo.js'
import { capabilityModules } from '../modules/index.js'
import { requiredOutput, type StackSlice } from '../modules/module.js'
import { engineDefinitions, readEngineVenue } from '../modules/engines/index.js'
import { loadEarnProfileBundle } from './bundle.js'
import { optionalPeriphery } from './components.js'
import { deploysEngine, profileCapabilities, type EarnDeploymentProfile } from './profile.js'
import type { EarnDeploymentRecord } from './record.js'
import type { EarnStack } from './stack.js'

/**
 * Builds the stack of one deployed profile from its generated record and live reads. Nothing is
 * inherited from a checked-in manifest: token metadata, venue, engine periphery, operator, and
 * access administrator are read from the chain the record targets. A test fixture is the caller's
 * to attach.
 */
export async function profileStack(options: profileStack.Options): Promise<EarnStack> {
  const { client, environment, profile, record } = options
  const outputs = record.addresses as Record<string, Address>
  const asset = requiredOutput(outputs, 'asset')
  const earnShare = requiredOutput(outputs, 'earnShare')
  const earnVault = requiredOutput(outputs, 'earnVault')
  const earnFees = requiredOutput(outputs, 'earnFees')
  const engine = requiredOutput(outputs, 'engine')
  const engineKind = profile.engine.kind
  const [operator, periphery, slices] = await Promise.all([
    // The current transferable operator, not the deployment owner the record names.
    client.readContract({ address: earnVault, abi: Abis.earnVault, functionName: 'operator' }),
    engineDefinitions[engineKind].readPeriphery?.(client, engine),
    Promise.all(capabilityModules.map((module) => module.stack?.(options))),
  ])
  // Each capability's fields, merged in module order into their places in the stack.
  const slice = <Key extends keyof StackSlice>(key: Key) =>
    Object.assign({}, ...slices.map((entry) => entry?.[key])) as NonNullable<StackSlice[Key]>
  const access = slices.find((entry) => entry?.access)?.access
  if (!access) throw new Error(`Profile ${profile.id} has no access capability`)
  const venue =
    'venue' in profile.engine
      ? getAddress(profile.engine.venue)
      : await readEngineVenue(client, engineKind, engine)
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
    capabilities: profileCapabilities(profile),
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
    client: Pick<PublicClient, 'getCode' | 'readContract'> & Client
    environment: { id: string; tempoRpcUrl: string; explorerUrl: string }
    profile: EarnDeploymentProfile
    record: EarnDeploymentRecord
  }
}

/**
 * Builds a deployed hosted profile's stack from its record and live reads on its chain: the hosted
 * environment's public RPC unless `values` configures `TEMPO_RPC_URL`.
 */
export async function loadHostedProfileStack(
  profilePath: string,
  values: Readonly<Record<string, string | undefined>>,
) {
  const bundle = loadEarnProfileBundle(profilePath)
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
