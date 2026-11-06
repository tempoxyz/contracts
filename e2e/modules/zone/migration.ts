import { Abis, Actions as TempoActions } from 'viem/tempo'
import { encodeFunctionData, parseEventLogs, type Address, type Hex } from 'viem'
import { simulateCalls } from 'viem/actions'
import { earnVaultAbi, morphoFeeWrapperAbi, simple4626VaultAbi } from '@tempoxyz/contracts/abis'
import { e2eEngines } from '../../engines/index.js'
import { requireE2eZone, type E2eContext, type E2eZoneContext } from '../../harness/context.js'
import { E2ePrerequisiteError, TIMEOUT_MS, assert } from '../../harness/support/utils.js'
import {
  approve,
  mintVaultAsset,
  tokenBalance,
  tokenSupply,
} from '../../harness/support/funding.js'
import { minimumOutput, previewEarnDeposit } from '../../harness/support/slippage.js'
import { write } from '../../harness/support/transactions.js'
import { accrueFees, depositIntoVenue } from '../../harness/support/public.js'
import { waitForZoneCredit, zoneBalance } from './actions.js'
import { portalDeposit, waitForDepositDelivery } from './delivery.js'
import { ensureZoneReady } from './readiness.js'

const MIGRATION_ASSETS = 1_000_000n

/**
 * Creates ordinary venue shares, then atomically converts and privately deposits
 * them through one four-call Tempo transaction.
 */
export async function migrateExistingVenueSharesToZone(context: E2eContext) {
  requireE2eZone(context)
  const deployment = context.deployment
  if (!deployment.capabilities.inKindDeposit) {
    throw new E2ePrerequisiteError(
      'The selected v1 deployment does not advertise direct venue-share entry',
    )
  }

  const { earnVault, engine, earnShare, venue } = deployment.contracts
  await ensureZoneReady(context)
  await mintVaultAsset(context, MIGRATION_ASSETS)
  const { venueShares } = await depositIntoVenue(context, {
    assets: MIGRATION_ASSETS,
    receiver: context.user.address,
  })
  assert(venueShares > 0n, 'Migration setup minted no venue shares')

  // Settle any prior positive accrual so the quoted migration output remains exact.
  await accrueFees(context)

  const earnShares = await context.l1Public.readContract({
    address: earnVault,
    abi: earnVaultAbi,
    functionName: 'convertEngineSharesToEarnShares',
    args: [venueShares],
  })
  assert(earnShares > 0n, 'Migration quote returned no EarnShare')

  const [userVenueBefore, engineVenueBefore, publicEarnBefore, supplyBefore] = await Promise.all([
    tokenBalance(context, venue, context.user.address),
    tokenBalance(context, venue, engine),
    tokenBalance(context, earnShare, context.user.address),
    context.l1Public.readContract({
      address: earnVault,
      abi: earnVaultAbi,
      functionName: 'totalEarnShares',
    }),
  ])
  const privateEntry = await privatizeEarnShares(
    context,
    earnShares,
    TempoActions.earn.depositShares.calls({
      earnShareAmountMin: earnShares,
      engine,
      recipient: context.user.address,
      vault: earnVault,
      venueShareAmount: venueShares,
      venueShareToken: venue,
    }),
  )
  const [userVenueAfter, engineVenueAfter, publicEarnAfter, supplyAfter] = await Promise.all([
    tokenBalance(context, venue, context.user.address),
    tokenBalance(context, venue, engine),
    tokenBalance(context, earnShare, context.user.address),
    context.l1Public.readContract({
      address: earnVault,
      abi: earnVaultAbi,
      functionName: 'totalEarnShares',
    }),
  ])

  assert(
    userVenueBefore - userVenueAfter === venueShares,
    'User venue shares were not fully migrated',
  )
  assert(
    engineVenueAfter - engineVenueBefore === venueShares,
    'Engine did not receive the migrated venue shares',
  )
  assert(publicEarnAfter === publicEarnBefore, 'Migrated EarnShare remained public')
  assert(
    supplyAfter - supplyBefore === earnShares,
    'Migration minted an unexpected EarnShare amount',
  )

  return { earnShares: privateEntry.netAmount, receipt: privateEntry.receipt, venueShares }
}

/** The engine's Morpho fee-wrapper fixture, whose bindings localnet validated when deploying it. */
export function requireMorphoFeeWrapperMigration(context: E2eContext) {
  const morphoFeeWrapper = e2eEngines[context.engineKind].morphoFeeWrapper?.(context)
  if (!morphoFeeWrapper) {
    throw new E2ePrerequisiteError(
      'This case requires the disposable local Morpho fee-wrapper fixture',
    )
  }
  return morphoFeeWrapper
}

