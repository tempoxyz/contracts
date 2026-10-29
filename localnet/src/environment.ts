import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { resolve } from 'node:path'
import { engineDefinitions } from '@tempoxyz/contracts/deployments'
import type { EarnDeploymentProfile } from '@tempoxyz/contracts/deployments/operations'
import { http, type Address, type Hex } from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { createClient as createTempoClient } from 'viem/tempo'

import * as Config from './config.js'
import * as Deployment from './deployment.js'
import { defaultEngineKind } from './engines/index.js'
import * as Log from './log.js'
import * as Network from './network.js'

/** A fresh, funded key of one run. */
export type Account = { address: Address; privateKey: Hex }

export type State = {
  accounts: {
    accessAdministrator: Account
    deployer: Account
    user: Account
    outsider: Account
    /** Zone administrator: enables Portal tokens and manages gateway access. */
    zoneAdministrator: Account
  }
  deployment: Deployment.State
  l1: {
    image: string
    rpcUrl: string
  }
  zone: {
    image: string
    publicRpcUrl: string
    rpcUrl: string
  }
}

export async function run<Result>(options: run.Options<Result>) {
  const engineKind = options.earnProfile?.engine.kind ?? options.engineKind ?? defaultEngineKind
  if (options.engineKind && options.engineKind !== engineKind) {
    throw new Error(`Profile ${options.earnProfile?.id} needs the ${engineKind} local variant`)
  }
  if (options.earnProfile && options.access) {
    throw new Error('A supplied profile defines its own access; omit the access option')
  }
  mkdirSync(Config.directory, { recursive: true })
  const runDirectory = mkdtempSync(resolve(Config.directory, 'run-'))
  const broadcastDirectory = resolve(runDirectory, 'broadcast')
  const accounts = {
    accessAdministrator: account(),
    deployer: account(),
    user: account(),
    outsider: account(),
    zoneAdministrator: account(),
  } satisfies State['accounts']
  const { accessAdministrator, deployer, user, outsider, zoneAdministrator } = accounts
  // Owns an engine its kind provisions apart from the deployer until the lifecycle binds it.
  const engineOwner = account()
  let l1: Network.L1 | undefined
  let zone: Network.Zone | undefined

  try {
    console.log('\nTempo Earn · Local Zone Environment\n')
    l1 = await Network.startL1(zoneAdministrator.address, options.containers)
    Log.setup(1, 'Tempo L1 running', [
      `├─ RPC · ${l1.rpcUrl}`,
      `├─ Chain · ${l1.chainId}`,
      `└─ Image · ${Log.image(Config.image.l1)}`,
    ])

    const fundingClient = createTempoClient({
      chain: Network.chain(l1.chainId, l1.rpcUrl),
      transport: http(l1.rpcUrl, { timeout: 60_000 }),
    })
    await Promise.all(
      [deployer, accessAdministrator, user, outsider, engineOwner].map(({ address }) =>
        fundingClient.faucet.fundSync({ account: address, timeout: 180_000 }),
      ),
    )
    Log.setup(2, 'Ephemeral accounts funded', [
      `├─ Deployer · ${Log.address(deployer.address)}`,
      `├─ Access administrator · ${Log.address(accessAdministrator.address)}`,
      `├─ E2E user · ${Log.address(user.address)}`,
      `└─ Ineligible user · ${Log.address(outsider.address)}`,
    ])

    const base = await Deployment.createBase({
      account: deployer.address,
      broadcastDirectory,
      chainId: l1.chainId,
      client: l1.client,
      privateKey: deployer.privateKey,
      rpcUrl: l1.rpcUrl,
      engineKind,
      engineOwnerPrivateKey: engineOwner.privateKey,
      sameAssetRoute: options.sameAssetRoute,
    })
    Log.setup(3, 'Local fixtures and factory release deployed', [
      `├─ Stablecoin fixture · ${Log.address(base.stablecoins.funder)}`,
      `│  ├─ Base asset · ${Log.address(base.baseAsset)}`,
      `│  └─ Alternate asset · ${Log.address(base.stablecoins.alternateAsset)}`,
      `├─ Router PropAMM pool · ${Log.address(base.routerPool.pool)}`,
      `│  └─ Inventory · ${Deployment.routerPoolInventory / 10n ** 6n} of each pair token, open`,
      `├─ ${engineDefinitions[engineKind].label} fixtures · ${Log.address(base.engine ?? base.vault)}`,
      ...(base.sameAssetVault
        ? [`├─ PATHUSD ERC-4626 vault · ${Log.address(base.sameAssetVault)}`]
        : []),
      `├─ EarnFactory · ${Log.address(base.factory)}`,
      ...base.engineFactories.map(
        ({ factory, address }) => `├─ ${factory.contract} · ${Log.address(address)}`,
      ),
      `└─ Transactions · ${base.receipts.length}`,
    ])

    zone = await Network.startZone({
      containers: options.containers,
      client: l1.client,
      initialToken: base.baseAsset,
      l1Port: l1.port,
      privateKey: zoneAdministrator.privateKey,
    })
    Log.setup(4, 'Tempo Zone running', [
      '├─ Zone · 1',
      `├─ Chain · ${zone.chainId}`,
      '├─ RPC',
      `│  ├─ Public · ${zone.publicRpcUrl}`,
      `│  └─ Private · ${zone.rpcUrl}`,
      '├─ Contracts',
      `│  ├─ ZoneFactory · ${Log.address(zone.factory)}`,
      `│  ├─ Portal · ${Log.address(zone.portal)}`,
      `│  └─ Messenger · ${Log.address(zone.messenger)}`,
      `└─ Image · ${Log.image(Config.image.zone)}`,
    ])

    const result = await Deployment.create({
      access: options.access,
      account: deployer.address,
      accessAdministrator: accessAdministrator.address,
      base,
      broadcastDirectory,
      chainId: l1.chainId,
      client: l1.client,
      earnProfile: options.earnProfile,
      engineOwnerPrivateKey: engineOwner.privateKey,
      privateKey: deployer.privateKey,
      rpcUrl: l1.rpcUrl,
      revenueShareRecipient: user.address,
      zone,
      zonePrivateKey: zoneAdministrator.privateKey,
    })
    const deployment = result.state
    Log.setup(5, 'Earn stacks deployed, verified, and ready', [
      ...result.profiles.flatMap(({ profile, outputs, actions }) => [
        `├─ Profile ${profile.id} · EarnShare ${Log.address(outputs.earnShare!)}`,
        ...Object.entries(actions).map(
          ([id, action], index, all) =>
            `│  ${index === all.length - 1 ? '└─' : '├─'} ✓ ${id} · ${action.transactions.length} tx`,
        ),
      ]),
      `└─ Access · ${deployment.access.kind} · ${result.accessTransactions} policy tx`,
    ])

    const environment = {
      accounts,
      deployment,
      l1: { image: Config.image.l1, rpcUrl: l1.rpcUrl },
      zone: {
        image: Config.image.zone,
        publicRpcUrl: zone.publicRpcUrl,
        rpcUrl: zone.rpcUrl,
      },
    } satisfies State
    Log.setup(6, 'Local environment ready', [`└─ Consumer · ${options.consumer}`])
    return await options.ready(environment)
  } finally {
    try {
      await Promise.all([zone?.container.stop(), l1?.container.stop()])
    } finally {
      rmSync(runDirectory, { force: true, recursive: true })
    }
  }
}

export declare namespace run {
  type Options<Result> = {
    /** Variant access when no profile is supplied; protected by default. */
    access?: Deployment.AccessKind | undefined
    consumer: string
    /**
     * An authored deployment profile to deploy instead of the variant default. Its chain, venue,
     * TIP-403 policy, and Zone router dependencies are replaced with local equivalents; its core,
     * principals, rewards, and engine kind are deployed as authored.
     */
    earnProfile?: EarnDeploymentProfile | undefined
    engineKind?: Deployment.EngineKind | undefined
    /** Names and labels the L1 and Zone containers for an outside owner. */
    containers?: Network.Containers | undefined
    /**
     * Also deploys a PATHUSD Earn stack with a pool-less same-asset router, exposed as
     * `deployment.sameAssetRoute`. Off by default.
     */
    sameAssetRoute?: boolean | undefined
    ready(environment: State): Promise<Result>
  }
}

function account(): Account {
  const privateKey = generatePrivateKey()
  return { address: privateKeyToAccount(privateKey).address, privateKey }
}
