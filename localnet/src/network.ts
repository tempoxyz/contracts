import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { Instance } from 'prool/testcontainers'
import { GenericContainer, Wait } from 'testcontainers'
import {
  createPublicClient,
  getAbiItem,
  getAddress,
  http,
  zeroAddress,
  type Address,
  type Hex,
} from 'viem'
import { zoneFactoryAbi } from '@tempoxyz/contracts/abis'
import { configuredTempoNetworkChain } from '@tempoxyz/contracts/deployments/operations'

import * as Config from './config.js'

const tip1091RuntimeSource = readFileSync(
  new URL('../fixtures/tip1091-runtime.json', import.meta.url),
  'utf8',
)
if (
  createHash('sha256').update(tip1091RuntimeSource).digest('hex') !==
  Config.runtimeLock.runtimeFixtureSha256
) {
  throw new Error('TIP-1091 runtime file does not match runtime-lock.json')
}
const tip1091Runtime = JSON.parse(tip1091RuntimeSource) as {
  sourceCommit: string
  solcVersion: string
  zoneMessenger: Hex
  zonePortal: Hex
  verifier: Hex
}
if (
  tip1091Runtime.sourceCommit !== Config.runtimeLock.sourceCommit ||
  tip1091Runtime.solcVersion !== Config.runtimeLock.solcVersion
) {
  throw new Error('TIP-1091 runtime provenance does not match runtime-lock.json')
}
for (const [name, runtime] of Object.entries({
  zoneMessenger: tip1091Runtime.zoneMessenger,
  zonePortal: tip1091Runtime.zonePortal,
  verifier: tip1091Runtime.verifier,
})) {
  if (!/^0x[0-9a-fA-F]+$/.test(runtime) || runtime.length % 2 !== 0) {
    throw new Error(`TIP-1091 ${name} runtime is not valid bytecode`)
  }
}

const zoneCreated = getAbiItem({ abi: zoneFactoryAbi, name: 'ZoneCreated' })

/** Docker identity for a run's containers, so an outside owner can find and remove them. */
export type Containers = {
  /** Applied to the L1 container; Prool does not expose Zone container labels. */
  labels?: Record<string, string> | undefined
  /** Container name stem: the L1 is `<name>.l1` and the Zone `<name>.zone`. */
  name?: string | undefined
}

export async function startL1(zoneFactoryOwner: Address, containers: Containers = {}) {
  const dumped = execFileSync(
    'docker',
    [
      'run',
      '--rm',
      '--platform',
      'linux/amd64',
      '--entrypoint',
      '/usr/local/bin/tempo',
      Config.image.l1,
      '-q',
      'dump-genesis',
      '--chain',
      'dev',
    ],
    { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 },
  )
  const genesis = JSON.parse(dumped) as {
    alloc: Record<
      string,
      {
        balance?: string
        code?: string
        nonce?: string
        storage?: Record<string, string>
      }
    >
  }
  genesis.alloc[Config.history.address] = {
    balance: '0x0',
    code: Config.history.code,
    nonce: '0x1',
  }
  genesis.alloc[Config.address.zoneFactory.toLowerCase()] = {
    balance: '0x0',
    code: '0xef',
    nonce: '0x1',
    storage: {
      ['0x'.padEnd(66, '0')]: `0x${'0'.repeat(16)}${zoneFactoryOwner
        .slice(2)
        .toLowerCase()}00000001`,
    },
  }
  genesis.alloc[Config.address.zonePortalImplementation.toLowerCase()] = {
    balance: '0x0',
    code: tip1091Runtime.zonePortal,
    nonce: '0x1',
  }
  genesis.alloc[Config.address.zoneMessenger.toLowerCase()] = {
    balance: '0x0',
    code: tip1091Runtime.zoneMessenger,
    nonce: '0x1',
  }
  genesis.alloc[Config.address.zoneVerifier.toLowerCase()] = {
    balance: '0x0',
    code: tip1091Runtime.verifier,
    nonce: '0x1',
  }

  const container = await new GenericContainer(Config.image.l1)
    .withPlatform('linux/amd64')
    .withExposedPorts(8545)
    .withExtraHosts([{ host: 'host.docker.internal', ipAddress: 'host-gateway' }])
    .withName(containers.name ? `${containers.name}.l1` : `tempo.${crypto.randomUUID()}`)
    .withLabels(containers.labels ?? {})
    .withCopyContentToContainer([
      { content: `${JSON.stringify(genesis)}\n`, target: '/tmp/tempo-dev-eip2935.json' },
    ])
    .withCommand([
      'node',
      '--authrpc.port',
      '8575',
      '--datadir',
      '/tmp/prool-tempo',
      '--dev',
      '--dev.block-time',
      '500ms',
      '--dev.finality-depth',
      '1',
      '--engine.disable-precompile-cache',
      '--engine.legacy-state-root',
      '--faucet.address',
      '0x20c0000000000000000000000000000000000000',
      '0x20c0000000000000000000000000000000000001',
      '0x20c0000000000000000000000000000000000002',
      '0x20c0000000000000000000000000000000000003',
      '--faucet.amount',
      '1000000000000',
      '--faucet.enabled',
      '--faucet.private-key',
      '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80',
      '--faucet.node-address',
      'http://localhost:8545',
      '--http.addr',
      '0.0.0.0',
      '--http.api',
      'all',
      '--http.corsdomain',
      '*',
      '--http.port',
      '8545',
      '--port',
      '8555',
      '--ws',
      '--ws.addr',
      '0.0.0.0',
      '--ws.api',
      'all',
      '--ws.port',
      '8545',
      '--chain',
      '/tmp/tempo-dev-eip2935.json',
    ])
    .withWaitStrategy(Wait.forLogMessage(/Received (block|new payload) from consensus engine/))
    .withStartupTimeout(300_000)
    .start()
  const port = container.getMappedPort(8545)
  const rpcUrl = `http://${container.getHost()}:${port}`
  try {
    const chainId = await createPublicClient({ transport: http(rpcUrl) }).getChainId()
    return { chainId, client: createClient(rpcUrl, chainId), container, port, rpcUrl }
  } catch (error) {
    await container.stop()
    throw error
  }
}

