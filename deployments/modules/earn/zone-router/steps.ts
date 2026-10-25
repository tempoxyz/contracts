import {
  AbiDecodingDataSizeTooSmallError,
  AbiDecodingZeroDataError,
  BaseError,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  concat,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  pad,
  parseAbiParameters,
  zeroAddress,
  type Address,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import {
  deployEarnRouterScriptAbi,
  earnVaultAbi,
  propAMMPoolAbi,
  propAMMRebalanceControllerAbi,
  safeAbi,
  zonePortalAbi,
} from '../../../abis/index.js'
import { InspectionMismatchError } from '../../../chain/inspect.js'
import { inspectRouterBinding } from './inspection.js'
import type { EarnDeploymentProfile } from '../../../core/profile.js'
import { configuredRouterPool, configuredZone, routerArgs } from './profile.js'
import { missingZoneTokens, zoneCallbackGatewayRegistered } from '../../../chain/zone.js'
import { zoneRouteTokens } from './index.js'
import { envPrivateKey } from '../../../chain/runtime.js'
import {
  authorityClient,
  sendAuthorityCalls,
  type AuthorityClient,
  type AuthorityDependencies,
  type AuthorityOptions,
} from '../../../../deployments/modules/signer.js'
import {
  defineAuthorityStep,
  deployerAuthority,
  defineFoundryStep,
  deployedOutputs,
  required,
  requiredOutput,
  type ChainClient,
  type StepAuthority,
} from '../../../../deployments/modules/module.js'

const hasZone = (profile: EarnDeploymentProfile) => configuredZone(profile) !== undefined

/** The router's PropAMM pool owner; planning proves whether the deployer key holds this role. */
const poolAdministrator = {
  id: 'pool-administrator',
  label: 'PropAMM pool owner',
  signer: 'DEPLOYER_PRIVATE_KEY',
} as const satisfies StepAuthority

/** The Zone Portal administrator, or the key that solely owns its threshold-1 Safe. */
const zoneAdministratorAuthority = {
  id: 'zone-administrator',
  label: 'Zone Portal administrator',
  signer: 'ZONE_ADMIN_PRIVATE_KEY',
} as const satisfies StepAuthority

export const deployRouter = defineFoundryStep({
  id: 'deploy-router',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: 'Deploy the immutable single-Zone router.',
  phase: 'deployment',
  intent: ['zone'],
  script: 'script/deploy/DeployEarnRouter.s.sol:DeployEarnRouterScript',
  rawGasEstimate: true,
  enabled: hasZone,
  input(profile, outputs, outputPath) {
    const { route, ...args } = routerArgs(profile, outputs)
    return encodeFunctionData({
      abi: deployEarnRouterScriptAbi,
      functionName: 'run',
      args: [{ expectedChainId: BigInt(profile.chainId), ...args, ...route, outputPath }],
    })
  },
  source: {
    output: 'earnRouter',
    contract: 'src/router/SingleZoneEarnRouter.sol:SingleZoneEarnRouter',
    accessMember: true,
    constructorArgs(profile, outputs) {
      const { zoneId, earnVault, privateAsset, route } = routerArgs(profile, outputs)
      return encodeAbiParameters(
        parseAbiParameters(
          'uint32 zoneId, address earnVault, address privateAsset, address pool, bytes32 customerId',
        ),
        [zoneId, earnVault, privateAsset, route.pool, route.customerId],
      )
    },
  },
  async satisfied(client, profile, outputs) {
    if (!(await deployedOutputs(client, outputs, ['earnRouter']))) return false
    const args = routerArgs(profile, outputs)
    const vaultAsset = await client.readContract({
      address: args.earnVault,
      abi: earnVaultAbi,
      functionName: 'asset',
    })
    return inspectRouterBinding(client, {
      ...args,
      router: requiredOutput(outputs, 'earnRouter'),
      earnShare: requiredOutput(outputs, 'earnShare'),
      vaultAsset,
    }).then(
      () => true,
      (error: unknown) => {
        if (error instanceof InspectionMismatchError) return false
        throw error
      },
    )
  },
})

/** Admits the router on its DirectPropAMM pool; a router whose private asset is the vault asset has no pool. */
export const authorizeRouter = defineAuthorityStep({
  id: 'authorize-router',
  authority: poolAdministrator,
  execution: 'authority',
  summary: 'Admit the router as a taker and recipient on its PropAMM pool.',
  handoffSummary: 'Verify PropAMM pool admission and emit a pool-owner handoff if it is missing.',
  phase: 'activation',
  intent: ['zone'],
  enabled: (profile) => configuredRouterPool(profile) !== undefined,
  async satisfied(client, profile, outputs) {
    const router = requiredOutput(outputs, 'earnRouter')
    const { pool } = required(configuredRouterPool(profile), 'router conversion pool')
    const { taker, recipient, resolved } = await poolAdmission(client, pool, router)
    return taker && recipient && getAddress(resolved) === router
  },
  handoff: (profile, outputs) =>
    `The owner of PropAMM pool ${configuredZone(profile)?.pool} must call setTakerAllowed(${requiredOutput(outputs, 'earnRouter')}, true) and setRecipientAllowed(${requiredOutput(outputs, 'earnRouter')}, true), and the pool must resolve that router as its own recipient. When a DirectPropAMMRebalanceController owns the pool, its owner makes both calls through controller.execute(data). Re-run the same pnpm earn deploy command; it will verify the admission onchain and continue.`,
  signerAvailable: (_profile, environment, proven) =>
    Boolean(environment.DEPLOYER_PRIVATE_KEY?.trim()) && proven,
  probeSigner: (options) => canAuthorizeRouter(options),
  async execute(options, dependencies) {
    const key = envPrivateKey(options.environment, 'DEPLOYER_PRIVATE_KEY')
    if (!key) return undefined
    const account = privateKeyToAccount(key)
    const { pool } = required(configuredRouterPool(options.profile), 'router conversion pool')
    const router = requiredOutput(options.outputs, 'earnRouter')
    const client = dependencies.authorityClient(options, account)
    const authority = await poolAuthority(client, pool, account.address)
    if (!authority) return undefined

    const { taker, recipient, resolved } = await poolAdmission(client, pool, router)
    // Admission cannot repair a recipient redirect; fail before spending a transaction on it.
    if (getAddress(resolved) !== router) {
      throw new Error(
        `PropAMM pool ${pool} resolves router ${router} to ${resolved}; remove the recipient redirect before admitting the router`,
      )
    }
    const poolCalls = [
      ...(taker
        ? []
        : [
            encodeFunctionData({
              abi: propAMMPoolAbi,
              functionName: 'setTakerAllowed',
              args: [router, true],
            }),
          ]),
      ...(recipient
        ? []
        : [
            encodeFunctionData({
              abi: propAMMPoolAbi,
              functionName: 'setRecipientAllowed',
              args: [router, true],
            }),
          ]),
    ]
    if (poolCalls.length === 0) return { transactions: [] }
    // A DirectPropAMMRebalanceController owns its pool and forwards owner calls through `execute`.
    const calls = poolCalls.map((data) =>
      authority.controller
        ? {
            to: authority.controller,
            data: encodeFunctionData({
              abi: propAMMRebalanceControllerAbi,
              functionName: 'execute',
              args: [data],
            }),
          }
        : { to: pool, data },
    )
    return await sendAuthorityCalls(client, dependencies, options.profile, calls)
  },
})

export const enableZoneTokens = defineAuthorityStep({
  id: 'enable-zone-tokens',
  authority: zoneAdministratorAuthority,
  execution: 'authority',
  summary: 'Enable the exact route token set on the Zone.',
  handoffSummary:
    'Verify Zone token readiness and emit a Zone administrator handoff if tokens are missing.',
  phase: 'activation',
  intent: ['zone'],
  enabled: hasZone,
  satisfied: async (client, profile, outputs) =>
    (
      await missingZoneTokens(
        client,
        requiredOutput(outputs, 'zonePortal'),
        zoneRouteTokens(profile, outputs),
      )
    ).length === 0,
  handoff: (profile, outputs) =>
    `Core Zones must enable ${zoneRouteTokens(profile, outputs)
      .map(([, token]) => token)
      .join(
        ', ',
      )} on Zone ${configuredZone(profile)?.id}. Re-run the same pnpm earn deploy command; it will verify every token and continue.`,
  async execute(options, dependencies) {
    const administrator = await zoneAdministrator(options, dependencies)
    if (!administrator) return undefined
    const { client, portal, send } = administrator
    const tokens = zoneRouteTokens(options.profile, options.outputs)
    const missing = new Set(await missingZoneTokens(client, portal, tokens))
    const calls = tokens.flatMap(([label, token]) =>
      missing.has(label)
        ? [
            {
              to: portal,
              data: encodeFunctionData({
                abi: zonePortalAbi,
                functionName: 'enableToken',
                args: [token],
              }),
            },
          ]
        : [],
    )
    if (calls.length === 0) return { transactions: [] }
    return send(calls)
  },
})

export const registerZoneGateway = defineAuthorityStep({
  id: 'register-zone-gateway',
  authority: zoneAdministratorAuthority,
  execution: 'authority',
  summary: 'Register the router as a Portal callback gateway when the Zone restricts gateways.',
  handoffSummary:
    'Verify callback-gateway registration and emit a Zone administrator handoff if it is missing.',
  phase: 'activation',
  intent: ['zone'],
  enabled: hasZone,
  satisfied: (client, _profile, outputs) =>
    zoneCallbackGatewayRegistered(
      client,
      requiredOutput(outputs, 'zonePortal'),
      requiredOutput(outputs, 'earnRouter'),
    ),
  handoff: (profile, outputs) =>
    `Zone ${configuredZone(profile)?.id} restricts callback gateways: its Portal administrator must call setGateway(${requiredOutput(outputs, 'earnRouter')}, true) on ${requiredOutput(outputs, 'zonePortal')}. Re-run the same pnpm earn deploy command; it will verify the registration and continue.`,
  async execute(options, dependencies) {
    const administrator = await zoneAdministrator(options, dependencies)
    if (!administrator) return undefined
    const { client, portal, send } = administrator
    const router = requiredOutput(options.outputs, 'earnRouter')
    if (await zoneCallbackGatewayRegistered(client, portal, router)) return { transactions: [] }
    return send([
      {
        to: portal,
        data: encodeFunctionData({
          abi: zonePortalAbi,
          functionName: 'setGateway',
          args: [router, true],
        }),
      },
    ])
  },
})

/**
 * Proves whether the configured deployer can admit the router: it owns the PropAMM pool directly, or
 * owns the rebalance controller that owns the pool.
 */
export async function canAuthorizeRouter(
  options: {
    environment: NodeJS.ProcessEnv
    profile: EarnDeploymentProfile
    rpcUrl: string
  },
  dependencies: Pick<AuthorityDependencies, 'authorityClient'> = { authorityClient },
) {
  const key = envPrivateKey(options.environment, 'DEPLOYER_PRIVATE_KEY')
  const conversion = configuredRouterPool(options.profile)
  if (!key || !conversion) return false
  const account = privateKeyToAccount(key)
  const client = dependencies.authorityClient(options, account)
  return (await poolAuthority(client, conversion.pool, account.address)) !== undefined
}

async function poolAdmission(
  client: Pick<ChainClient, 'readContract'>,
  pool: Address,
  router: Address,
) {
  const [taker, recipient, resolved] = await Promise.all([
    client.readContract({
      address: pool,
      abi: propAMMPoolAbi,
      functionName: 'takerAllowed',
      args: [router],
    }),
    client.readContract({
      address: pool,
      abi: propAMMPoolAbi,
      functionName: 'recipientAllowed',
      args: [router],
    }),
    client.readContract({
      address: pool,
      abi: propAMMPoolAbi,
      functionName: 'resolveRecipient',
      args: [router],
    }),
  ])
  return { taker, recipient, resolved }
}

/** Resolves how `account` can act as the pool owner, directly or through its rebalance controller. */
async function poolAuthority(
  client: AuthorityClient,
  pool: Address,
  account: Address,
): Promise<{ controller?: Address } | undefined> {
  const owner = getAddress(
    await client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'owner' }),
  )
  if (owner === account) return {}
  // An EOA or an unrelated contract owner reverts, returns no or malformed data, or mismatches here,
  // and the action stays a handoff for the real owner. Any other failure, such as an RPC outage that
  // outlasted retries, propagates instead of being mistaken for missing authority.
  const controller = await Promise.all([
    client.readContract({
      address: owner,
      abi: propAMMRebalanceControllerAbi,
      functionName: 'pool',
    }),
    client.readContract({
      address: owner,
      abi: propAMMRebalanceControllerAbi,
      functionName: 'owner',
    }),
  ])
    .then(([controlledPool, controllerOwner]) =>
      getAddress(controlledPool) === getAddress(pool) && getAddress(controllerOwner) === account
        ? owner
        : undefined,
    )
    .catch((error: unknown) => {
      if (notRebalanceController(error)) return undefined
      throw error
    })
  return controller ? { controller } : undefined
}

