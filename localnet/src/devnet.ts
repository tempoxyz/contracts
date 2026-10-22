import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { resolve } from 'node:path'
import { getAddress, isAddress, type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import { zonePortalAbi } from '@tempoxyz/earn/abis'
import { hostedEnvironment } from '@tempoxyz/earn/deployments'
import { envPrivateKey } from '@tempoxyz/earn/deployments/node'
import { inspectZone, zonePortalRole } from '@tempoxyz/earn/tempo/zone'

import * as Config from './config.js'
import * as Deployment from './deployment.js'
import { defaultEngineKind } from './engines/index.js'
import type * as Environment from './environment.js'
import * as Network from './network.js'

/** The files `devnet:deploy --out <dir>` writes; tempoxyz/workflows reads each by name. */
export const outputFiles = [
  'earn-input-token',
  'earn-funding-helper',
  'earn-token',
  'earn-vault',
  'earn-router',
  'earn-source-revision',
] as const

/** The existing chains a devnet run targets. */
export type Topology = {
  chainId: number
  rpcUrl: string
  zoneId: number
  zoneChainId: number
  zoneRpcUrl: string
  zonePortal: Address
}

/**
 * Deploys the default engine's fixture and profile onto an existing L1 and Zone through the same
 * `createBase`/`create` path local runs use. Beyond enabling its fixture tokens and registering its
 * router, it never starts or stops either chain, changes access modes, or admits accounts.
 */
export async function deploy(options: deploy.Options): Promise<Deployment.State> {
  if (hostedEnvironment(options.chainId)) {
    throw new Error(`Devnet fixtures refuse hosted chain ${options.chainId}`)
  }
  const client = Network.createClient(options.rpcUrl, options.chainId)
  const liveChain = await client.getChainId()
  if (liveChain !== options.chainId) {
    throw new Error(`L1 RPC serves chain ${liveChain}, expected ${options.chainId}`)
  }
  const zone = await inspectZone({
    id: options.zoneId,
    chainId: options.zoneChainId,
    l1Client: client,
    zoneClient: Network.createClient(options.zoneRpcUrl, options.zoneChainId),
  })
  if (getAddress(options.zonePortal) !== zone.portal) {
    throw new Error(`ZONE_PORTAL_ADDRESS is not the Factory's Zone ${zone.id} Portal`)
  }
  const portal = { address: zone.portal, abi: zonePortalAbi } as const
  const [admin, accessEnforced] = await Promise.all([
    client.readContract({ ...portal, functionName: 'admin' }),
    client.readContract({ ...portal, functionName: 'isAccessEnforced' }),
  ])
  if (getAddress(admin) !== privateKeyToAccount(options.privateKeys.zoneAdministrator).address) {
    throw new Error('ZONE_ADMIN_PRIVATE_KEY does not administer the devnet Portal')
  }
  if (accessEnforced) {
    const admitted = await Promise.all(
      options.portalAccounts.map((address) =>
        client.readContract({
          ...portal,
          functionName: 'hasRole',
          args: [address, zonePortalRole.account],
        }),
      ),
    )
    const missing = options.portalAccounts.filter((_, index) => !admitted[index])
    if (missing.length > 0) {
      throw new Error(
        `The devnet Portal enforces access; admit ${missing.join(', ')} before the run`,
      )
    }
  }

  mkdirSync(Config.directory, { recursive: true })
  const directory = mkdtempSync(resolve(Config.directory, 'devnet-'))
  const deployer = privateKeyToAccount(options.privateKeys.deployer)
  const common = {
    account: deployer.address,
    broadcastDirectory: resolve(directory, 'broadcast'),
    chainId: options.chainId,
    client,
    privateKey: options.privateKeys.deployer,
    rpcUrl: options.rpcUrl,
  }
  try {
    const base = await Deployment.createBase({ ...common, engineKind: defaultEngineKind })
    const { state } = await Deployment.create({
      ...common,
      base,
      accessAdministrator: options.accessAdministrator,
      revenueShareRecipient: options.user,
      zone: { ...zone, publicRpcUrl: options.zoneRpcUrl },
      zonePrivateKey: options.privateKeys.zoneAdministrator,
    })
    return state
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

export declare namespace deploy {
  type Options = Topology & {
    privateKeys: { deployer: Hex; zoneAdministrator: Hex }
    /** Eligible under the stack's access policy and its revenue-share recipient. */
    user: Address
    accessAdministrator: Address
    /** Accounts that must already hold the Portal `Account` role when the Portal enforces access. */
    portalAccounts: readonly Address[]
  }
}

/** Deploys a fresh stack with `deploy`, then hands it and the E2E actors to `ready`. */
export async function run<Result>(options: run.Options<Result>) {
  const accounts = Object.fromEntries(
    Object.entries(options.privateKeys).map(([role, privateKey]) => [
      role,
      { address: privateKeyToAccount(privateKey).address, privateKey },
    ]),
  ) as Environment.State['accounts']
  const { deployer, user, outsider, accessAdministrator } = accounts
  const deployment = await deploy({
    ...options,
    user: user.address,
    accessAdministrator: accessAdministrator.address,
    portalAccounts: [deployer, user, outsider, accessAdministrator].map(({ address }) => address),
  })
  return await options.ready({
    accounts,
    deployment,
    l1: { rpcUrl: options.rpcUrl, image: 'external' },
    zone: { rpcUrl: options.zoneRpcUrl, publicRpcUrl: options.zoneRpcUrl, image: 'external' },
  })
}

export declare namespace run {
  type Options<Result> = Topology & {
    privateKeys: { [Role in keyof Environment.State['accounts']]: Hex }
    ready(state: Environment.State): Promise<Result>
  }
}

/**
 * Reads the topology, deployer, and Zone admin key the caller injects; nothing falls back to hosted
 * defaults. `privateKey` reads any further signer.
 */
export function configuration(values: NodeJS.ProcessEnv) {
  const zonePortal = required(values, 'ZONE_PORTAL_ADDRESS')
  if (!isAddress(zonePortal)) throw new Error('ZONE_PORTAL_ADDRESS must be an address')
  return {
    chainId: integer(values, 'EXPECTED_L1_CHAIN_ID'),
    rpcUrl: required(values, 'TEMPO_RPC_URL'),
    zoneId: integer(values, 'ZONE_ID'),
    zoneChainId: integer(values, 'ZONE_CHAIN_ID'),
    zoneRpcUrl: required(values, 'ZONE_RPC_URL'),
    zonePortal,
    privateKeys: {
      deployer: privateKey(values, 'DEPLOYER_PRIVATE_KEY'),
      zoneAdministrator: privateKey(values, 'ZONE_ADMIN_PRIVATE_KEY'),
    },
  } satisfies Topology & Pick<deploy.Options, 'privateKeys'>
}

export function privateKey(values: NodeJS.ProcessEnv, name: string): Hex {
  return envPrivateKey(values, name, { required: true })
}

function required(values: NodeJS.ProcessEnv, name: string) {
  const value = values[name]?.trim()
  if (!value) throw new Error(`${name} is required`)
  return value
}

function integer(values: NodeJS.ProcessEnv, name: string) {
  const value = required(values, name)
  if (!/^[1-9]\d*$/.test(value) || !Number.isSafeInteger(Number(value))) {
    throw new Error(`${name} must be a positive integer`)
  }
  return Number(value)
}