export type L1 = Awaited<ReturnType<typeof startL1>>

export async function resolveZoneSequencer(options: resolveZoneSequencer.Options) {
  const info = await options.client.readContract({
    address: Config.address.zoneFactory,
    abi: zoneFactoryAbi,
    functionName: 'zones',
    args: [options.zoneId],
  })
  if (getAddress(info.portal) !== getAddress(options.portal)) {
    throw new Error(
      `ZoneFactory Portal ${getAddress(info.portal)} does not match ${getAddress(options.portal)}`,
    )
  }
  const sequencer = info.sequencers[0]
  if (!sequencer) throw new Error(`Zone ${options.zoneId} has no active sequencer`)
  if (getAddress(sequencer) === zeroAddress) {
    throw new Error('Zone sequencer cannot be the zero address')
  }
  return getAddress(sequencer)
}

export declare namespace resolveZoneSequencer {
  type Options = {
    client: ReturnType<typeof createClient>
    portal: Address
    zoneId: number
  }
}

export async function startZone(options: startZone.Options) {
  const instance = Instance.tempoZone({
    ...(options.containers?.name ? { containerName: `${options.containers.name}.zone` } : {}),
    dev: { key: options.privateKey, token: options.initialToken },
    image: Config.image.zone,
    l1: { rpcUrl: `ws://host.docker.internal:${options.l1Port}` },
    nodeArgs: ['--zone.batch-interval-blocks', '10', '--withdrawal-poll-interval-secs', '1'],
    startupTimeout: 300_000,
  })
  try {
    await instance.start()
    const publicRpcUrl = `http://${instance.host}:${instance.port}`
    const privateRpc = instance._internal.privateRpc
    if (!privateRpc) throw new Error('Prool started without exposing the private Zone RPC endpoint')
    const rpcUrl = `http://${privateRpc.host}:${privateRpc.port}`
    const factory = Config.address.zoneFactory
    const factoryCode = await options.client.getCode({ address: factory })
    if (!factoryCode || factoryCode === '0x') {
      throw new Error(`Could not find the canonical ZoneFactory at ${factory}`)
    }

    const [created, chainId] = await Promise.all([
      options.client.getLogs({ address: factory, event: zoneCreated, fromBlock: 0n }),
      createPublicClient({ transport: http(publicRpcUrl) }).getChainId(),
    ])
    const event = created.find((log) => log.args.zoneId === 1)
    if (!event?.args.portal) throw new Error('Prool did not emit the expected ZoneCreated event')
    const portal = getAddress(event.args.portal)

    return {
      id: 1,
      chainId,
      container: instance,
      factory,
      messenger: Config.address.zoneMessenger,
      portal,
      publicRpcUrl,
      rpcUrl,
    }
  } catch (error) {
    await instance.stop().catch(() => undefined)
    throw error
  }
}

export declare namespace startZone {
  type Options = {
    client: ReturnType<typeof createClient>
    containers?: Containers | undefined
    initialToken: Address
    l1Port: number
    privateKey: Hex
  }
}

export type Zone = Awaited<ReturnType<typeof startZone>>

export function createClient(rpcUrl: string, chainId: number) {
  return createPublicClient({
    chain: chain(chainId, rpcUrl),
    transport: http(rpcUrl, { timeout: 60_000 }),
  })
}

export function chain(chainId: number, rpcUrl: string) {
  return configuredTempoNetworkChain({ id: 'Local Tempo', chainId, rpcUrl })
}

/** Waits for the Zone to mirror a token the Portal just enabled. */
export async function waitForToken(rpcUrl: string, token: Address) {
  const client = createPublicClient({ transport: http(rpcUrl) })
  const deadline = Date.now() + 90_000
  while (Date.now() < deadline) {
    // The Zone may briefly reject reads while consuming the L1 enablement block.
    const code = await client.getCode({ address: token }).catch(() => undefined)
    if (code && code !== '0x') return
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250))
  }
  throw new Error(`Zone did not mirror the enabled token ${token} within 90 seconds`)
}
