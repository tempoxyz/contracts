import { demoStablecoinFunderAbi, propAMMPoolAbi } from '@tempoxyz/earn/abis'
import type { EngineKind } from '@tempoxyz/earn/deployments'
import { custom, type Address, type Hex, type PublicClient } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { Abis, createClient as createTempoClient } from 'viem/tempo'

import * as Config from '../config.js'
import * as Foundry from '../foundry.js'
import { localEngines } from '../engines/index.js'
import { expectAddress } from '../engines/local-engine.js'

/** Per-token inventory of the router and PropAMM engine pools; local cases convert a few units. */
export const routerPoolInventory = 100_000n * 10n ** 6n

/** The fixtures one deployer provisions around an Earn stack, in the order they were deployed. */
export type Fixtures = {
  /** The vault asset: the disposable base stablecoin, or the existing asset the caller named. */
  baseAsset: Address
  /**
   * The disposable stablecoin pair, absent over an existing base asset. `funder` is the
   * `DemoStablecoinFunder`: sole issuer of both tokens, whose permissionless
   * `fund(token, receiver, amount)` mints either.
   */
  stablecoins?: { funder: Address; alternateAsset: Address } | undefined
  /** The router's DirectPropAMM conversion pool, funded and open; present when requested. */
  routerPool?: ConversionPool | undefined
  /** The venue the engine kind's `provision` returned. */
  vault: Address
  /** The engine `provision` deployed; absent when the lifecycle provisions it through a factory. */
  engine?: Address | undefined
  /** Engine-specific fixtures beside the venue and engine; see `LocalEngine.provision`. */
  engineFixtures: Readonly<Record<string, Address>>
  receipts: Foundry.Receipt[]
}

/** A DirectPropAMM pool that converts the alternate and base stablecoins at par. */
export type ConversionPool = { pool: Address; oracle: Address; registry: Address }

/**
 * Provisions an engine's venue over a base asset, one Forge step per transaction, on the disposable
 * chain or, with `persistent`, a hosted one. Without `baseAsset` it first deploys the stablecoin
 * pair and its funder, and with `conversionPool` the router's pool, funded and unpaused.
 */
export async function provisionFixtures(options: provisionFixtures.Options): Promise<Fixtures> {
  const receipts: Foundry.Receipt[] = []
  const deploy = async (step: Foundry.Step) => {
    const deployment = await Foundry.deploy({ ...options, step })
    receipts.push(deployment.receipt)
    options.onStep?.(step.name, deployment.address)
    return deployment
  }
  const deployAsEngineOwner = async (step: Foundry.Step) => {
    if (!options.engineOwnerPrivateKey) throw new Error(`${step.name} needs an engine setup owner`)
    const deployment = await Foundry.deploy({
      ...options,
      account: privateKeyToAccount(options.engineOwnerPrivateKey).address,
      privateKey: options.engineOwnerPrivateKey,
      step,
    })
    receipts.push(deployment.receipt)
    options.onStep?.(step.name, deployment.address)
    return deployment
  }
  const run = async (step: Foundry.Step) => {
    const receipt = await Foundry.run({ ...options, step })
    receipts.push(receipt)
    options.onStep?.(step.name)
    return receipt
  }

  let baseAsset = options.baseAsset
  let stablecoins: Fixtures['stablecoins']
  if (!baseAsset) {
    const nonce = options.saltNonce ?? 0n
    const funder = await deploy(Foundry.earnFixture('stablecoinFunder', [nonce]))
    // Creating both tokens needs the raw estimate; see `StepOptions.rawGasEstimate`.
    await run(Foundry.earnFixture('stablecoins', [funder.address, nonce], { rawGasEstimate: true }))
    const contract = { address: funder.address, abi: demoStablecoinFunderAbi } as const
    const [base, alternateAsset] = await Promise.all([
      options.client.readContract({ ...contract, functionName: 'baseAsset' }),
      options.client.readContract({ ...contract, functionName: 'alternateAsset' }),
    ])
    baseAsset = base
    stablecoins = { funder: funder.address, alternateAsset }
  }

  // Stateful TIP-20 mints go through viem Tempo transactions; see the localnet reference.
  const wallet = createTempoClient({
    account: privateKeyToAccount(options.privateKey),
    chain: options.client.chain,
    transport: custom(options.client),
  })
  const fundInventory = async (token: Address, receiver: Address, label: string) => {
    if (!stablecoins) throw new Error(`${label} funding needs the stablecoin funder`)
    const hash = await wallet.writeContract({
      address: stablecoins.funder,
      abi: demoStablecoinFunderAbi,
      functionName: 'fund',
      args: [token, receiver, routerPoolInventory],
      feeToken: Config.address.pathUsd,
    })
    const receipt = await options.client.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success') throw new Error(`${label} funding failed`)
    receipts.push(receipt)
    options.onStep?.(`${label} funding`)
  }

  let routerPool: ConversionPool | undefined
  if (options.conversionPool) {
    if (!stablecoins) throw new Error('The router conversion pool needs the stablecoin pair')
    const oracle = await deploy(Foundry.earnFixture('routerPoolOracle', []))
    const registry = await deploy(Foundry.earnFixture('routerPoolRegistry', []))
    const pool = await deploy(
      Foundry.earnFixture('routerPool', [
        stablecoins.alternateAsset,
        baseAsset,
        oracle.address,
        registry.address,
      ]),
    )
    // Redeem output is private-asset inventory; deposit output is vault-asset inventory.
    await fundInventory(stablecoins.alternateAsset, pool.address, 'Router pool private-asset')
    await fundInventory(baseAsset, pool.address, 'Router pool vault-asset')
    await run(Foundry.earnFixture('routerPoolUnpause', [pool.address]))
    routerPool = { pool: pool.address, oracle: oracle.address, registry: registry.address }
  }

  const venue = await localEngines[options.engineKind].provision({
    baseAsset,
    funder: stablecoins?.funder,
    persistent: options.persistent ?? false,
    deploy,
    deployAsEngineOwner,
    run,
    inventory: routerPoolInventory,
    fundInventory,
  })
  return {
    baseAsset,
    ...(stablecoins ? { stablecoins } : {}),
    ...(routerPool ? { routerPool } : {}),
    ...venue,
    receipts,
  }
}

