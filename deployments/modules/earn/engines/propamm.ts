import {
  erc20Abi,
  getAddress,
  toFunctionSelector,
  zeroHash,
  type Address,
  type PublicClient,
} from 'viem'
import { priceOracleAbi, propAMMEngineAbi, propAMMPoolAbi } from '../../../abis/index.js'
import { defineEngine, type EngineReadiness } from './engine.js'

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

/** Canonical bindings plus a live deposit-readiness snapshot; neither is a liquidity guarantee. */
export async function inspectPropAMMEngine(
  client: Pick<PublicClient, 'getCode' | 'readContract'>,
  engine: Address,
  mode: 'ready' | 'bindings' = 'ready',
) {
  const [asset, baseToken, pool, oracle, maxAge, priceScale, shareScale, customerId] =
    await Promise.all([
      client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'asset' }),
      client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'baseToken' }),
      client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'pool' }),
      client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'priceOracle' }),
      client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'maxOracleAge' }),
      client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'priceScale' }),
      client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'shareScale' }),
      client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'customerId' }),
    ])
  for (const [label, address] of Object.entries({ asset, baseToken, pool, oracle })) {
    const code = await client.getCode({ address })
    if (!code || code === '0x') throw new Error(`PropAMM ${label} has no runtime code`)
  }
  const [
    base,
    quote,
    liveOracle,
    poolMaxAge,
    assetDecimals,
    baseDecimals,
    oracleDecimals,
    paused,
    taker,
    recipient,
    resolved,
    fresh,
    interfaces,
  ] = await Promise.all([
    client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'baseToken' }),
    client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'quoteToken' }),
    client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'oracle' }),
    client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'maxOracleAge' }),
    client.readContract({ address: asset, abi: erc20Abi, functionName: 'decimals' }),
    client.readContract({ address: baseToken, abi: erc20Abi, functionName: 'decimals' }),
    client.readContract({ address: oracle, abi: priceOracleAbi, functionName: 'decimals' }),
    client.readContract({ address: pool, abi: propAMMPoolAbi, functionName: 'paused' }),
    client.readContract({
      address: pool,
      abi: propAMMPoolAbi,
      functionName: 'takerAllowed',
      args: [engine],
    }),
    client.readContract({
      address: pool,
      abi: propAMMPoolAbi,
      functionName: 'recipientAllowed',
      args: [engine],
    }),
    client.readContract({
      address: pool,
      abi: propAMMPoolAbi,
      functionName: 'resolveRecipient',
      args: [engine],
    }),
    client.readContract({
      address: engine,
      abi: propAMMEngineAbi,
      functionName: 'isFeeValuationFresh',
    }),
    Promise.all(
      requiredInterfaces.map((id) =>
        client.readContract({
          address: engine,
          abi: propAMMEngineAbi,
          functionName: 'supportsInterface',
          args: [id],
        }),
      ),
    ),
  ])
  if (
    getAddress(base) !== getAddress(baseToken) ||
    getAddress(quote) !== getAddress(asset) ||
    getAddress(asset) === getAddress(baseToken)
  )
    throw new Error('PropAMM pool token bindings do not match engine')
  if (getAddress(liveOracle) !== getAddress(oracle))
    throw new Error('PropAMM pool oracle differs from immutable engine oracle')
  const exponent = baseDecimals + oracleDecimals - assetDecimals
  if (baseDecimals > 77 || exponent < 0 || exponent > 77)
    throw new Error('PropAMM unsupported decimals')
  if (shareScale !== 10n ** BigInt(baseDecimals)) throw new Error('PropAMM share scale mismatch')
  if (priceScale !== 10n ** BigInt(exponent)) throw new Error('PropAMM oracle scale mismatch')
  if (maxAge === 0n || poolMaxAge === 0n) throw new Error('PropAMM oracle windows must be nonzero')
  if (customerId === zeroHash) throw new Error('PropAMM route identifier is zero')
  if (interfaces.some((supported) => !supported))
    throw new Error('PropAMM engine lacks required synchronous or fee-valuation capability')
  const blockers: string[] = []
  if (paused) blockers.push('pool is paused')
  if (!taker) blockers.push('engine is not admitted as taker')
  if (!recipient) blockers.push('engine is not admitted as recipient')
  if (getAddress(resolved) !== getAddress(engine)) blockers.push('engine recipient is redirected')
  if (!fresh) blockers.push('fee valuation is stale')
  const readiness: EngineReadiness = {
    scope: 'deposit',
    status: blockers.length === 0 ? 'ready' : 'blocked',
    blockers,
    warnings:
      poolMaxAge > maxAge
        ? [
            'Pool accepts older prices than the engine; engine admission still enforces its own freshness window.',
          ]
        : poolMaxAge < maxAge
          ? [
              'Pool enforces a shorter freshness window; simulate the intended deposit to validate pool freshness and execution.',
            ]
          : [],
  }
  if (mode === 'ready' && blockers.length > 0)
    throw new Error(`PropAMM deposits unavailable: ${blockers.join('; ')}`)
  return { asset, baseToken, pool, oracle, maxOracleAge: maxAge, customerId, readiness }
}

/** An oracle-priced base token bought through one pool; see `docs/earn/modules/propamm.md`. */
export const propamm = defineEngine({
  label: 'PropAMM',
  engineContract: 'PropAMMEngine',
  engineSource: 'src/engines/propamm/PropAMMEngine.sol',
  venueLabel: 'PropAMM base token',
  venueDetail: 'Oracle-priced base token',
  periphery: [],
  capabilities: {
    inKindDeposit: false,
    redeem: true,
    boundedRedeem: true,
    exactWithdraw: true,
    asyncRedeem: false,
  },
  readVenue: (client, engine) =>
    client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'baseToken' }),
  inspectBindings: async (client, engine, mode) =>
    (await inspectPropAMMEngine(client, engine, mode)).readiness,
  /** The exact base-token purchase the engine's deposit executes. */
  quoteDeposit: (client, { engine }, assets) => quotePropAMMRoute(client, engine, false, assets),
})

/**
 * Quotes the engine's own pool route, including its accrued rounding credit: a base-token purchase,
 * or with `sell` a base-token sale for the asset.
 */
export async function quotePropAMMRoute(
  client: Pick<PublicClient, 'readContract'>,
  engine: Address,
  sell: boolean,
  amountIn: bigint,
) {
  const [pool, customerId] = await Promise.all([
    client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'pool' }),
    client.readContract({ address: engine, abi: propAMMEngineAbi, functionName: 'customerId' }),
  ])
  const [amountOut] = await client.readContract({
    address: pool,
    abi: propAMMPoolAbi,
    functionName: 'quoteExactInputFor',
    args: [engine, engine, customerId, sell, amountIn],
  })
  return amountOut
}
