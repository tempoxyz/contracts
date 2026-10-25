// Adapted from Earn's `localnet/src/network.ts` and `config.ts`: a disposable Tempo L1 whose genesis
// carries the TIP-1091 Zone runtimes, and a Tempo Zone started by prool against it. The images and
// runtimes are the ones Earn's localnet pins (`localnet/fixtures/`), so both run the same chain.
import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { Instance } from 'prool/testcontainers'
import { GenericContainer, Wait } from 'testcontainers'
import {
  createPublicClient,
  defineChain,
  getAddress,
  http,
  parseAbiItem,
  type Address,
  type Hex,
} from 'viem'
import { tempoModerato } from 'viem/tempo/chains'

type RuntimeLock = {
  l1Image: string
  zoneImage: string
  runtimeFixtureSha256: string
  sourceCommit: string
  solcVersion: string
}

const lock = JSON.parse(
  readFileSync(
    new URL('../../../../localnet/fixtures/runtime-lock.json', import.meta.url),
    'utf8',
  ),
) as RuntimeLock
const runtimeSource = readFileSync(
  new URL('../../../../localnet/fixtures/tip1091-runtime.json', import.meta.url),
  'utf8',
)
if (createHash('sha256').update(runtimeSource).digest('hex') !== lock.runtimeFixtureSha256) {
  throw new Error('TIP-1091 runtime fixture does not match runtime-lock.json')
}
const runtime = JSON.parse(runtimeSource) as {
  zoneMessenger: Hex
  zonePortal: Hex
  verifier: Hex
}

export const image = { l1: lock.l1Image, zone: lock.zoneImage }

/** Zone blocks between empty withdrawal batches, set lower than the node's 120 to keep runs short. */
export const zoneBatchIntervalBlocks = 10

export const address = {
  pathUsd: getAddress('0x20C0000000000000000000000000000000000000'),
  zoneFactory: getAddress('0x5aF2000000000000000000000000000000000000'),
  zoneMessenger: getAddress('0x5A4d000000000000000000000000000000000000'),
  zonePortalImplementation: getAddress('0x5AD1000000000000000000000000000000000000'),
  zoneVerifier: getAddress('0x5A56000000000000000000000000000000000000'),
  zoneOutbox: getAddress('0x1c00000000000000000000000000000000000002'),
}

const history = {
  address: '0x0000f90827f1c53a10cb7a02335b175320002935',
  code: '0x3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500',
}

const zoneCreated = parseAbiItem(
  'event ZoneCreated(uint32 indexed zoneId, address indexed portal, address initialToken, bool accessMode, bool gatewayMode, address admin, address[] sequencers, uint8 threshold, address verifier)',
)

export async function startL1(zoneFactoryOwner: Address) {
  const dumped = execFileSync(
    'docker',
    [
      'run',
      '--rm',
      '--platform',
      'linux/amd64',
      '--entrypoint',
      '/usr/local/bin/tempo',
      image.l1,
      '-q',
      'dump-genesis',
      '--chain',
      'dev',
    ],
    { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 },
  )
  const genesis = JSON.parse(dumped) as {
    alloc: Record<string, { balance?: string; code?: string; nonce?: string; storage?: Record<string, string> }>
  }
  genesis.alloc[history.address] = { balance: '0x0', code: history.code, nonce: '0x1' }
  genesis.alloc[address.zoneFactory.toLowerCase()] = {
    balance: '0x0',
    code: '0xef',
    nonce: '0x1',
    storage: {
      ['0x'.padEnd(66, '0')]: `0x${'0'.repeat(16)}${zoneFactoryOwner.slice(2).toLowerCase()}00000001`,
    },
  }
  genesis.alloc[address.zonePortalImplementation.toLowerCase()] = {
    balance: '0x0',
    code: runtime.zonePortal,
    nonce: '0x1',
  }
  genesis.alloc[address.zoneMessenger.toLowerCase()] = {
    balance: '0x0',
    code: runtime.zoneMessenger,
    nonce: '0x1',
  }
  genesis.alloc[address.zoneVerifier.toLowerCase()] = {
    balance: '0x0',
    code: runtime.verifier,
    nonce: '0x1',
  }

  const container = await new GenericContainer(image.l1)
    .withPlatform('linux/amd64')
    .withExposedPorts(8545)
    .withExtraHosts([{ host: 'host.docker.internal', ipAddress: 'host-gateway' }])
    .withName(`spend-zone-e2e.${crypto.randomUUID()}.l1`)
    .withCopyContentToContainer([
      { content: `${JSON.stringify(genesis)}\n`, target: '/tmp/tempo-dev.json' },
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
      '/tmp/tempo-dev.json',
    ])
    .withWaitStrategy(Wait.forLogMessage(/Received (block|new payload) from consensus engine/))
    .withStartupTimeout(300_000)
    .start()
  const port = container.getMappedPort(8545)
  const rpcUrl = `http://${container.getHost()}:${port}`
  const chainId = await createPublicClient({ transport: http(rpcUrl) }).getChainId()
  return { chainId, container, port, rpcUrl }
}

export type L1 = Awaited<ReturnType<typeof startL1>>

export async function startZone(options: {
  l1: L1
  initialToken: Address
  privateKey: Hex
}) {
  const instance = Instance.tempoZone({
    dev: { key: options.privateKey, token: options.initialToken },
    image: image.zone,
    l1: { rpcUrl: `ws://host.docker.internal:${options.l1.port}` },
    nodeArgs: [
      '--zone.batch-interval-blocks',
      String(zoneBatchIntervalBlocks),
      '--withdrawal-poll-interval-secs',
      '1',
    ],
    startupTimeout: 300_000,
  })
  await instance.start()
  try {
    const publicRpcUrl = `http://${instance.host}:${instance.port}`
    const privateRpc = instance._internal.privateRpc
    if (!privateRpc) throw new Error('prool did not expose the private Zone RPC')
    const rpcUrl = `http://${privateRpc.host}:${privateRpc.port}`
    const l1Client = createPublicClient({ transport: http(options.l1.rpcUrl) })
    const [created, chainId] = await Promise.all([
      l1Client.getLogs({ address: address.zoneFactory, event: zoneCreated, fromBlock: 0n }),
      createPublicClient({ transport: http(publicRpcUrl) }).getChainId(),
    ])
    const event = created.find((log) => log.args.zoneId === 1)
    if (!event?.args.portal) throw new Error('prool did not create Zone 1')
    return {
      chainId,
      container: instance,
      zoneId: 1,
      portal: getAddress(event.args.portal),
      accessMode: event.args.accessMode ?? false,
      gatewayMode: event.args.gatewayMode ?? false,
      publicRpcUrl,
      rpcUrl,
    }
  } catch (error) {
    await instance.stop().catch(() => undefined)
    throw error
  }
}

export type Zone = Awaited<ReturnType<typeof startZone>>

export function chain(chainId: number, rpcUrl: string, name = 'Local Tempo') {
  return defineChain({
    ...tempoModerato,
    id: chainId,
    name,
    rpcUrls: { default: { http: [rpcUrl] } },
  })
}
