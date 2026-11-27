import {
  erc20Abi,
  getAddress,
  isAddressEqual,
  toFunctionSelector,
  zeroAddress,
  zeroHash,
  type Address,
  type PublicClient,
} from 'viem'
import {
  managedPropAMMEngineAbi,
  managedPropAMMPoolAbi,
  managedPropAMMPoolFactoryAbi,
  priceOracleAbi,
} from '../../../abis/index.js'
import { defineEngine, type EngineReadiness } from './engine.js'

// Not deployed and not registered: `ManagedPropAMMEngine` has no reviewed release, profile, localnet
// fixture or E2E cases, so this definition is absent from the engine registry in `index.ts` and no
// lifecycle step reaches it. See `docs/earn/modules/propamm.md#managed-pools`.

// Operational reads only. Caller transactions continue to use viem/tempo's Earn actions.
const requiredInterfaces = [
  [
    'asset()',
    'deposit(uint256)',
    'earnVault()',
    'name()',
    'shareScale()',
    'symbol()',
    'totalShares()',
    'totalAssets()',
    'valueOf(uint256)',
  ],
  ['previewWithdraw(uint256)', 'withdraw(uint256,address)'],
  ['previewRedeem(uint256)', 'redeem(uint256,address,uint256)'],
  ['isFeeValuationFresh()'],
].map(
  (signatures) =>
    `0x${signatures
      .reduce((id, signature) => id ^ BigInt(toFunctionSelector(signature)), 0n)
      .toString(16)
      .padStart(8, '0')}` as const,
)

/** The pool's `TakerAccess` outcomes that block a swap, by ordinal; 1 is `Allowed`. */
const accessBlockers: Record<number, string> = {
  2: 'pair is unknown or removed',
  3: 'pair is closed',
  4: 'engine is on the pool deny list',
  5: 'sponsor is not registered',
  6: 'sponsor is disabled',
  7: 'pair does not admit the sponsor',
  8: 'engine is not on the access list',
}

/** Canonical bindings plus a live deposit-readiness snapshot; neither is a liquidity guarantee. */
export async function inspectManagedPropAMMEngine(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  engine: Address,
  mode: 'ready' | 'bindings' = 'ready',
) {
  const read = { address: engine, abi: managedPropAMMEngineAbi } as const
  const [
    asset,
    baseToken,
    pool,
    settler,
    pairIndex,
    sponsorId,
    oracle,
    maxAge,
    priceScale,
    shareScale,
    customerId,
  ] = await Promise.all([
    client.readContract({ ...read, functionName: 'asset' }),
    client.readContract({ ...read, functionName: 'baseToken' }),
    client.readContract({ ...read, functionName: 'pool' }),
    client.readContract({ ...read, functionName: 'settler' }),
    client.readContract({ ...read, functionName: 'pairIndex' }),
    client.readContract({ ...read, functionName: 'sponsorId' }),
    client.readContract({ ...read, functionName: 'priceOracle' }),
    client.readContract({ ...read, functionName: 'maxOracleAge' }),
    client.readContract({ ...read, functionName: 'priceScale' }),
    client.readContract({ ...read, functionName: 'shareScale' }),
    client.readContract({ ...read, functionName: 'customerId' }),
  ])
  for (const [label, address] of Object.entries({ asset, baseToken, pool, settler, oracle })) {
    const code = await client.getCode({ address })
    if (!code || code === '0x') throw new Error(`Managed PropAMM ${label} has no runtime code`)
  }
  const venue = { address: pool, abi: managedPropAMMPoolAbi } as const
  const [
    pair,
    factory,
    poolSettler,
    assetDecimals,
    baseDecimals,
    oracleDecimals,
    paused,
    fresh,
    interfaces,
  ] = await Promise.all([
    client.readContract({ ...venue, functionName: 'pair', args: [pairIndex] }),
    client.readContract({ ...venue, functionName: 'factory' }),
    client.readContract({ ...venue, functionName: 'settler' }),
    client.readContract({ address: asset, abi: erc20Abi, functionName: 'decimals' }),
    client.readContract({ address: baseToken, abi: erc20Abi, functionName: 'decimals' }),
    client.readContract({ address: oracle, abi: priceOracleAbi, functionName: 'decimals' }),
    client.readContract({ ...venue, functionName: 'paused' }),
    client.readContract({ ...read, functionName: 'isFeeValuationFresh' }),
    Promise.all(
      requiredInterfaces.map((id) =>
        client.readContract({ ...read, functionName: 'supportsInterface', args: [id] }),
      ),
    ),
  ])
  // An unknown or removed pair reads all zero, so it matches no token.
  if (pair.access === 0 || pair.base === zeroAddress)
    throw new Error(`Managed PropAMM pool has no live pair ${pairIndex}`)
  if (
    getAddress(pair.base) !== getAddress(baseToken) ||
    getAddress(pair.quote) !== getAddress(asset) ||
    getAddress(asset) === getAddress(baseToken)
  )
    throw new Error('Managed PropAMM pair token bindings do not match engine')
  if (getAddress(pair.oracle) !== getAddress(oracle))
    throw new Error('Managed PropAMM pair oracle differs from immutable engine oracle')
  const exponent = baseDecimals + oracleDecimals - assetDecimals
  if (baseDecimals > 77 || exponent < 0 || exponent > 77)
    throw new Error('Managed PropAMM unsupported decimals')
  if (
    pair.baseDecimals !== baseDecimals ||
    pair.quoteDecimals !== assetDecimals ||
    pair.oracleDecimals !== oracleDecimals
  )
    throw new Error('Managed PropAMM pair decimals differ from its tokens and oracle')
  if (shareScale !== 10n ** BigInt(baseDecimals))
    throw new Error('Managed PropAMM share scale mismatch')
  if (priceScale !== 10n ** BigInt(exponent) || pair.priceScale !== priceScale)
    throw new Error('Managed PropAMM oracle scale mismatch')
  if (maxAge === 0n || pair.maxOracleAge === 0n)
    throw new Error('Managed PropAMM oracle windows must be nonzero')
  if (customerId === zeroHash) throw new Error('Managed PropAMM route identifier is zero')
  if (interfaces.some((supported) => !supported))
    throw new Error('Managed PropAMM engine lacks required synchronous or fee-valuation capability')
  // The engine swaps only through its immutable settler: the default Settler of the factory that
  // created the pool, which fills no other pool.
  if (factory === zeroAddress)
    throw new Error('Managed PropAMM pool has no factory, so no Settler settles its swaps')
  const poolFactory = { address: factory, abi: managedPropAMMPoolFactoryAbi } as const
  const [defaultSettler, created] = await Promise.all([
    client.readContract({ ...poolFactory, functionName: 'defaultSettler' }),
    client.readContract({ ...poolFactory, functionName: 'isPool', args: [pool] }),
  ])
  if (!created) throw new Error('Managed PropAMM pool was not created by the factory it names')
  if (!isAddressEqual(defaultSettler, settler))
    throw new Error('Managed PropAMM engine settler differs from the pool factory default Settler')
  // Only a live pair has a hook and an access outcome to read.
  const [[hook], access] = await Promise.all([
    client.readContract({ ...venue, functionName: 'pairHook', args: [pairIndex] }),
    client.readContract({
      ...venue,
      functionName: 'takerAccess',
      args: [pairIndex, engine, sponsorId],
    }),
  ])
  const blockers: string[] = []
  if (paused) blockers.push('pool is paused')
  // The pool's owner can move the pool to another settler. The pool then refuses the engine's Settler,
  // so every trade reverts with the pool's `NotSettler`; the engine itself does not read the pool's
  // settler, so only this inspection shows the change before a trade fails.
  if (!isAddressEqual(poolSettler, settler)) blockers.push('pool settler is not the engine settler')
  if (access !== 1) blockers.push(accessBlockers[access] ?? 'engine is not admitted as taker')
  // The engine values its base tokens at the oracle price and takes no deposit through a pair with a hook.
  if (hook !== zeroAddress) blockers.push('pair has a hook')
  if (!fresh) blockers.push('fee valuation is stale')
  const readiness: EngineReadiness = {
    scope: 'deposit',
    status: blockers.length === 0 ? 'ready' : 'blocked',
    blockers,
    warnings:
      pair.maxOracleAge > maxAge
        ? [
            'Pair accepts older prices than the engine; engine admission still enforces its own freshness window.',
          ]
        : pair.maxOracleAge < maxAge
          ? [
              'Pair enforces a shorter freshness window; simulate the intended deposit to validate pool freshness and execution.',
            ]
          : [],
  }
  if (mode === 'ready' && blockers.length > 0)
    throw new Error(`Managed PropAMM deposits unavailable: ${blockers.join('; ')}`)
  return {
    asset,
    baseToken,
    pool,
    settler,
    pairIndex,
    sponsorId,
    oracle,
    maxOracleAge: maxAge,
    customerId,
    readiness,
  }
}