function notRebalanceController(error: unknown) {
  return (
    error instanceof BaseError &&
    error.walk(
      (cause) =>
        cause instanceof ContractFunctionRevertedError ||
        cause instanceof ContractFunctionZeroDataError ||
        cause instanceof AbiDecodingZeroDataError ||
        cause instanceof AbiDecodingDataSizeTooSmallError,
    ) !== null
  )
}

/**
 * The configured Portal administrator, or `undefined` when none is configured. The key either is the
 * Portal admin or solely owns a threshold-1 Safe that is; `send` submits Portal calls either way.
 */
async function zoneAdministrator(options: AuthorityOptions, dependencies: AuthorityDependencies) {
  const variable = zoneAdministratorAuthority.signer
  const key = envPrivateKey(options.environment, variable)
  if (!key) return undefined
  const account = privateKeyToAccount(key)
  const portal = requiredOutput(options.outputs, 'zonePortal')
  const client = dependencies.authorityClient(options, account)
  const administrator = getAddress(
    await client.readContract({ address: portal, abi: zonePortalAbi, functionName: 'admin' }),
  )
  const safe = administrator === account.address ? undefined : administrator
  if (safe && !(await soleSafeOwner(client, safe, account.address))) {
    throw new Error(
      `${variable} ${account.address} does not control Portal ${portal}; its admin ${administrator} is neither that account nor a threshold-1 Safe it solely owns`,
    )
  }
  const send = (calls: { to: Address; data: Hex }[]) =>
    sendAuthorityCalls(
      client,
      dependencies,
      options.profile,
      safe ? calls.map((call) => safeCall(safe, account.address, call)) : calls,
    )
  return { client, portal, send }
}

async function soleSafeOwner(client: AuthorityClient, safe: Address, owner: Address) {
  try {
    const [owners, threshold] = await Promise.all([
      client.readContract({ address: safe, abi: safeAbi, functionName: 'getOwners' }),
      client.readContract({ address: safe, abi: safeAbi, functionName: 'getThreshold' }),
    ])
    return threshold === 1n && owners.length === 1 && getAddress(owners[0]!) === owner
  } catch {
    return false
  }
}

/** Wraps a call in `execTransaction`; an owner that submits it approves with signature v=1. */
function safeCall(safe: Address, owner: Address, call: { to: Address; data: Hex }) {
  const signature = concat([pad(owner), pad('0x00'), '0x01'])
  return {
    to: safe,
    data: encodeFunctionData({
      abi: safeAbi,
      functionName: 'execTransaction',
      args: [call.to, 0n, call.data, 0, 0n, 0n, 0n, zeroAddress, zeroAddress, signature],
    }),
  }
}
