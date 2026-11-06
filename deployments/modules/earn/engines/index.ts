import { erc20Abi, getAddress, zeroAddress, type Address, type PublicClient } from 'viem'

import { earnEngineBindingAbi, earnFeesAbi, earnVaultAbi } from '../../../abis/index.js'
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
export async function readEngineBinding(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  engine: Address,
) {
  const contract = { address: engine, abi: earnEngineBindingAbi } as const
  const [asset, owner, earnVault] = (
    await Promise.all([
      client.readContract({ ...contract, functionName: 'asset' }),
      client.readContract({ ...contract, functionName: 'owner' }),
      client.readContract({ ...contract, functionName: 'earnVault' }),
    ])
  ).map((value) => getAddress(value)) as [Address, Address, Address]
  const vaultOperator = await (async () => {
    if (earnVault === zeroAddress) return undefined
    try {
      const code = await client.getCode({ address: earnVault })
      if (!code || code === '0x') throw new Error('bound address has no runtime code')
      return getAddress(
        await client.readContract({
          address: earnVault,
          abi: earnVaultAbi,
          functionName: 'operator',
        }),
      )
    } catch (cause) {
      throw new Error(
        `Engine ${engine} is already bound to ${earnVault}, which is not a readable EarnVault`,
        { cause },
      )
    }
  })()
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
  client: ReadClient & Pick<PublicClient, 'getBlockNumber'>,
  stack: { engineKind: EngineKind; contracts: EngineStack & { earnVault: Address } },
  assets: bigint,
) {
  // All venue and accrual reads use one block, so pending fees and supply cannot straddle a deposit.
  const blockNumber = await client.getBlockNumber({ cacheTime: 0 })
  const snapshot: ReadClient = {
    readContract: (parameters) => client.readContract({ ...parameters, blockNumber } as never),
  }
  const vault = { address: stack.contracts.earnVault, abi: earnVaultAbi } as const
  const [engineShares, supply, held, earnFees, currentEngine] = await Promise.all([
    engineDefinitions[stack.engineKind].quoteDeposit(snapshot, stack.contracts, assets),
    snapshot.readContract({ ...vault, functionName: 'totalEarnShares' }),
    snapshot.readContract({ ...vault, functionName: 'engineShares' }),
    snapshot.readContract({ ...vault, functionName: 'earnFees' }),
    snapshot.readContract({ ...vault, functionName: 'engine' }),
  ])
  if (getAddress(currentEngine) !== getAddress(stack.contracts.engine))
    throw new Error('EarnVault engine changed before the deposit quote; reload the stack')
  const fees = await snapshot.readContract({
    address: earnFees,
    abi: earnFeesAbi,
    functionName: 'previewAccruedFees',
  })
  const projectedSupply = supply + fees.totalFeeEarnShares
  if (projectedSupply === 0n) {
    const [engineScale, share] = await Promise.all([
      engineDefinitions[stack.engineKind].shareScale(snapshot, currentEngine),
      snapshot.readContract({ ...vault, functionName: 'earnShare' }),
    ])
    const decimals = await snapshot.readContract({
      address: share,
      abi: erc20Abi,
      functionName: 'decimals',
    })
    if (engineScale <= 0n || decimals > 77)
      throw new Error('Earn engine or share has an invalid scale')
    return (engineShares * 10n ** BigInt(decimals)) / engineScale
  }

  if (held === 0n) throw new Error('EarnVault has active supply without managed backing')
  // Deposit accrues fee shares and reanchors to managed custody before converting venue output.
  return (engineShares * projectedSupply) / held
}

/** Resolves a migrated engine's supported adapter; ambiguous or unknown interfaces fail closed. */
export async function readEngineKind(client: ReadClient, engine: Address): Promise<EngineKind> {
  const matches = await Promise.all(
    engineKinds.map(async (kind) => {
      try {
        return (await engineDefinitions[kind].recognizes(client, engine)) ? kind : undefined
      } catch {
        return undefined
      }
    }),
  )
  const supported = matches.filter((kind) => kind !== undefined)
  if (supported.length !== 1)
    throw new Error(`Current engine ${engine} has unknown or ambiguous engine interfaces`)
  return supported[0]!
}
