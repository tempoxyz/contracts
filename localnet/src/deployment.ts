import { mkdirSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'
import { isDeepStrictEqual } from 'node:util'

import {
  accessMembers,
  engineFactories,
  factoryReleaseStep,
  optionalPeriphery,
  planEarnDeployment,
  serializeWhitelistPolicy,
  type EarnDeploymentProfile,
} from '@tempoxyz/contracts/deployments/operations'
import {
  authoredProfile,
  discoverOutputs,
  preflightEarnDeployment,
  prepareLifecycleStep,
  reconcileEarnProfileActions,
  recordAuthorityAction,
  verifyEarnDeploymentState,
} from '@tempoxyz/contracts/deployments/node'
import {
  encodeFunctionData,
  getAddress,
  http,
  isAddressEqual,
  keccak256,
  stringToHex,
  type Address,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { Addresses, createClient as createTempoClient } from 'viem/tempo'

import * as Config from './config.js'
import * as Foundry from './foundry.js'
import * as Network from './network.js'
import { provisionFixtures, routerPoolInventory, validateFixtures } from './deployment/fixtures.js'
import {
  isProtected,
  localizeProfile,
  sameAssetProfile,
  variantAccess,
  variantProfile,
  type LocalTargets,
} from './deployment/profile.js'
import type {
  AccessKind,
  Base,
  EngineKind,
  ProfileDeployment,
  Result,
  State,
} from './deployment/types.js'
import { earnEngineBindingAbi, earnRouterAbi, zonePortalAbi } from '@tempoxyz/contracts/abis'
import { missingZoneTokens, zonePortalRole } from '@tempoxyz/contracts/tempo/zone'

/** Pure profile helpers, so consumers can derive what a variant deploys without a chain. */
export {
  localizeProfile,
  variantAccess,
  variantProfile,
  type LocalTargets,
} from './deployment/profile.js'

export {
  provisionFixtures,
  routerPoolInventory,
  validateFixtures,
  type Fixtures,
} from './deployment/fixtures.js'

export type {
  AccessKind,
  Base,
  EngineKind,
  ProfileDeployment,
  Result,
  SameAssetRoute,
  State,
} from './deployment/types.js'

/** Nonzero pool rounding-route and trade-memo identifier for the variant profiles' router. */
export const routerCustomerId = keccak256(stringToHex('tempo-earn.local.router'))

/** Deploys the local fixtures (stablecoins, router pool, venue) and the shared factory release. */
export async function createBase(options: createBase.Options): Promise<Base> {
  const { stablecoins, routerPool, ...fixtures } = await provisionFixtures({
    ...options,
    conversionPool: true,
  })
  if (!stablecoins || !routerPool) throw new Error('Local fixtures need the stablecoin pair')
  const deployed = async (step: Foundry.Step) => {
    const deployment = await Foundry.deploy({ ...options, step })
    fixtures.receipts.push(deployment.receipt)
    return deployment.address
  }
  const sameAssetVault = options.sameAssetRoute
    ? await deployed(Foundry.earnFixture('pathUsdVault', []))
    : undefined
  const chainId = BigInt(options.chainId)
  const large = { rawGasEstimate: true }
  // Release contracts are created deterministically, and an entry point reuses one that exists
  // without a transaction (a persistent devnet deployed before), so take it from its address.
  const predicted = Foundry.releaseAddresses(engineFactories.map((factory) => factory.releaseKey))
  const released = async (name: string, step: Foundry.Step) => {
    const address = predicted[name]
    if (!address) throw new Error(`No deterministic address for ${name}`)
    const code = await options.client.getCode({ address })
    if (code && code !== '0x') return address
    const created = await deployed(step)
    if (getAddress(created) !== address) {
      throw new Error(`${step.name} created ${created}, not its deterministic address ${address}`)
    }
    return address
  }
  const earnVaultImplementation = await released(
    'EarnVault',
    Foundry.release('earnVaultImplementation', [chainId], large),
  )
  const earnFeesImplementation = await released(
    'EarnFees',
    Foundry.release('earnFeesImplementation', [chainId], large),
  )
  const factory = await released(
    'EarnFactory',
    Foundry.release(
      'earnFactory',
      [chainId, earnVaultImplementation, earnFeesImplementation],
      large,
    ),
  )
  // Every engine factory joins the release, since every profile's release identity names them.
  const releasedEngineFactories: Base['engineFactories'][number][] = []
  for (const factory of engineFactories) {
    const step = factoryReleaseStep(factory, chainId)
    releasedEngineFactories.push({ factory, address: await released(factory.contract, step) })
  }
  return {
    ...fixtures,
    engineKind: options.engineKind,
    stablecoins,
    routerPool,
    engineFactories: releasedEngineFactories,
    factory,
    ...(sameAssetVault ? { sameAssetVault } : {}),
  }
}

export declare namespace createBase {
  type Options = Omit<Foundry.deploy.Options, 'step'> & {
    engineKind: EngineKind
    /** Also deploys the PATHUSD venue for `State.sameAssetRoute`. */
    sameAssetRoute?: boolean | undefined
    /**
     * The funded key of the engine setup owner, separate from the deployer, for an engine kind that
     * provisions its engine as that owner (`ProvisionContext.deployAsEngineOwner`).
     */
    engineOwnerPrivateKey?: Hex | undefined
  }
}

/**
 * Deploys the Earn stack a profile describes through the shared profile lifecycle, completes
 * local-only readiness (policy membership, fixture tokens, router gateways), then verifies each
 * stack and requires every capability it reports to be ready.
 */
export async function create(options: create.Options): Promise<Result> {
  const { base, client } = options
  const zoneId = options.zone.id
  const zoneSequencer = await Network.resolveZoneSequencer({
    client,
    portal: options.zone.portal,
    zoneId,
  })
  const accessClient = tempoClient(options, options.privateKey)
  const { accessAdministrator } = options
  const now = Number((await client.getBlock()).timestamp)
  const source = options.earnProfile
    ? authoredProfile(options.earnProfile)
    : variantProfile({
        access: options.access ?? variantAccess,
        customerId: routerCustomerId,
        deployer: options.account,
        engineKind: base.engineKind,
        now,
        revenueShareRecipient: options.revenueShareRecipient,
      })

  // Disposable stand-in for the profile's TIP-403 policy; the Zone principals join before deploy.
  const preDeploymentMembers = unique([
    options.zone.portal,
    options.zone.messenger,
    zoneSequencer,
    Addresses.zoneOutbox,
    options.account,
    options.revenueShareRecipient,
  ])
  const policy = isProtected(source)
    ? await accessClient.policy.createSync({ addresses: preDeploymentMembers, type: 'whitelist' })
    : undefined
  const targets: LocalTargets = {
    chainId: options.chainId,
    deployer: options.account,
    factories: {
      earn: base.factory,
      ...Object.fromEntries(
        base.engineFactories.map(({ factory, address }) => [factory.releaseKey, address]),
      ),
    },
    venueOrEngine: base.engine ?? base.vault,
    policyId: policy?.policyId,
    zoneId,
    conversion: { privateAsset: base.stablecoins.alternateAsset, pool: base.routerPool.pool },
    vaultAsset: base.baseAsset,
  }
  const primary = localizeProfile(source, targets)
  const profiles = [
    primary,
    ...(base.sameAssetVault
      ? [
          sameAssetProfile(primary, {
            ...targets,
            venueOrEngine: base.sameAssetVault,
            vaultAsset: Config.address.pathUsd,
          }),
        ]
      : []),
  ]
  const deployments: ProfileDeployment[] = []
  for (const profile of profiles) {
    deployments.push(await deployProfile(profile, options))
  }
  const [stack, sameAsset] = deployments as [ProfileDeployment, ProfileDeployment | undefined]
  const outputs = stack.outputs

  const accessReceipts: { transactionHash: Hex }[] = []
  if (policy) {
    accessReceipts.push(policy.receipt)
    const members = deployments.flatMap((deployment) =>
      accessMembers(deployment.profile, deployment.outputs),
    )
    for (const member of unique(members)) {
      if (preDeploymentMembers.includes(member)) continue
      const update = await accessClient.policy.modifyWhitelistSync({
        policyId: policy.policyId,
        address: member,
        allowed: true,
      })
      accessReceipts.push(update.receipt)
    }
    if (!isAddressEqual(accessAdministrator, options.account)) {
      const admin = await accessClient.policy.setAdminSync({
        admin: accessAdministrator,
        policyId: policy.policyId,
      })
      accessReceipts.push(admin.receipt)
    }
  }
  const zoneAdministration = await administerZonePortal(
    tempoClient(options, options.zonePrivateKey),
    options.zone.portal,
    {
      tokens: [Config.address.pathUsd, base.baseAsset, base.stablecoins.alternateAsset],
      gateways: deployments.flatMap(({ outputs }) =>
        outputs.earnRouter ? [outputs.earnRouter] : [],
      ),
    },
  )
  await validateFixtures(client, base.engineKind, base, options.account)
  for (const deployment of deployments) {
    await verifyReady(deployment, options.rpcUrl)
    await validateRouter(client, deployment)
    // Private cases need the Zone to mirror each routed EarnShare first.
    if (deployment.outputs.earnRouter) {
      await Network.waitForToken(
        options.zone.publicRpcUrl,
        required(deployment.outputs, 'earnShare'),
      )
    }
  }

  const pool = primary.zone?.router.pool ? primary.zone.router : undefined
  const lifecycleTransactions = deployments.flatMap((deployment) =>
    Object.values(deployment.actions).flatMap((action) => action.transactions),
  )
  const state: State = {
    version: 1,
    engineKind: base.engineKind,
    earnProfile: primary,
    chainId: options.chainId,
    deployedAtBlock: await client.getBlockNumber(),
    transactions: [
      ...base.receipts,
      ...accessReceipts,
      ...(zoneAdministration ? [zoneAdministration] : []),
    ]
      .map((receipt) => receipt.transactionHash)
      .concat(lifecycleTransactions),
    zoneId,
    zoneChainId: options.zone.chainId,
    zonePortal: options.zone.portal,
    zoneMessenger: options.zone.messenger,
    zoneSequencer,
    tip20Factory: Config.address.tip20Factory,
    pathUsd: Config.address.pathUsd,
    baseAsset: base.baseAsset,
    stablecoinFixture: base.stablecoins.funder,
    owner: primary.owner,
    revenueShareRecipient: options.revenueShareRecipient,
    alternateAsset: base.stablecoins.alternateAsset,
    factory: base.factory,
    vault: base.vault,
    engine: required(outputs, 'engine'),
    earnShare: required(outputs, 'earnShare'),
    earnVault: required(outputs, 'earnVault'),
    earnFees: required(outputs, 'earnFees'),
    ...(outputs.earnRouter ? { earnRouter: outputs.earnRouter } : {}),
    earnRouterPool: {
      ...base.routerPool,
      customerId: pool?.customerId ?? routerCustomerId,
      inventory: routerPoolInventory,
    },
    ...optionalPeriphery(outputs),
    accessAdministrator,
    access: policy ? serializeWhitelistPolicy(policy.policyId) : { kind: 'open' },
    engineFixtures: base.engineFixtures,
    ...(sameAsset && base.sameAssetVault
      ? {
          sameAssetRoute: {
            asset: Config.address.pathUsd,
            vault: base.sameAssetVault,
            engine: required(sameAsset.outputs, 'engine'),
            earnShare: required(sameAsset.outputs, 'earnShare'),
            earnVault: required(sameAsset.outputs, 'earnVault'),
            earnFees: required(sameAsset.outputs, 'earnFees'),
            earnRouter: required(sameAsset.outputs, 'earnRouter'),
          },
        }
      : {}),
  }
  return { profiles: deployments, accessTransactions: accessReceipts.length, state }
}

export declare namespace create {
  type Options = Omit<createBase.Options, 'engineKind' | 'sameAssetRoute'> & {
    /** Variant access when no profile is supplied; a supplied profile defines its own. */
    access?: AccessKind | undefined
    base: Base
    /** An authored profile to deploy instead of the variant default, localized to this chain. */
    earnProfile?: EarnDeploymentProfile | undefined
    revenueShareRecipient: Address
    accessAdministrator: Address
    zone: {
      id: number
      chainId: number
      messenger: Address
      portal: Address
      /** Unauthenticated Zone RPC that shows when the Zone mirrors a newly enabled token. */
      publicRpcUrl: string
    }
    zonePrivateKey: Hex
  }
}

/**
 * Verifies one deployed stack as hosted reconciliation does and requires every capability it
 * reports, such as router conversion and Zone tokens, to be ready.
 */
async function verifyReady({ profile, outputs }: ProfileDeployment, rpcUrl: string) {
  const report = await verifyEarnDeploymentState(
    profile,
    rpcUrl,
    outputs,
    undefined,
    planEarnDeployment(profile),
  )
  const blocked = Object.values(report).filter((readiness) => readiness.status !== 'ready')
  if (blocked.length > 0) {
    const reasons = blocked.map(({ label, blockers }) => `${label}: ${blockers.join('; ')}`)
    throw new Error(`Local ${profile.id} stack is not ready (${reasons.join(', ')})`)
  }
}

/** Local par oracle precision; see `DemoPropAMMParOracle`. */
const localParPrice = 10n ** 8n

/**
 * The local router checks the shared inspection does not make: it supports exactly the deposit and
 * redeem flows, and a converting router prices at the local par with the full E2E inventory.
 */
async function validateRouter(
  client: create.Options['client'],
  { profile, outputs }: ProfileDeployment,
) {
  if (!outputs.earnRouter) return
  const router = { address: outputs.earnRouter, abi: earnRouterAbi } as const
  const flows = await Promise.all(
    [0, 1, 2, 3].map((flow) =>
      client.readContract({ ...router, functionName: 'supportsFlow', args: [flow] }),
    ),
  )
  if (flows.join() !== 'true,true,false,false') {
    throw new Error(`Local ${profile.id} router flow support is ${flows.join()}`)
  }
  if (!profile.zone?.router.pool) return
  const [parPrice, [, , , depositLiquidity, redeemLiquidity]] = await Promise.all([
    client.readContract({ ...router, functionName: 'parPrice' }),
    client.readContract({ ...router, functionName: 'liquidityStatus' }),
  ])
  if (parPrice !== localParPrice) throw new Error(`Local ${profile.id} router par price mismatch`)
  if (depositLiquidity < routerPoolInventory || redeemLiquidity < routerPoolInventory) {
    throw new Error(`Local ${profile.id} router pool inventory is below ${routerPoolInventory}`)
  }
}

/**
 * Runs the shared plan to completion on the disposable chain. Every authority is a local account:
 * the deployer acts for itself, and an engine's separate setup owner satisfies the `bind-core`
 * handoff, recorded through the same `recordAuthorityAction` path hosted operators use. Any other
 * handoff is a failure. A second pass must then find the stack complete and change nothing.
 * `create` verifies the result once local readiness is complete.
 */
async function deployProfile(
  profile: EarnDeploymentProfile,
  options: create.Options,
): Promise<ProfileDeployment> {
  // The lifecycle reads Forge receipts from `<root>/broadcast` and keeps resume state beside the
  // profile path, so both stay inside this run's temporary directory.
  if (basename(options.broadcastDirectory) !== 'broadcast') {
    throw new Error('Local broadcast directory must be <run directory>/broadcast')
  }
  const root = dirname(options.broadcastDirectory)
  mkdirSync(resolve(root, 'profiles', profile.id), { recursive: true })
  const environment = {
    ...process.env,
    DEPLOYER_PRIVATE_KEY: options.privateKey,
    ZONE_ADMIN_PRIVATE_KEY: options.zonePrivateKey,
  }
  const lifecycle = {
    actions: planEarnDeployment(profile),
    environment,
    profile,
    profilePath: resolve(root, 'profiles', profile.id, 'profile.json'),
    root,
    rpcUrl: options.rpcUrl,
  }
  const discoveredOutputs = await discoverOutputs({
    environment,
    profile,
    rpcUrl: options.rpcUrl,
    requireLive: false,
  })
  await preflightEarnDeployment(profile, options.rpcUrl)
  const reconcile = () =>
    reconcileEarnProfileActions({
      ...lifecycle,
      discoveredOutputs,
      executeFoundry: (step) => Foundry.runLifecycleStep(step, options.broadcastDirectory),
    })
  let result = await reconcile()
  if (result.kind === 'handoff' && result.action.id === 'bind-core') {
    const transaction = await bindAsEngineOwner(profile, result.pending.outputs, options)
    await recordAuthorityAction({ ...lifecycle, step: result, transactions: [transaction] })
    result = await reconcile()
  }
  if (result.kind === 'handoff') {
    throw new Error(
      `Local ${profile.id} deployment stopped at ${result.action.id}: ${result.instructions}`,
    )
  }
  const resumed = await prepareLifecycleStep(lifecycle)
  if (resumed.kind !== 'complete' || !isDeepStrictEqual(resumed.pending, result.pending)) {
    throw new Error(`Resuming the complete local ${profile.id} deployment planned ${resumed.kind}`)
  }
  return { profile, outputs: result.pending.outputs, actions: result.pending.actions }
}

/** Binds an existing engine to its EarnVault and final owner as the engine's setup owner. */
async function bindAsEngineOwner(
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
  options: create.Options,
) {
  if (!options.engineOwnerPrivateKey || !('address' in profile.engine)) {
    throw new Error(`Local ${profile.id} engine has no local setup owner to bind it`)
  }
  const receipt = await tempoClient(options, options.engineOwnerPrivateKey).writeContractSync({
    address: profile.engine.address,
    abi: earnEngineBindingAbi,
    functionName: 'initializeEarnVault',
    args: [required(outputs, 'earnVault'), profile.owner],
    feeToken: Config.address.pathUsd,
    throwOnReceiptRevert: true,
    timeout: 180_000,
  })
  return receipt.transactionHash
}

function tempoClient(options: Pick<create.Options, 'chainId' | 'rpcUrl'>, privateKey: Hex) {
  return createTempoClient({
    account: privateKeyToAccount(privateKey),
    chain: Network.chain(options.chainId, options.rpcUrl),
    transport: http(options.rpcUrl, { timeout: 60_000 }),
  })
}

/**
 * Enables the fixture stablecoins the profile lifecycle does not and registers every router as a
 * callback gateway, as hosted Zone administrators do, in one Zone administrator call. The local
 * Zone starts with access and gateway enforcement off; registration keeps routers working when a
 * consumer enables them.
 */
async function administerZonePortal(
  zoneAdministrator: ReturnType<typeof tempoClient>,
  portal: Address,
  options: { tokens: Address[]; gateways: Address[] },
) {
  const [missing, registered] = await Promise.all([
    missingZoneTokens(
      zoneAdministrator,
      portal,
      options.tokens.map((token) => [token, token] as const),
    ),
    Promise.all(
      options.gateways.map((gateway) =>
        zoneAdministrator.readContract({
          address: portal,
          abi: zonePortalAbi,
          functionName: 'hasRole',
          args: [gateway, zonePortalRole.callbackGateway],
        }),
      ),
    ),
  ])
  const calls = [
    ...missing.map((token) =>
      encodeFunctionData({
        abi: zonePortalAbi,
        functionName: 'enableToken',
        args: [getAddress(token)],
      }),
    ),
    ...options.gateways
      .filter((_, index) => !registered[index])
      .map((gateway) =>
        encodeFunctionData({
          abi: zonePortalAbi,
          functionName: 'setGateway',
          args: [gateway, true],
        }),
      ),
  ].map((data) => ({ to: portal, data }))
  if (calls.length === 0) return undefined
  return await zoneAdministrator.sendTransactionSync({
    account: zoneAdministrator.account,
    calls,
    chain: zoneAdministrator.chain,
    forceAtomic: true,
    throwOnFailure: true,
    timeout: 180_000,
  })
}

function unique(addresses: readonly Address[]) {
  return [...new Set(addresses.map((address) => getAddress(address)))]
}

function required(outputs: Record<string, Address>, key: string) {
  const value = outputs[key]
  if (!value) throw new Error(`Local deployment is missing ${key}`)
  return value
}