/**
 * Approves an exact Morpho fee-wrapper balance, then atomically redeems it through
 * the source wrapper, deposits into EarnVault, and privately deposits the replacement EarnShare.
 */
export async function migrateMorphoFeeWrapperToPrivateEarn(context: E2eContext) {
  requireE2eZone(context)
  const position = await createMorphoFeeWrapperPosition(context)
  const migration = await prepareExistingMorphoFeeWrapperMigration(
    context,
    position.morphoFeeWrapper,
  )
  const before = await morphoFeeWrapperMigrationState(context, migration.morphoFeeWrapper)
  const privateEntry = await privatizeEarnShares(context, migration.earnShares, migration.calls)
  const after = await morphoFeeWrapperMigrationState(context, migration.morphoFeeWrapper)
  const result = assertMorphoFeeWrapperMigrationSucceeded(before, after, migration, privateEntry)
  // Dust must cover both Portal fees; otherwise keep it explicitly accounted for publicly.
  let privateEarnShares = privateEntry.netAmount
  if (await canPrivatizeMigrationDust(context, result.publicDust)) {
    const publicBefore = await tokenBalance(
      context,
      context.contracts.earnShare,
      context.user.address,
    )
    const dustEntry = await privatizeEarnShares(context, result.publicDust)
    privateEarnShares += dustEntry.netAmount
    const publicAfter = await tokenBalance(
      context,
      context.contracts.earnShare,
      context.user.address,
    )
    assert(
      publicBefore - publicAfter === result.publicDust,
      'Migration rounding dust remained public',
    )
  }

  return {
    assets: migration.assets,
    earnShares: privateEarnShares,
    morphoFeeShares: migration.morphoFeeShares,
    receipt: privateEntry.receipt,
  }
}

async function createMorphoFeeWrapperPosition(context: E2eContext) {
  const morphoFeeWrapper = requireMorphoFeeWrapperMigration(context)
  const asset = context.assets.base
  await ensureZoneReady(context)
  await mintVaultAsset(context, MIGRATION_ASSETS)
  await approve(context, context.actors.user.wallet, asset, morphoFeeWrapper, MIGRATION_ASSETS)

  const morphoFeeSharesBefore = await tokenBalance(context, morphoFeeWrapper, context.user.address)
  await write(context.actors.user.wallet, {
    address: morphoFeeWrapper,
    abi: morphoFeeWrapperAbi,
    functionName: 'deposit',
    args: [MIGRATION_ASSETS, context.user.address],
  })
  const morphoFeeSharesAfter = await tokenBalance(context, morphoFeeWrapper, context.user.address)
  assert(
    morphoFeeSharesAfter > morphoFeeSharesBefore,
    'Migration setup minted no Morpho fee-wrapper shares',
  )
  // “Migrate entire position” is a client choice: pass the holder's exact current balance.
  return { morphoFeeShares: morphoFeeSharesAfter, morphoFeeWrapper }
}

async function prepareExistingMorphoFeeWrapperMigration(
  context: E2eContext,
  morphoFeeWrapper: `0x${string}`,
) {
  requireE2eZone(context)
  const morphoFeeShares = await tokenBalance(context, morphoFeeWrapper, context.user.address)
  assert(morphoFeeShares > 0n, 'User has no Morpho fee-wrapper position to migrate')

  // Fix the current Earn conversion anchor before quoting the replacement entry.
  await accrueFees(context)

  const assets = await context.l1Public.readContract({
    address: morphoFeeWrapper,
    abi: morphoFeeWrapperAbi,
    functionName: 'previewRedeem',
    args: [morphoFeeShares],
  })
  const quotedEarnShares = await previewEarnDeposit(context, assets)
  assert(assets > 0n, 'Morpho fee wrapper returned no redeemable assets')
  assert(quotedEarnShares > 0n, 'Replacement EarnShare quote returned zero')
  const migrationCalls = [
    {
      to: morphoFeeWrapper,
      data: encodeFunctionData({
        abi: morphoFeeWrapperAbi,
        functionName: 'redeem',
        args: [morphoFeeShares, context.user.address, context.user.address],
      }),
    },
    ...TempoActions.earn.deposit.calls({
      assetAmount: assets,
      assetToken: context.assets.base,
      recipient: context.user.address,
      shareAmountMin: minimumOutput(quotedEarnShares),
      vault: context.contracts.earnVault,
    }),
  ]
  const simulation = await simulateCalls(context.l1Public, {
    account: context.user.address,
    calls: migrationCalls,
    validation: false,
  })
  const simulationFailure = simulation.results.find((result) => result.status === 'failure')
  if (simulationFailure) {
    throw simulationFailure.error ?? new Error('Morpho migration prefix simulation failed')
  }
  const simulatedDeposits = parseEventLogs({
    abi: earnVaultAbi,
    eventName: 'Deposited',
    logs: simulation.results.flatMap((result) => result.logs ?? []),
    strict: true,
  })
  assert(
    simulatedDeposits.length === 1,
    'Migration prefix simulation emitted an unexpected deposit count',
  )
  const earnShares = simulatedDeposits[0].args.earnShares
  assert(
    earnShares >= minimumOutput(quotedEarnShares),
    'Migration prefix simulation missed the quoted EarnShare minimum',
  )
  return { assets, calls: migrationCalls, earnShares, morphoFeeShares, morphoFeeWrapper }
}

