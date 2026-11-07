import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import {
  concat,
  getAddress,
  getCreate2Address,
  keccak256,
  parseAbi,
  zeroAddress,
  zeroHash,
  type Address,
  type Hex,
} from 'viem'
import { zoneRouterFactoryAbi } from '@tempoxyz/contracts/abis'
import * as Safety from './targets-safety.js'
import type { Program, PublicClient } from './targets.js'

const bindingsAbi = parseAbi([
  'function getSpenderAddress(bytes32 spenderId) view returns (address)',
  'function ROUTER_FACTORY() view returns (address)',
  'function PROVIDER() view returns (address)',
  'function PAYOUT_TARGET() view returns (address)',
  'function FACTORY() view returns (address)',
  'function CLONE() view returns (address)',
  'function SPENDER_ID() view returns (bytes32)',
  'function isDeployed(address program) view returns (bool)',
  'function predict(bytes32 programId, address provider) view returns (address)',
  'function portal() view returns (address)',
])

/** The only mode admitted by the card runner, not merely any router containing the program. */
export function spendMode(program: Address, zoneId: number) {
  return {
    zoneId,
    enabledOps: 4,
    earnVault: zeroAddress,
    privateAsset: zeroAddress,
    pool: zeroAddress,
    customerId: zeroHash,
    spenders: [program],
  } as const
}

// Solady LibClone's pinned minimal ERC1967 beacon proxy runtime, shared with ProgramChecks.isCanonical.
const cloneRuntime =
  '0x363d3d373d3d363d602036600436635c60da1b60e01b36527fa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50545afa5036515af43d6000803e604d573d6000fd5b3d6000f3' as const

/** Predicts the canonical proxy, not an arbitrary existing contract registered under this spender ID. */
export function canonicalBridgeClone(factory: Address, spenderId: Hex) {
  const bytecode = concat(['0x60523d8160223d3973', factory, '0x60195155f3', cloneRuntime])
  return getCreate2Address({ from: factory, salt: spenderId, bytecodeHash: keccak256(bytecode) })
}

/** Resolves the same registry entry that governorCall will mutate, before any governance send. */
export async function assertClone(
  client: PublicClient,
  program: Pick<Program, 'factory' | 'spenderId' | 'clone'>,
) {
  if (getAddress(program.clone) !== canonicalBridgeClone(program.factory, program.spenderId))
    throw new Error(
      'Recorded clone is not the canonical factory/spender ID proxy; no governance call was sent',
    )
  const clone = await client.readContract({
    address: program.factory,
    abi: bindingsAbi,
    functionName: 'getSpenderAddress',
    args: [program.spenderId],
  })
  if (getAddress(clone) !== getAddress(program.clone) || clone === zeroAddress)
    throw new Error(
      'Recorded clone does not match factory.getSpenderAddress(spenderId); no governance call was sent',
    )
  if ((await client.getCode({ address: clone }))?.toLowerCase() !== cloneRuntime)
    throw new Error(
      'Canonical clone runtime is not the pinned beacon proxy; refusing target authority',
    )
}

/** Predicts the exact mode before deployment or admission, and optionally proves its deployment. */
export async function assertRouter(
  client: PublicClient,
  program: Pick<Program, 'routerFactory' | 'router' | 'program'>,
  zoneId: number,
  deployed = true,
) {
  const predicted = await client.readContract({
    address: program.routerFactory,
    abi: zoneRouterFactoryAbi,
    functionName: 'predict',
    args: [spendMode(program.program, zoneId)],
  })
  if (getAddress(predicted) !== getAddress(program.router))
    throw new Error('Recorded router is not the exact single-spender Spend-mode prediction')
  if (
    deployed &&
    !(await client.readContract({
      address: program.routerFactory,
      abi: zoneRouterFactoryAbi,
      functionName: 'isRouter',
      args: [program.router],
    }))
  )
    throw new Error('The predicted Spend router has not been deployed by its factory')
}