export declare namespace provisionFixtures {
  type Options = Omit<Foundry.deploy.Options, 'step'> & {
    engineKind: EngineKind
    /** An existing vault asset, such as canonical PATHUSD, instead of the stablecoin pair. */
    baseAsset?: Address | undefined
    /** Separates the pairs one deployer creates on a persistent chain; zero by default. */
    saltNonce?: bigint | undefined
    /** Also deploys the router's DirectPropAMM conversion pool over the stablecoin pair. */
    conversionPool: boolean
    /** Provisions a test fixture for a persistent hosted chain; see `ProvisionContext`. */
    persistent?: boolean | undefined
    /** The funded key of a disposable chain's engine setup owner; see `ProvisionContext`. */
    engineOwnerPrivateKey?: Hex | undefined
    /** Reports each completed step and the address it deployed. */
    onStep?: ((name: string, address?: Address) => void) | undefined
  }
}

/**
 * Checks provisioned fixtures before any stack binds them: code at every fixture address, a funder
 * that issues exactly the stablecoin pair, an unpaused conversion pool over that pair with its own
 * oracle and registry and owned by `owner`, and the engine's own fixture bindings.
 */
export async function validateFixtures(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  engineKind: EngineKind,
  fixtures: Omit<Fixtures, 'receipts'>,
  owner: Address,
) {
  const { baseAsset, stablecoins, routerPool } = fixtures
  const addresses = {
    baseAsset,
    vault: fixtures.vault,
    ...(fixtures.engine ? { engine: fixtures.engine } : {}),
    ...stablecoins,
    ...routerPool,
    ...fixtures.engineFixtures,
  }
  for (const [name, address] of Object.entries(addresses)) {
    const code = await client.getCode({ address })
    if (!code || code === '0x') throw new Error(`Fixture ${name} has no code at ${address}`)
  }
  if (stablecoins) {
    const funder = { address: stablecoins.funder, abi: demoStablecoinFunderAbi } as const
    const [funderBase, funderAlternate, ...issuers] = await Promise.all([
      client.readContract({ ...funder, functionName: 'baseAsset' }),
      client.readContract({ ...funder, functionName: 'alternateAsset' }),
      ...[baseAsset, stablecoins.alternateAsset].map(async (token) =>
        client.readContract({
          address: token,
          abi: Abis.tip20,
          functionName: 'hasRole',
          args: [
            stablecoins.funder,
            await client.readContract({
              address: token,
              abi: Abis.tip20,
              functionName: 'ISSUER_ROLE',
            }),
          ],
        }),
      ),
    ])
    expectAddress(funderBase, baseAsset, 'Funder base asset')
    expectAddress(funderAlternate, stablecoins.alternateAsset, 'Funder alternate asset')
    if (!issuers.every(Boolean)) throw new Error('Funder is missing ISSUER_ROLE on a fixture token')
  }
  if (routerPool) {
    if (!stablecoins) throw new Error('The router conversion pool needs the stablecoin pair')
    const pool = { address: routerPool.pool, abi: propAMMPoolAbi } as const
    const [base, quote, oracle, registry, poolOwner, paused] = await Promise.all([
      client.readContract({ ...pool, functionName: 'baseToken' }),
      client.readContract({ ...pool, functionName: 'quoteToken' }),
      client.readContract({ ...pool, functionName: 'oracle' }),
      client.readContract({ ...pool, functionName: 'addressRegistry' }),
      client.readContract({ ...pool, functionName: 'owner' }),
      client.readContract({ ...pool, functionName: 'paused' }),
    ])
    expectAddress(base, stablecoins.alternateAsset, 'Conversion pool base token')
    expectAddress(quote, baseAsset, 'Conversion pool quote token')
    expectAddress(oracle, routerPool.oracle, 'Conversion pool oracle')
    expectAddress(registry, routerPool.registry, 'Conversion pool recipient registry')
    expectAddress(poolOwner, owner, 'Conversion pool owner')
    if (paused) throw new Error('Conversion pool is paused')
  }
  await localEngines[engineKind].validate?.(client, fixtures)
}
