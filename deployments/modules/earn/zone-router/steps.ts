import {
  AbiDecodingDataSizeTooSmallError,
  AbiDecodingZeroDataError,
  BaseError,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  concat,
  encodeFunctionData,
  getAddress,
  pad,
  zeroAddress,
  type Address,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import {
  propAMMPoolAbi,
  propAMMRebalanceControllerAbi,
  safeAbi,
  zonePortalAbi,
} from '../../../abis/index.js'
import type { EarnDeploymentProfile } from '../../../core/profile.js'
import { configuredZone } from './profile.js'
import { missingZoneTokens, registeredZone } from '../../../chain/zone.js'
import { zoneTokens } from './index.js'
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
  required,
  requiredOutput,
  type ChainClient,
  type StepAuthority,
} from '../../../../deployments/modules/module.js'

const hasZone = (profile: EarnDeploymentProfile) => configuredZone(profile) !== undefined

/** A router's PropAMM pool owner; planning proves whether the deployer key holds this role. */
export const poolAdministrator = {
  id: 'pool-administrator',
  label: 'PropAMM pool owner',
  signer: 'DEPLOYER_PRIVATE_KEY',
} as const satisfies StepAuthority

/** The Zone Portal administrator, or the key that solely owns its threshold-1 Safe. */
export const zoneAdministratorAuthority = {
  id: 'zone-administrator',
  label: 'Zone Portal administrator',
  signer: 'ZONE_ADMIN_PRIVATE_KEY',
} as const satisfies StepAuthority

/**
 * Admits `router` as a taker and recipient on `pool` as the deployer, when it owns the pool directly
 * or through its rebalance controller; `undefined` when it holds neither. `requireProvenance` must
 * prove the recovered router canonical: like Portal admission, pool admission grants it authority
 * the lifecycle cannot take back.
 */
export async function admitPoolRouter(
  options: AuthorityOptions,
  dependencies: AuthorityDependencies,
  pool: Address,
  router: Address,
  requireProvenance: (client: AuthorityClient) => Promise<void>,
): Promise<{ transactions: Hex[] } | undefined> {
  const key = envPrivateKey(options.environment, 'DEPLOYER_PRIVATE_KEY')
  if (!key) return undefined
  const account = privateKeyToAccount(key)
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
  await requireProvenance(client)
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
}

export const enableZoneTokens = defineAuthorityStep({
  id: 'enable-zone-tokens',
  authority: zoneAdministratorAuthority,
  execution: 'authority',
  summary: 'Enable EarnShare on the Zone.',
  handoffSummary:
    'Verify Zone token readiness and emit a Zone administrator handoff if tokens are missing.',
  phase: 'activation',
  intent: ['zone'],
  enabled: hasZone,
  signerAvailable: (_profile, environment, proven) =>
    Boolean(environment.ZONE_ADMIN_PRIVATE_KEY?.trim()) && proven,
  probeSigner: (options) =>
    canAdministerZone(options, required(configuredZone(options.profile), 'Zone').id),
  satisfied: async (client, _profile, outputs) =>
    (await missingZoneTokens(client, requiredOutput(outputs, 'zonePortal'), zoneTokens(outputs)))
      .length === 0,
  handoff: (profile, outputs) =>
    `Core Zones must enable ${zoneTokens(outputs)
      .map(([, token]) => token)
      .join(
        ', ',
      )} on Zone ${configuredZone(profile)?.id}. Re-run the same pnpm earn deploy command; it will verify every token and continue.`,
  async execute(options, dependencies) {
    const administrator = await zoneAdministrator(options, dependencies)
    if (!administrator) return undefined
    const { client, portal, send } = administrator
    const tokens = zoneTokens(options.outputs)
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

/** Proves whether the configured deployer owns `pool`, directly or through its rebalance controller. */
export async function canAdministerPool(
  options: {
    environment: NodeJS.ProcessEnv
    profile: EarnDeploymentProfile
    rpcUrl: string
  },
  pool: Address,
  dependencies: Pick<AuthorityDependencies, 'authorityClient'> = { authorityClient },
) {
  const key = envPrivateKey(options.environment, 'DEPLOYER_PRIVATE_KEY')
  if (!key) return false
  const account = privateKeyToAccount(key)
  const client = dependencies.authorityClient(options, account)
  return (await poolAuthority(client, pool, account.address)) !== undefined
}

/** Whether `pool` admits `router` as a taker and a recipient, and where it sends its output. */
export async function poolAdmission(
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

/** Proves Zone administration without signing: the direct admin or its sole threshold-1 Safe owner. */
export async function canAdministerZone(
  options: Pick<AuthorityOptions, 'environment' | 'profile' | 'rpcUrl'>,
  zoneId: number,
  dependencies: Pick<AuthorityDependencies, 'authorityClient'> = { authorityClient },
) {
  const key = envPrivateKey(options.environment, zoneAdministratorAuthority.signer)
  if (!key) return false
  const account = privateKeyToAccount(key)
  const client = dependencies.authorityClient(options, account)
  const { portal } = await registeredZone(client, zoneId)
  const administrator = getAddress(
    await client.readContract({ address: portal, abi: zonePortalAbi, functionName: 'admin' }),
  )
  return administrator === account.address || soleSafeOwner(client, administrator, account.address)
}

/**
 * The configured administrator of `portal` (the profile Zone's by default), or `undefined` when none
 * is configured. The key either is the Portal admin or solely owns a threshold-1 Safe that is;
 * `send` submits Portal calls either way.
 */
export async function zoneAdministrator(
  options: AuthorityOptions,
  dependencies: AuthorityDependencies,
  portal: Address = requiredOutput(options.outputs, 'zonePortal'),
) {
  const variable = zoneAdministratorAuthority.signer
  const key = envPrivateKey(options.environment, variable)
  if (!key) return undefined
  const account = privateKeyToAccount(key)
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
  } catch (error) {
    if (notRebalanceController(error)) return false
    throw error
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