/** Rebuilds trusted local sources; stale outputs or RPC-supplied membership are not release evidence. */
export function reviewedArtifacts(root: string) {
  const build = (directory: string, paths: string[], names: string[]) =>
    Safety.withReport(root, (out) => {
      const artifacts = resolve(out, '..', 'artifacts')
      execFileSync(
        'forge',
        ['build', ...paths, '--out', artifacts, '--cache-path', resolve(out, '..', 'cache')],
        {
          cwd: directory,
          stdio: 'ignore',
          env: Safety.childEnvironment({ FOUNDRY_PROFILE: 'default' }),
        },
      )
      return Object.fromEntries(
        names.map((name) => [
          name,
          JSON.parse(readFileSync(resolve(artifacts, `${name}.sol`, `${name}.json`), 'utf8')),
        ]),
      ) as Record<string, Parameters<typeof Safety.matchesRuntime>[1]>
    })
  const cards = build(
    root,
    [
      'src/core/CardFactory.sol',
      'src/providers/bridge/BridgeProvider.sol',
      '../zone-router/src/ZoneRouterFactory.sol',
    ],
    ['CardFactory', 'CardSpender', 'BridgeProvider', 'ZoneRouterFactory'],
  )
  const router = build(
    resolve(root, '../zone-router'),
    ['src/ZoneRouterFactory.sol'],
    ['ZoneRouterFactory'],
  )
  return { cards, router }
}

/** Proves reviewed factory/provider code and every binding before a persisted target receives authority. */
export async function assertProgram(
  client: PublicClient,
  program: Program,
  zoneId: number,
  artifacts: ReturnType<typeof reviewedArtifacts>,
  portal?: Address,
) {
  await assertClone(client, program)
  const code = async (address: Address) => client.getCode({ address })
  const factoryCode = await code(program.routerFactory)
  if (
    ![artifacts.cards.ZoneRouterFactory!, artifacts.router.ZoneRouterFactory!].some((artifact) =>
      Safety.matchesRuntime(factoryCode, artifact),
    )
  )
    throw new Error(
      'Router factory runtime is not a reviewed local build; refusing target authority',
    )
  for (const [name, address, values] of [
    ['CardFactory', program.cardFactory, [program.routerFactory]],
    ['BridgeProvider', program.provider, [program.factory, program.spenderId, program.clone]],
    ['CardSpender', program.program, [program.provider, program.routerFactory, program.clone]],
  ] as const) {
    if (!Safety.matchesRuntime(await code(address), artifacts.cards[name]!, values))
      throw new Error(
        `${name} runtime or immutable bindings differ from the reviewed build; refusing target authority`,
      )
  }
  // Bind each getter as well as immutable values: swapping equal-sized immutable slots is not valid.
  for (const [address, functionName, expected] of [
    [program.cardFactory, 'ROUTER_FACTORY', program.routerFactory],
    [program.provider, 'FACTORY', program.factory],
    [program.provider, 'CLONE', program.clone],
    [program.provider, 'SPENDER_ID', program.spenderId],
    [program.program, 'PROVIDER', program.provider],
    [program.program, 'PAYOUT_TARGET', program.clone],
    [program.program, 'ROUTER_FACTORY', program.routerFactory],
  ] as const) {
    const actual = await client.readContract({ address, abi: bindingsAbi, functionName })
    if (actual.toLowerCase() !== expected.toLowerCase())
      throw new Error(`Target ${functionName} binding mismatch`)
  }
  const predicted = await client.readContract({
    address: program.cardFactory,
    abi: bindingsAbi,
    functionName: 'predict',
    args: [program.spenderId, program.provider],
  })
  if (
    getAddress(predicted) !== getAddress(program.program) ||
    !(await client.readContract({
      address: program.cardFactory,
      abi: bindingsAbi,
      functionName: 'isDeployed',
      args: [program.program],
    }))
  )
    throw new Error(
      'CardFactory does not bind the recorded program to this spender ID and provider',
    )
  await assertRouter(client, program, zoneId)
  if (
    portal &&
    getAddress(
      await client.readContract({
        address: program.router,
        abi: bindingsAbi,
        functionName: 'portal',
      }),
    ) !== getAddress(portal)
  )
    throw new Error('Recorded router is bound to a different Zone portal')
}