/**
 * An oracle-priced base token bought through one pair of a managed pool; see
 * `docs/earn/modules/propamm.md#managed-pools`. Not deployed: the definition is not in the registry.
 */
export const managedPropamm = defineEngine({
  label: 'Managed PropAMM',
  engineContract: 'ManagedPropAMMEngine',
  engineSource: 'src/earn/engines/propamm/ManagedPropAMMEngine.sol',
  venueLabel: 'PropAMM base token',
  idleAssetResidue: true,
  periphery: [],
  capabilities: {
    inKindDeposit: false,
    redeem: true,
    boundedRedeem: true,
    exactWithdraw: true,
    asyncRedeem: false,
  },
  // Only a managed engine names a pair; the single-pair engine has no such read and reverts.
  recognizes: async (client, engine) =>
    (await client.readContract({
      address: engine,
      abi: managedPropAMMEngineAbi,
      functionName: 'pairIndex',
    })) >= 0,
  shareScale: (client, engine) =>
    client.readContract({
      address: engine,
      abi: managedPropAMMEngineAbi,
      functionName: 'shareScale',
    }),
  readVenue: (client, engine) =>
    client.readContract({
      address: engine,
      abi: managedPropAMMEngineAbi,
      functionName: 'baseToken',
    }),
  inspectBindings: async (client, engine, mode) =>
    (await inspectManagedPropAMMEngine(client, engine, mode)).readiness,
  /** The exact base-token purchase the engine's deposit executes. */
  quoteDeposit: (client, { engine }, assets) =>
    quoteManagedPropAMMRoute(client, engine, false, assets),
})

/**
 * Quotes the engine's own route on its pair, including its accrued rounding credit: a base-token
 * purchase, or with `sell` a base-token sale for the asset.
 */
export async function quoteManagedPropAMMRoute(
  client: Pick<PublicClient, 'readContract'>,
  engine: Address,
  sell: boolean,
  amountIn: bigint,
) {
  const read = { address: engine, abi: managedPropAMMEngineAbi } as const
  const [pool, pairIndex, customerId] = await Promise.all([
    client.readContract({ ...read, functionName: 'pool' }),
    client.readContract({ ...read, functionName: 'pairIndex' }),
    client.readContract({ ...read, functionName: 'customerId' }),
  ])
  const [amountOut] = await client.readContract({
    address: pool,
    abi: managedPropAMMPoolAbi,
    functionName: 'quoteExactInputFor',
    args: [pairIndex, engine, customerId, sell, amountIn],
  })
  return amountOut
}