function assertMorphoFeeWrapperMigrationSucceeded(
  before: Awaited<ReturnType<typeof morphoFeeWrapperMigrationState>>,
  after: Awaited<ReturnType<typeof morphoFeeWrapperMigrationState>>,
  migration: Awaited<ReturnType<typeof prepareExistingMorphoFeeWrapperMigration>>,
  entry: Awaited<ReturnType<typeof privatizeEarnShares>>,
) {
  assert(
    before.userMorphoFeeShares - after.userMorphoFeeShares === migration.morphoFeeShares,
    'User Morpho fee-wrapper shares were not fully burned',
  )
  assert(after.morphoWrapperSupply === 0n, 'Morpho fee-wrapper supply remained after migration')
  assert(after.morphoWrapperAssets === 0n, 'Morpho fee wrapper retained managed assets')
  assert(after.morphoWrapperVenueShares === 0n, 'Morpho fee wrapper retained vault shares')
  const engineVenueSharesReceived = after.engineVenueShares - before.engineVenueShares
  assert(engineVenueSharesReceived > 0n, 'Engine received no replacement vault shares')
  assert(
    engineVenueSharesReceived <= before.morphoWrapperVenueShares,
    'Migration inflated replacement vault-share custody',
  )
  const venueShareRoundingLoss = before.morphoWrapperVenueShares - engineVenueSharesReceived
  assert(
    before.venueSupply - after.venueSupply === venueShareRoundingLoss,
    'Venue share-supply delta does not match source redemption and replacement entry',
  )
  assert(
    venueShareRoundingLoss < before.morphoWrapperVenueShares,
    'Migration lost the complete replacement venue-share position',
  )
  assert(after.venueAssets === before.venueAssets, 'Migration changed venue managed assets')
  assert(after.earnVaultAssets === before.earnVaultAssets, 'EarnVault retained base assets')
  assert(after.earnVaultVenueShares === before.earnVaultVenueShares, 'EarnVault held venue shares')
  // The source-vault redemption executes before the earnVault deposit and can move the shared
  // venue's assets-per-share by a rounding unit. The preview is therefore a bound, while the
  // earnVault event is the authoritative principal output. The total supply delta can additionally
  // include fee EarnShare crystallized immediately before the principal mint.
  const depositEvents = parseEventLogs({
    abi: earnVaultAbi,
    eventName: 'Deposited',
    logs: entry.receipt.logs,
    strict: true,
  })
  assert(depositEvents.length === 1, 'Migration emitted an unexpected earnVault deposit count')
  const mintedEarnShares = depositEvents[0].args.earnShares
  const privateEarnShares = after.privateEarn - before.privateEarn
  const publicDust = after.publicEarn - before.publicEarn
  assert(
    mintedEarnShares >= minimumOutput(migration.earnShares),
    'Migration minted less EarnShare than its independent minimum bound',
  )
  assert(
    after.earnShareSupply - before.earnShareSupply >= mintedEarnShares,
    'Migration supply delta did not include its principal EarnShare mint',
  )
  assertPrivateMigrationCredit({
    privateEarnShares,
    netAmount: entry.netAmount,
    fee: entry.fee,
    publicDust,
    mintedEarnShares,
  })
  return { mintedEarnShares, publicDust }
}

/**
 * Sends `prefixCalls` and an encrypted Zone deposit of `amount` EarnShare to the user's own Zone
 * balance in one atomic Tempo transaction, then waits for that exact private credit.
 */
