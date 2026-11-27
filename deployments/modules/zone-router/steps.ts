import {
  encodeFunctionData,
  getAbiItem,
  getAddress,
  type Address,
  type Hex,
  isAddressEqual,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'

import { deployZoneRouterScriptAbi, zonePortalAbi, zoneRouterFactoryAbi } from '../../abis/index.js'
import { requireRouterProvenance } from '../earn/zone-router/provenance.js'
import { InspectionMismatchError } from '../../chain/inspect.js'
import { envPrivateKey } from '../../chain/runtime.js'
import {
  missingZoneTokens,
  zoneCallbackGatewayRegistered,
  zoneGatewayDepositsAdmitted,
  portalRoleCalls,
} from '../../chain/zone.js'
import type { EarnDeploymentProfile } from '../../core/profile.js'
import {
  admitPoolRouter,
  canAdministerPool,
  canAdministerZone,
  poolAdministrator,
  poolAdmission,
  zoneAdministrator,
  zoneAdministratorAuthority,
} from '../earn/zone-router/steps.js'
import {
  defineAuthorityStep,
  defineFoundryStep,
  deployedOutputs,
  deployerAuthority,
  required,
  requiredOutput,
  type ChainClient,
} from '../module.js'
import { privateKeyMatches, sendAuthorityCalls } from '../signer.js'
import { inspectZoneRouterBinding } from './inspection.js'
import {
  missingZoneRouterSeeds,
  sendableZoneRouterSeedCalls,
  zoneRouterWarmed,
  zoneRouterSeedPlan,
} from './seeds.js'
import {
  configuredZoneRouter,
  zoneRouterConstructorArgs,
  zoneRouterFactory,
  zoneRouterMode,
} from './profile.js'

const hasZoneRouter = (profile: EarnDeploymentProfile) => profile.zoneRouter !== null

/**
 * The check a person makes before any grant: the lifecycle grants with its own keys only a router and
 * factory that run this checkout's build, so a handoff with a signer configured means they do not.
 */
const sourceCheck = (profile: EarnDeploymentProfile, outputs: Record<string, Address>) =>
  `First confirm that ZoneRouterFactory ${zoneRouterFactory(profile, outputs)} and router ${requiredOutput(outputs, 'zoneRouter')} are source verified as src/zone/ZoneRouterFactory.sol and src/zone/ZoneRouter.sol; with a configured signer, this handoff means they do not run this checkout's build. `

/** The router's conversion pool, when its Earn binding converts the private asset. */
const routerPool = (profile: EarnDeploymentProfile) => profile.zoneRouter?.earn?.pool

/**
 * Deploys the profile's mode through the released ZoneRouterFactory, which returns an existing router
 * for it.
 */
export const deployZoneRouter = defineFoundryStep({
  id: 'deploy-zone-router',
  authority: deployerAuthority,
  execution: 'foundry',
  summary: 'Deploy the ZoneRouter for the profile mode through the released ZoneRouterFactory.',
  phase: 'deployment',
  intent: ['zoneRouter'],
  // The released ZoneRouterFactory source-verifies with its release, before any router trusts its event.
  creationEvent: (profile, outputs) => ({
    address: zoneRouterFactory(profile, outputs),
    event: routerDeployed,
    argument: 'router',
    output: 'zoneRouter',
    source: { contract: 'src/zone/ZoneRouterFactory.sol:ZoneRouterFactory' },
  }),
  script: 'script/zone/deploy/DeployZoneRouter.s.sol:DeployZoneRouterScript',
  rawGasEstimate: true,
  enabled: hasZoneRouter,
  input: (profile, outputs, outputPath) =>
    encodeFunctionData({
      abi: deployZoneRouterScriptAbi,
      functionName: 'run',
      args: [
        {
          expectedChainId: BigInt(profile.chainId),
          factory: zoneRouterFactory(profile, outputs),
          mode: zoneRouterMode(profile, outputs),
          outputPath,
        },
      ],
    }),
  source: {
    output: 'zoneRouter',
    contract: 'src/zone/ZoneRouter.sol:ZoneRouter',
    // An Earn mode moves EarnShare; a Spend-only router never holds it, and membership grants it nothing.
    accessMember: true,
    constructorArgs: (profile, outputs) =>
      zoneRouterConstructorArgs(zoneRouterMode(profile, outputs)),
    // Ownerless and immutable: a router built from other code is replaced through the released
    // factory of this checkout's build. A Spend router is kept on its recorded factory: its spenders,
    // such as the profile's own card program, take spends only from that factory's routers.
    replaceOnCodeChange: (profile) => !profile.zoneRouter?.spenders?.length,
  },
  async satisfied(client, profile, outputs) {
    if (!(await deployedOutputs(client, outputs, ['zoneRouter']))) return false
    return zoneRouterBound(client, profile, outputs)
  },
  // Anyone can deploy a mode through the factory, such as Bridge's spend script listing the same
  // spender; the factory then returns that router, and its RouterDeployed event names the creation.
  adopt: adoptPredictedZoneRouter,
})

const routerDeployed = getAbiItem({ abi: zoneRouterFactoryAbi, name: 'RouterDeployed' })
const maxLogBlockRange = 100_000n

/** The router the factory already deployed for the profile's mode, with its creation transaction. */
export async function adoptPredictedZoneRouter(
  client: Pick<ChainClient, 'getBlockNumber' | 'getLogs' | 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  const factory = zoneRouterFactory(profile, outputs)
  const contract = { address: factory, abi: zoneRouterFactoryAbi } as const
  const router = await client.readContract({
    ...contract,
    functionName: 'predict',
    args: [zoneRouterMode(profile, outputs)],
  })
  const deployed = await client.readContract({
    ...contract,
    functionName: 'isRouter',
    args: [router],
  })
  if (!deployed) return undefined
  for (
    let toBlock = await client.getBlockNumber({ cacheTime: 0 });
    toBlock >= 0n;
    toBlock -= maxLogBlockRange
  ) {
    const fromBlock = toBlock >= maxLogBlockRange ? toBlock - maxLogBlockRange + 1n : 0n
    const [log] = await client.getLogs({
      address: factory,
      event: routerDeployed,
      args: { router },
      fromBlock,
      toBlock,
    })
    if (log) {
      return {
        outputs: {
          ...outputs,
          zoneRouterFactory: getAddress(factory),
          zoneRouter: getAddress(router),
        },
        transaction: log.transactionHash,
      }
    }
    if (fromBlock === 0n) break
  }
  throw new Error(
    `ZoneRouterFactory ${factory} lists router ${router}, but no RouterDeployed event names it`,
  )
}

/** Admits the router on its DirectPropAMM pool; an Earn binding without a pool has nothing to admit. */
export const authorizeZoneRouter = defineAuthorityStep({
  id: 'authorize-zone-router',
  authority: poolAdministrator,
  execution: 'authority',
  summary: 'Admit the ZoneRouter as a taker and recipient on its PropAMM pool.',
  handoffSummary: 'Verify PropAMM pool admission and emit a pool-owner handoff if it is missing.',
  phase: 'activation',
  intent: ['zoneRouter'],
  enabled: (profile) => routerPool(profile) !== undefined,
  async satisfied(client, profile, outputs) {
    const router = requiredOutput(outputs, 'zoneRouter')
    const pool = required(routerPool(profile), 'Zone router conversion pool')
    const { taker, recipient, resolved } = await poolAdmission(client, pool, router)
    return taker && recipient && getAddress(resolved) === router
  },
  handoff: (profile, outputs) => {
    const router = requiredOutput(outputs, 'zoneRouter')
    return `${sourceCheck(profile, outputs)}Confirm ZoneRouterFactory ${zoneRouterFactory(profile, outputs)}.isRouter(${router}) and the mode in its RouterDeployed event, and verify the router's canonical implementation and immutable bindings. Then the owner of PropAMM pool ${routerPool(profile)} must call setTakerAllowed(${router}, true) and setRecipientAllowed(${router}, true), and the pool must resolve that router as its own recipient. When a DirectPropAMMRebalanceController owns the pool, its owner makes both calls through controller.execute(data). Re-run the same pnpm earn deploy command; it will verify the admission onchain and continue.`
  },
  signerAvailable: (_profile, environment, proven) =>
    Boolean(environment.DEPLOYER_PRIVATE_KEY?.trim()) && proven,
  probeSigner: (options) => {
    const pool = routerPool(options.profile)
    return pool ? canAdministerPool(options, pool) : Promise.resolve(false)
  },
  execute: (options, dependencies) =>
    admitPoolRouter(
      options,
      dependencies,
      required(routerPool(options.profile), 'Zone router conversion pool'),
      requiredOutput(options.outputs, 'zoneRouter'),
      (client) => modeProvenanceMatches(client, options.profile, options.outputs),
    ),
})

export const enableZoneRouterTokens = defineAuthorityStep({
  id: 'enable-zone-router-tokens',
  authority: zoneAdministratorAuthority,
  execution: 'authority',
  summary: "Enable EarnShare and the private asset on the ZoneRouter's Zone.",
  handoffSummary:
    'Verify Zone token readiness and emit a Zone administrator handoff if tokens are missing.',
  phase: 'activation',
  intent: ['zoneRouter'],
  // Spend returns whatever token the Portal already enables; only Earn ops need their pair.
  enabled: (profile) => profile.zoneRouter?.earn !== undefined,
  signerAvailable: (_profile, environment, proven) =>
    Boolean(environment.ZONE_ADMIN_PRIVATE_KEY?.trim()) && proven,
  probeSigner: (options) =>
    canAdministerZone(options, configuredZoneRouter(options.profile).zoneId),
  satisfied: async (client, profile, outputs) =>
    (
      await missingZoneTokens(
        client,
        requiredOutput(outputs, 'zoneRouterPortal'),
        zoneRouterTokens(profile, outputs),
      )
    ).length === 0,
  handoff: (profile, outputs) =>
    `Core Zones must enable ${zoneRouterTokens(profile, outputs)
      .map(([, token]) => token)
      .join(
        ', ',
      )} on Zone ${configuredZoneRouter(profile).zoneId}. Re-run the same pnpm earn deploy command; it will verify every token and continue.`,
  async execute(options, dependencies) {
    const portal = requiredOutput(options.outputs, 'zoneRouterPortal')
    const administrator = await zoneAdministrator(options, dependencies, portal)
    if (!administrator) return undefined
    const tokens = zoneRouterTokens(options.profile, options.outputs)
    const missing = new Set(await missingZoneTokens(administrator.client, portal, tokens))
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
    return administrator.send(calls)
  },
})

export const registerZoneRouterGateway = defineAuthorityStep({
  id: 'register-zone-router-gateway',
  authority: zoneAdministratorAuthority,
  execution: 'authority',
  summary: 'Register the ZoneRouter as a Portal callback gateway when the Zone restricts gateways.',
  handoffSummary:
    'Verify callback-gateway registration and emit a Zone administrator handoff if it is missing.',
  phase: 'activation',
  intent: ['zoneRouter'],
  enabled: hasZoneRouter,
  satisfied: (client, _profile, outputs) =>
    zoneCallbackGatewayRegistered(
      client,
      requiredOutput(outputs, 'zoneRouterPortal'),
      requiredOutput(outputs, 'zoneRouter'),
    ),
  handoff: (profile, outputs) => {
    const router = requiredOutput(outputs, 'zoneRouter')
    const factory = zoneRouterFactory(profile, outputs)
    return `${sourceCheck(profile, outputs)}Zone ${configuredZoneRouter(profile).zoneId} restricts callback gateways: its Portal administrator should confirm ZoneRouterFactory ${factory}.isRouter(${router}) and the mode in its RouterDeployed event, review every readiness blocker and verify each listed spender implementation and ROUTER_FACTORY binding before granting access, then, if the router holds the account role, call setAllowedAccount(${router}, false), and call setGateway(${router}, true) on ${requiredOutput(outputs, 'zoneRouterPortal')}, in one batch. Re-run the same pnpm earn deploy command; it will verify the registration and continue.`
  },
  signerAvailable: (_profile, environment, proven) =>
    Boolean(environment.ZONE_ADMIN_PRIVATE_KEY?.trim()) && proven,
  probeSigner: (options) =>
    canAdministerZone(options, configuredZoneRouter(options.profile).zoneId),
  async execute(options, dependencies) {
    const portal = requiredOutput(options.outputs, 'zoneRouterPortal')
    const administrator = await zoneAdministrator(options, dependencies, portal)
    if (!administrator) return undefined
    const router = requiredOutput(options.outputs, 'zoneRouter')
    if (await zoneCallbackGatewayRegistered(administrator.client, portal, router))
      return { transactions: [] }
    if (!(await modeProvenanceMatches(administrator.client, options.profile, options.outputs)))
      return undefined
    return administrator.send(
      await portalRoleCalls(administrator.client, portal, router, 'callbackGateway'),
    )
  },
})

/**
 * Admits the router as a Portal account when the Portal enforces access with open gateways: the
 * router then returns change and converted output as an ordinary depositor, which needs that role.
 */
export const admitZoneRouterAccount = defineAuthorityStep({
  id: 'admit-zone-router-account',
  authority: zoneAdministratorAuthority,
  execution: 'authority',
  summary:
    'Admit the ZoneRouter as a Portal account when the Zone enforces access with open gateways.',
  handoffSummary:
    'Verify the router can deposit back into its Zone and emit a Zone administrator handoff if not.',
  phase: 'activation',
  intent: ['zoneRouter'],
  enabled: hasZoneRouter,
  satisfied: (client, _profile, outputs) =>
    zoneGatewayDepositsAdmitted(
      client,
      requiredOutput(outputs, 'zoneRouterPortal'),
      requiredOutput(outputs, 'zoneRouter'),
    ),
  handoff: (profile, outputs) => {
    const router = requiredOutput(outputs, 'zoneRouter')
    return `${sourceCheck(profile, outputs)}Zone ${configuredZoneRouter(profile).zoneId} enforces account access with open callback gateways, so the router deposits back as an account: its Portal administrator should confirm ZoneRouterFactory ${zoneRouterFactory(profile, outputs)}.isRouter(${router}) and the mode in its RouterDeployed event, review every readiness blocker and verify each listed spender implementation and ROUTER_FACTORY binding before granting access, then, if the router holds the callback-gateway role, call setGateway(${router}, false), and call setAllowedAccount(${router}, true) on ${requiredOutput(outputs, 'zoneRouterPortal')}, in one batch. Re-run the same pnpm earn deploy command; it will verify the admission and continue.`
  },
  signerAvailable: (_profile, environment, proven) =>
    Boolean(environment.ZONE_ADMIN_PRIVATE_KEY?.trim()) && proven,
  probeSigner: (options) =>
    canAdministerZone(options, configuredZoneRouter(options.profile).zoneId),
  async execute(options, dependencies) {
    const portal = requiredOutput(options.outputs, 'zoneRouterPortal')
    const administrator = await zoneAdministrator(options, dependencies, portal)
    if (!administrator) return undefined
    const router = requiredOutput(options.outputs, 'zoneRouter')
    if (await zoneGatewayDepositsAdmitted(administrator.client, portal, router))
      return { transactions: [] }
    if (!(await modeProvenanceMatches(administrator.client, options.profile, options.outputs)))
      return undefined
    return administrator.send(
      await portalRoleCalls(administrator.client, portal, router, 'account'),
    )
  },
})

/**
 * Keeps the router's and its SendSpenders' TIP-20 balance slots, and the router's Portal allowances,
 * nonzero so no callback pays to create them. Idempotent: it sends only what is missing.
 */
export const seedZoneRouter = defineAuthorityStep({
  id: 'seed-zone-router',
  authority: deployerAuthority,
  execution: 'authority',
  summary:
    'Send the ZoneRouter and its SendSpenders 1 base unit of each token they route, and warm the router Portal allowances.',
  handoffSummary:
    'Verify the router holds its Portal allowances, and emit a deployer handoff if not.',
  phase: 'activation',
  intent: ['zoneRouter'],
  enabled: hasZoneRouter,
  signerAvailable: (profile, environment) =>
    privateKeyMatches(environment, deployerAuthority.signer, profile.deployer),
  // Only the Portal allowances, which stay set once warmed, are required, so verify stays stable
  // whatever the deployer later holds. Seed units are sent once by `attemptWhenSatisfied`.
  async satisfied(client, profile, outputs) {
    const plan = await zoneRouterSeedPlan(client, profile, outputs)
    return zoneRouterWarmed(await missingZoneRouterSeeds(client, plan))
  },
  attemptWhenSatisfied: true,
  handoff: (profile, outputs) =>
    `ZoneRouter ${requiredOutput(outputs, 'zoneRouter')} lacks a Portal allowance. Run pnpm earn verify, then either re-run the same pnpm earn deploy command with the deployer ${profile.deployer}'s DEPLOYER_PRIVATE_KEY, or call warm(token) on the router for each allowance listed under Zone router seeds (anyone may), and re-run; it will verify them and continue. Seed units listed there block nothing: send each holder 1 base unit by hand.`,
  async execute(options, dependencies) {
    const key = envPrivateKey(options.environment, deployerAuthority.signer)
    if (!key) return undefined
    const account = privateKeyToAccount(key)
    // Completion is judged by what the profile's deployer can send, so only that account seeds.
    if (!isAddressEqual(account.address, options.profile.deployer)) return undefined
    const client = dependencies.authorityClient(options, account)
    if (!(await zoneRouterBound(client, options.profile, options.outputs)))
      throw new Error(
        `ZoneRouter ${requiredOutput(options.outputs, 'zoneRouter')} is not the profile's router; refusing to seed it`,
      )
    const plan = await zoneRouterSeedPlan(client, options.profile, options.outputs)
    const missing = await missingZoneRouterSeeds(client, plan)
    if (missing.seeds.length === 0 && zoneRouterWarmed(missing)) return { transactions: [] }
    // Each call is simulated alone first, so a token whose policy refuses one transfer never reverts
    // the batch: the rest go out, and units left unsent are reported by verify.
    const sendable = await sendableZoneRouterSeedCalls(client, account.address, plan, missing)
    // Each seed or warm call can create a slot (about 290,000 gas), so batches stay well under
    // Tempo's 30M transaction cap however many spenders the router lists.
    const sent: { transactions: Hex[] } = { transactions: [] }
    for (let index = 0; index < sendable.calls.length; index += seedBatchSize) {
      const batch = sendable.calls.slice(index, index + seedBatchSize)
      const { transactions } = await sendAuthorityCalls(
        client,
        dependencies,
        options.profile,
        batch,
      )
      sent.transactions.push(...transactions)
    }
    // Seeds left unsent (refused, unfunded, or newly fundable after a faucet top-up) never block.
    if (zoneRouterWarmed(await missingZoneRouterSeeds(client, plan))) return sent
    if (sent.transactions.length === 0) return undefined
    // Sent batches cannot be recorded against an unsatisfied step, so name them before handing off.
    throw new Error(
      `seed-zone-router sent ${sent.transactions.join(', ')} but a Portal allowance is still missing: ${sendable.refused.join('; ')}`,
    )
  },
})

/** Calls per seed transaction: about 14M gas when every call creates a slot. */
const seedBatchSize = 48

/** The tokens an Earn mode moves in and out of its Zone, labeled for readiness reports. */
export function zoneRouterTokens(
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
): [label: string, token: Address][] {
  const earn = required(configuredZoneRouter(profile).earn, 'Zone router Earn binding')
  return [
    ['EarnShare', requiredOutput(outputs, 'earnShare')],
    ['private asset', earn.privateAsset],
  ]
}

/** Whether the recorded router is the factory's router for the profile mode, bound as configured. */
export async function zoneRouterBound(
  client: Pick<ChainClient, 'readContract'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  return inspectZoneRouterBinding(client, {
    router: requiredOutput(outputs, 'zoneRouter'),
    factory: zoneRouterFactory(profile, outputs),
    portal: requiredOutput(outputs, 'zoneRouterPortal'),
    mode: zoneRouterMode(profile, outputs),
    earnShare: requiredOutput(outputs, 'earnShare'),
    vaultAsset: requiredOutput(outputs, 'asset'),
  }).then(
    () => true,
    (error: unknown) => {
      if (error instanceof InspectionMismatchError) return false
      throw error
    },
  )
}

/**
 * Whether the factory and router run this build, as the lifecycle's own grants require. A Spend router
 * kept on an older build is not an error: its grants are handed to a person, who checks its source.
 */
async function modeProvenanceMatches(
  client: Pick<ChainClient, 'call' | 'getCode'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  try {
    await requireModeProvenance(client, profile, outputs)
    return true
  } catch (error) {
    if ((error as Error | undefined)?.name === 'ProvenanceMismatchError') return false
    throw error
  }
}

/** Both the restored factory and its mode must be canonical before a Zone administrator grants access. */
async function requireModeProvenance(
  client: Pick<ChainClient, 'call' | 'getCode'>,
  profile: EarnDeploymentProfile,
  outputs: Record<string, Address>,
) {
  await requireRouterProvenance(client, {
    address: zoneRouterFactory(profile, outputs),
    contract: 'src/zone/ZoneRouterFactory.sol:ZoneRouterFactory',
    constructorArgs: '0x',
  })
  await requireRouterProvenance(client, {
    address: requiredOutput(outputs, 'zoneRouter'),
    contract: 'src/zone/ZoneRouter.sol:ZoneRouter',
    constructorArgs: zoneRouterConstructorArgs(zoneRouterMode(profile, outputs)),
  })
}
