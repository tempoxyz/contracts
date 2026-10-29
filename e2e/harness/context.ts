import { configuredTempoChain, type EarnStack } from '@tempoxyz/contracts/deployments/operations'
import { configuredRpcTransport } from '@tempoxyz/contracts/deployments/node'
import { http, zeroAddress, type Account, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { createClient, Store, Transport } from 'viem/tempo'
import type { StablecoinFixture } from '../fixtures/profile-fixture.js'
import { configuredZoneChain, type E2eEnvironmentDefinition } from './environments.js'
import { createTimings } from './support/timings.js'

/** A stack E2E runs against, with the disposable stablecoin fixture it was provisioned with, if any. */
export type E2eStack = EarnStack & { stablecoinFixture?: StablecoinFixture | undefined }

export function createDeploymentPublicClient(
  deployment: Pick<EarnStack, 'network'>,
  options: {
    headers?: Record<string, string> | undefined
    environment?: E2eEnvironmentDefinition | undefined
  } = {},
) {
  return createClient({
    chain: configuredTempoChain(deployment),
    transport: configuredRpcTransport({ url: deployment.network.rpcUrl, headers: options.headers }),
    ...(options.environment?.provider === 'local'
      ? { pollingInterval: options.environment.pollingIntervalMs }
      : {}),
  })
}

export type DeploymentPublicClient = ReturnType<typeof createDeploymentPublicClient>

/** Matches the app Worker's trusted API-key path; direct RPCs retain caller-token isolation. */
function createZoneTransport(url: string, options: Transport.HttpConfig) {
  const headers = new Headers(options.fetchOptions?.headers)
  if (!headers.get('tempo-api-key')?.trim()) return Transport.http(url, options)
  const { store: _store, ...config } = options
  return http(url, config)
}

type E2eProgressStage = 'INPUT' | 'ZONE' | 'L1' | 'RETURN' | 'CHECK' | 'CLEANUP'

function createE2eProgress() {
  let muted = false
  return {
    step(stage: E2eProgressStage, message: string, reference?: string) {
      if (muted) return
      console.log(`  ${stage.padEnd(8)} ${message}${reference ? ` · ${reference}` : ''}`)
    },
    async withMuted<T>(action: () => T | Promise<T>) {
      const previous = muted
      muted = true
      try {
        return await action()
      } finally {
        muted = previous
      }
    },
  }
}

/** The signing identities every E2E run has: user, operator, outsider, and access administrator. */
export const e2eActors = ['user', 'operator', 'outsider', 'accessAdministrator'] as const
export type E2eActor = (typeof e2eActors)[number]

export function createE2eContext(options: createE2eContext.Options) {
  const { deployment, environment } = options
  const pollingInterval = environment.pollingIntervalMs
  const localPolling = environment.provider === 'local' ? { pollingInterval } : {}
  const fixture = deployment.stablecoinFixture
  const tempoChain = configuredTempoChain(deployment)
  const tempoTransport = configuredRpcTransport({
    url: deployment.network.rpcUrl,
    headers: options.rpcHeaders?.tempo,
  })
  const zone = deployment.network.zone
  const zoneChain = zone ? configuredZoneChain(deployment) : undefined
  const zoneHeaders = options.rpcHeaders?.zone
  // Each Zone actor reads through the configured Zone RPC and submits through the public RPC when the
  // environment separates them; both share the actor's authorization store.
  const zoneClients = (account: Account) => {
    if (!zone || !zoneChain) return undefined
    const store = Store.memory()
    const client = createClient({
      account,
      chain: zoneChain,
      transport: createZoneTransport(zone.rpcUrl, {
        fetchOptions: { headers: zoneHeaders },
        timeout: 10_000,
        store,
      }),
      ...localPolling,
    })
    const submission = options.zoneSubmissionRpcUrl
      ? createClient({
          account,
          chain: zoneChain,
          transport: createZoneTransport(options.zoneSubmissionRpcUrl, {
            timeout: 10_000,
            store,
          }),
          ...localPolling,
        })
      : client
    return { client, submission, store }
  }
  const actor = (actorId: E2eActor) => {
    const account = privateKeyToAccount(options.privateKeys[actorId])
    return {
      account,
      wallet: createClient({
        account,
        chain: tempoChain,
        transport: tempoTransport,
        ...localPolling,
      }),
      zone: zoneClients(account),
    }
  }
  const actors = Object.fromEntries(e2eActors.map((id) => [id, actor(id)])) as Record<
    E2eActor,
    ReturnType<typeof actor>
  >
  const policyZoneClient =
    zone && zoneChain
      ? createClient({
          account: zeroAddress,
          chain: zoneChain,
          transport: http(options.zoneSubmissionRpcUrl ?? zone.rpcUrl, {
            fetchOptions: { headers: zoneHeaders },
            timeout: 10_000,
          }),
          ...localPolling,
        })
      : undefined
  return {
    deployment,
    deploymentId: deployment.id,
    environmentId: environment.id,
    provider: environment.provider,
    contracts: deployment.contracts,
    operations: deployment.operations,
    // A public deployment has no fixture: its own asset is the base, and only Zone cases use the alternate.
    assets: {
      base: fixture?.baseAsset ?? deployment.contracts.asset,
      alternate: fixture?.alternateAsset ?? deployment.contracts.asset,
    },
    funding: fixture,
    actors,
    user: actors.user.account,
    operator: actors.operator.account,
    outsider: actors.outsider.account,
    accessAdministrator: actors.accessAdministrator.account,
    l1Public: createDeploymentPublicClient(deployment, {
      environment,
      headers: options.rpcHeaders?.tempo,
    }),
    policyZoneClient,
    pollingInterval,
    progress: createE2eProgress(),
    /** Phase timings the shared actions record, reported per case and per benchmark sample. */
    timings: createTimings(),
    engineKind: deployment.engineKind,
    engineFixtures: options.engineFixtures ?? {},
  }
}

export type E2eContext = ReturnType<typeof createE2eContext>
export type E2eWallet = E2eContext['actors'][E2eActor]['wallet']

/**
 * The named engine fixtures a case or engine needs, or undefined when the stack lacks any of them.
 * Local stacks and hosted profiles with a fixture record carry engine fixtures; the engine or
 * module that owns them names what it reads.
 */
export function engineFixtures<const Name extends string>(
  context: Pick<E2eContext, 'engineFixtures'>,
  names: readonly Name[],
): Record<Name, Address> | undefined {
  if (names.some((name) => !context.engineFixtures[name])) return undefined
  return Object.fromEntries(names.map((name) => [name, context.engineFixtures[name]!])) as Record<
    Name,
    Address
  >
}

type ZoneActorClients = NonNullable<E2eContext['actors'][E2eActor]['zone']>

export type E2eZoneContext = E2eContext & {
  deployment: E2eStack & {
    network: EarnStack['network'] & { zone: NonNullable<EarnStack['network']['zone']> }
  }
  contracts: E2eContext['contracts'] & { earnRouter: `0x${string}` }
  actors: Record<E2eActor, E2eContext['actors'][E2eActor] & { zone: ZoneActorClients }>
  policyZoneClient: NonNullable<E2eContext['policyZoneClient']>
}

/** Narrows a generic E2E context to one with an attached Zone target, its router, and clients. */
export function requireE2eZone(context: E2eContext): asserts context is E2eZoneContext {
  if (!context.deployment.network.zone || !context.actors.user.zone) {
    throw new Error(`E2E deployment ${context.deploymentId} has no Zone target`)
  }
  if (!context.contracts.earnRouter) {
    throw new Error(`E2E deployment ${context.deploymentId} has no EarnRouter`)
  }
}

export declare namespace createE2eContext {
  type Options = {
    deployment: E2eStack
    environment: E2eEnvironmentDefinition
    privateKeys: Record<E2eActor, Hex>
    rpcHeaders?: {
      tempo?: Record<string, string> | undefined
      zone?: Record<string, string> | undefined
    }
    zoneSubmissionRpcUrl?: string
    /** Engine-specific test fixtures by name; see `engineFixtures`. */
    engineFixtures?: Readonly<Record<string, Address>> | undefined
  }
}