async function privatizeEarnShares(
  context: E2eContext,
  amount: bigint,
  prefixCalls: readonly { to: Address; data: Hex }[] = [],
) {
  requireE2eZone(context)
  const { user } = context
  const prepared = await TempoActions.zone.encryptedDeposit.prepare(context.l1Public, {
    amount,
    tempoRefundRecipient: user.address,
    recipient: user.address,
    sender: user.address,
    token: context.contracts.earnShare,
    portalAddress: context.deployment.network.zone.portal,
    zoneId: context.deployment.network.zone.id,
  })
  const before = await zoneBalance(context, context.contracts.earnShare, 'user')
  const fromBlock = await context.actors.user.zone.client.getBlockNumber()
  const submitted = await context.actors.user.wallet.sendTransactionSync({
    account: user,
    calls: [...prefixCalls, ...TempoActions.zone.encryptedDeposit.calls(prepared)],
    chain: context.actors.user.wallet.chain,
    forceAtomic: true,
    throwOnFailure: true,
    timeout: TIMEOUT_MS,
  })
  const receipt =
    submitted.status === 'pending'
      ? await context.l1Public.waitForTransactionReceipt({
          hash: submitted.transactionHash,
          timeout: TIMEOUT_MS,
        })
      : submitted
  assert(receipt.status === 'success', 'Private migration has no successful Portal receipt')
  const deposit = portalDeposit(receipt.logs, {
    portal: context.deployment.network.zone.portal,
    sender: user.address,
    token: context.contracts.earnShare,
    gross: amount,
  })
  await waitForDepositDelivery(context, {
    hash: deposit.hash,
    token: context.contracts.earnShare,
    sender: user.address,
    recipient: user.address,
    amount: deposit.netAmount,
    fromBlock,
  })
  await waitForZoneCredit(context, {
    token: context.contracts.earnShare,
    before,
    expected: deposit.netAmount,
    exact: true,
    message: 'Zone did not credit the privatized EarnShare',
  })
  return { receipt, ...deposit }
}

async function morphoFeeWrapperMigrationState(
  context: E2eContext,
  morphoFeeWrapper: `0x${string}`,
) {
  const { earnVault, engine, earnShare, venue } = context.contracts
  const asset = context.assets.base
  const [
    userMorphoFeeShares,
    morphoWrapperSupply,
    morphoWrapperAssets,
    morphoWrapperVenueShares,
    engineVenueShares,
    venueSupply,
    venueAssets,
    earnVaultAssets,
    earnVaultVenueShares,
    publicEarn,
    earnShareSupply,
    privateEarn,
  ] = await Promise.all([
    tokenBalance(context, morphoFeeWrapper, context.user.address),
    tokenSupply(context, morphoFeeWrapper),
    context.l1Public.readContract({
      address: morphoFeeWrapper,
      abi: morphoFeeWrapperAbi,
      functionName: 'totalAssets',
    }),
    tokenBalance(context, venue, morphoFeeWrapper),
    tokenBalance(context, venue, engine),
    tokenSupply(context, venue),
    context.l1Public.readContract({
      address: venue,
      abi: simple4626VaultAbi,
      functionName: 'totalAssets',
    }),
    tokenBalance(context, asset, earnVault),
    tokenBalance(context, venue, earnVault),
    tokenBalance(context, earnShare, context.user.address),
    context.l1Public.readContract({
      address: earnVault,
      abi: earnVaultAbi,
      functionName: 'totalEarnShares',
    }),
    zoneBalance(context, earnShare, 'user'),
  ])
  return {
    earnVaultAssets,
    earnVaultVenueShares,
    earnShareSupply,
    engineVenueShares,
    morphoWrapperAssets,
    morphoWrapperSupply,
    morphoWrapperVenueShares,
    privateEarn,
    publicEarn,
    userMorphoFeeShares,
    venueAssets,
    venueSupply,
  }
}

/** Accounts for the private position separately from gross issuance, the recorded Portal fee and public dust. */
export function assertPrivateMigrationCredit(options: {
  privateEarnShares: bigint
  netAmount: bigint
  fee: bigint
  publicDust: bigint
  mintedEarnShares: bigint
}) {
  assert(
    options.privateEarnShares === options.netAmount &&
      options.fee >= 0n &&
      options.privateEarnShares + options.fee + options.publicDust === options.mintedEarnShares,
    'Replacement EarnShare was not fully attributable to private credit, Portal fee and public rounding dust',
  )
  assert(
    options.publicDust >= 0n && options.publicDust <= 1n,
    'Migration public rounding dust is outside its bound',
  )
}

/** Keeps migration dust public unless it exceeds the Portal's minimum deposit. */
export async function canPrivatizeMigrationDust(context: E2eZoneContext, amount: bigint) {
  if (amount <= 0n) return false
  const blockNumber = await context.l1Public.getBlockNumber({ cacheTime: 0 })
  const [depositFee, bouncebackFee] = await Promise.all([
    context.l1Public.readContract({
      address: context.deployment.network.zone.portal,
      abi: Abis.zonePortal,
      functionName: 'calculateDepositFee',
      blockNumber,
    }),
    context.l1Public.readContract({
      address: context.deployment.network.zone.portal,
      abi: Abis.zonePortal,
      functionName: 'calculateBouncebackFee',
      blockNumber,
    }),
  ])
  return amount > depositFee + bouncebackFee
}
