import { getAddress, zeroAddress, type Address, type PublicClient } from 'viem'

import { earnEngineBindingAbi, earnVaultAbi } from '../../../abis/index.js'
import type { Engine, EngineFactory, EngineStack } from './engine.js'
import { erc4626 } from './erc4626.js'
import { propamm } from './propamm.js'
import { veda } from './veda.js'

export { factoryReleaseEntryPoint, factoryReleaseStep } from './engine.js'
export type {
  Engine,
  EngineDeployInput,
  EngineFactory,
  EngineReadiness,
  EngineStack,
  PeripheryContract,
} from './engine.js'

/** Every engine kind. A new kind is its own `defineEngine` module plus one entry here. */
const registry = { erc4626, veda, propamm }

export type EngineKind = keyof typeof registry

/** Kinds the lifecycle can provision from a venue through their shared factory. */
export type FactoryEngineKind = {
  [Kind in EngineKind]: (typeof registry)[Kind] extends { factory: EngineFactory } ? Kind : never
}[EngineKind]

/** Release keys of the engine factories, e.g. `erc4626Engine`. */
export type EngineFactoryKey = (typeof registry)[FactoryEngineKind]['factory']['releaseKey']

export const engineDefinitions: Readonly<Record<EngineKind, Engine>> = registry

export const engineKinds = Object.keys(registry) as EngineKind[]

/** Every engine factory a shared release can carry, in registry order. */
export const engineFactories = engineKinds.flatMap((kind) => {
  const factory = engineDefinitions[kind].factory
  return factory ? [factory as EngineFactory & { releaseKey: EngineFactoryKey }] : []
})

type ReadClient = Pick<PublicClient, 'readContract'>

/** The venue a deployed engine holds shares of, read from the engine itself. */
export async function readEngineVenue(client: ReadClient, kind: EngineKind, engine: Address) {
  return getAddress(await engineDefinitions[kind].readVenue(client, engine))
}

/** An engine's asset, owner, and EarnVault binding, plus that EarnVault's operator once bound. */
export async function readEngineBinding(client: ReadClient, engine: Address) {
  const contract = { address: engine, abi: earnEngineBindingAbi } as const
  const [asset, owner, earnVault] = (
    await Promise.all([
      client.readContract({ ...contract, functionName: 'asset' }),
      client.readContract({ ...contract, functionName: 'owner' }),
      client.readContract({ ...contract, functionName: 'earnVault' }),
    ])
  ).map((value) => getAddress(value)) as [Address, Address, Address]
  const vaultOperator =
    earnVault === zeroAddress
      ? undefined
      : getAddress(
          await client.readContract({
            address: earnVault,
            abi: earnVaultAbi,
            functionName: 'operator',
          }),
        )
  return { asset, owner, earnVault, vaultOperator }
}

/**
 * Engine-specific binding inspection beyond the shared stack checks, returning the engine's
 * deposit readiness when it has one.
 */
export async function inspectEngineBindings(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  kind: EngineKind,
  engine: Address,
  mode: 'ready' | 'bindings' = 'bindings',
) {
  return engineDefinitions[kind].inspectBindings?.(client, engine, mode)
}

/** EarnShare a deposit of `assets` mints at the current state, through the engine's own quote. */
export async function quoteEarnDeposit(
  client: ReadClient,
  stack: { engineKind: EngineKind; contracts: EngineStack & { earnVault: Address } },
  assets: bigint,
) {
  const engineShares = await engineDefinitions[stack.engineKind].quoteDeposit(
    client,
    stack.contracts,
    assets,
  )
  return client.readContract({
    address: stack.contracts.earnVault,
    abi: earnVaultAbi,
    functionName: 'convertEngineSharesToEarnShares',
    args: [engineShares],
  })
}
