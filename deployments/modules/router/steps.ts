import { encodeFunctionData, getAbiItem, getAddress, zeroAddress, type Address } from 'viem'

import {
  deployZoneRouterFactoryScriptAbi,
  deployZoneRouterScriptAbi,
  zonePortalAbi,
  zoneRouterFactoryAbi,
} from '../../abis/index.js'
import { InspectionMismatchError } from '../../chain/inspect.js'
import { missingZoneTokens, zoneCallbackGatewayRegistered } from '../../chain/zone.js'
import type { EarnDeploymentProfile } from '../../core/profile.js'
import {
  admitPoolRouter,
  canAdministerPool,
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
import { inspectZoneRouterBinding } from './inspection.js'
import {
  configuredZoneRouter,
  zoneRouterConstructorArgs,
  zoneRouterFactory,
  zoneRouterMode,
} from './profile.js'

const hasZoneRouter = (profile: EarnDeploymentProfile) => profile.zoneRouter !== null

/** Whether the profile names an existing ZoneRouterFactory rather than deploying its own. */
const namesFactory = (profile: EarnDeploymentProfile) => profile.zoneRouter?.factory !== undefined

/**
 * The check a person makes before admitting a router from a factory the profile names, which the
 * lifecycle trusts only for its own answers; empty for a factory the lifecycle deployed.
 */
const namedFactoryCheck = (profile: EarnDeploymentProfile, outputs: Record<string, Address>) =>
  namesFactory(profile)
    ? `First confirm that ZoneRouterFactory ${zoneRouterFactory(profile, outputs)} is source verified as router/src/ZoneRouterFactory.sol. `
    : ''

/** The router's conversion pool, when its Earn binding converts the private asset. */
const routerPool = (profile: EarnDeploymentProfile) => profile.zoneRouter?.earn?.pool

export const deployZoneRouterFactory = defineFoundryStep({
  id: 'deploy-zone-router-factory',
  authority: deployerAuthority,
  execution: 'foundry',
  project: 'router',
  summary: 'Deploy the ownerless ZoneRouterFactory the profile does not name.',
  phase: 'deployment',
  intent: ['zoneRouterFactory'],
  script: 'script/deploy/DeployZoneRouterFactory.s.sol:DeployZoneRouterFactoryScript',
  enabled: (profile) => profile.zoneRouter !== null && profile.zoneRouter.factory === undefined,
  input: (profile, _outputs, outputPath) =>
    encodeFunctionData({
      abi: deployZoneRouterFactoryScriptAbi,
      functionName: 'run',
      args: [{ expectedChainId: BigInt(profile.chainId), outputPath }],
    }),
  source: {
    output: 'zoneRouterFactory',
    contract: 'src/ZoneRouterFactory.sol:ZoneRouterFactory',
    constructorArgs: () => '0x',
  },
  async satisfied(client, _profile, outputs) {
    if (!(await deployedOutputs(client, outputs, ['zoneRouterFactory']))) return false
    // Source verification identifies the contract; this only rejects an obviously different one.
    return client
      .readContract({
        address: requiredOutput(outputs, 'zoneRouterFactory'),
        abi: zoneRouterFactoryAbi,
        functionName: 'isRouter',
        args: [zeroAddress],
      })
      .then(
        (deployed) => !deployed,
        () => false,
      )
  },
})

/** Deploys the profile's mode through the factory, which returns an existing router for it. */
export const deployZoneRouter = defineFoundryStep({
  id: 'deploy-zone-router',
  authority: deployerAuthority,
  execution: 'foundry',
  project: 'router',
  summary: 'Deploy the ZoneRouter for the profile mode through its ZoneRouterFactory.',
  phase: 'deployment',
  // A new factory deploys the same mode at a new address.
  intent: ['zoneRouterFactory', 'zoneRouter'],
  script: 'script/deploy/DeployZoneRouter.s.sol:DeployZoneRouterScript',
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
    contract: 'src/ZoneRouter.sol:ZoneRouter',
    // An Earn mode moves EarnShare; a Spend-only router never holds it, and membership grants it nothing.
    accessMember: true,
    constructorArgs: (profile, outputs) =>
      zoneRouterConstructorArgs(zoneRouterMode(profile, outputs)),
  },
  async satisfied(client, profile, outputs) {
    if (!(await deployedOutputs(client, outputs, ['zoneRouter']))) return false
    return zoneRouterBound(client, profile, outputs)
  },
  // Anyone can deploy a mode through the factory, such as Bridge's spend script listing the same
  // settler; the factory then returns that router, and its RouterDeployed event names the creation.
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
  for (let toBlock = await client.getBlockNumber(); toBlock >= 0n; toBlock -= maxLogBlockRange) {
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
        outputs: { ...outputs, zoneRouter: getAddress(router) },
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
    return `${namedFactoryCheck(profile, outputs)}The owner of PropAMM pool ${routerPool(profile)} must call setTakerAllowed(${router}, true) and setRecipientAllowed(${router}, true), and the pool must resolve that router as its own recipient. When a DirectPropAMMRebalanceController owns the pool, its owner makes both calls through controller.execute(data). Re-run the same pnpm earn deploy command; it will verify the admission onchain and continue.`
  },
  // Like gateway admission, a router from a factory the profile names is admitted only by a person.
  signerAvailable: (profile, environment, proven) =>
    Boolean(environment.DEPLOYER_PRIVATE_KEY?.trim()) && proven && !namesFactory(profile),
  probeSigner: (options) => {
    const pool = routerPool(options.profile)
    return pool ? canAdministerPool(options, pool) : Promise.resolve(false)
  },
  execute: (options, dependencies) =>
    namesFactory(options.profile)
      ? Promise.resolve(undefined)
      : admitPoolRouter(
          options,
          dependencies,
          required(routerPool(options.profile), 'Zone router conversion pool'),
          requiredOutput(options.outputs, 'zoneRouter'),
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
    const provenance = profile.zoneRouter?.factory
      ? `confirm that ZoneRouterFactory ${factory} is source verified as router/src/ZoneRouterFactory.sol, then `
      : ''
    return `Zone ${configuredZoneRouter(profile).zoneId} restricts callback gateways: its Portal administrator should ${provenance}confirm ZoneRouterFactory ${factory}.isRouter(${router}) and the mode in its RouterDeployed event, then call setGateway(${router}, true) on ${requiredOutput(outputs, 'zoneRouterPortal')}. Re-run the same pnpm earn deploy command; it will verify the registration and continue.`
  },
  // A factory the profile names is trusted only for its own answers, so a router it made is admitted
  // by a person who checked its verified source; the lifecycle admits only routers of its own factory.
  signerAvailable: (profile, environment) =>
    Boolean(environment.ZONE_ADMIN_PRIVATE_KEY?.trim()) && !namesFactory(profile),
  async execute(options, dependencies) {
    if (namesFactory(options.profile)) return undefined
    const portal = requiredOutput(options.outputs, 'zoneRouterPortal')
    const administrator = await zoneAdministrator(options, dependencies, portal)
    if (!administrator) return undefined
    const router = requiredOutput(options.outputs, 'zoneRouter')
    if (await zoneCallbackGatewayRegistered(administrator.client, portal, router))
      return { transactions: [] }
    return administrator.send([
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
