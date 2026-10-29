import { zeroAddress, type ContractFunctionArgs, type ContractFunctionName } from 'viem'
import {
  deposit,
  depositIntoVenue,
  redeem,
  redeemVenueShares,
  withdrawExact,
} from '../../harness/support/public.js'
import { earnVaultAbi } from '@tempoxyz/contracts/abis'
import { E2ePrerequisiteError, assert } from '../../harness/support/utils.js'
import {
  approve,
  mintVaultAsset,
  tokenBalance,
  tokenSupply,
} from '../../harness/support/funding.js'
import { minimumOutput, previewEarnDeposit } from '../../harness/support/slippage.js'
import { expectRevertedWrite, write } from '../../harness/support/transactions.js'
import type { E2eCase, LaunchFeature } from '../../harness/case.js'
import type { E2eActor, E2eContext } from '../../harness/context.js'

const DEPOSIT = 2_000_000n
const IN_KIND = 1_000_000n
const CONTRIBUTION = 100_000n
const WITHDRAW = 400_000n

function readVault<const Name extends 'depositsPaused' | 'emergencyGuardian' | 'asyncJanitor'>(
  context: E2eContext,
  functionName: Name,
) {
  return context.l1Public.readContract({
    address: context.contracts.earnVault,
    abi: earnVaultAbi,
    functionName,
  })
}

type VaultCall<Name extends ContractFunctionName<typeof earnVaultAbi, 'nonpayable'>> = {
  functionName: Name
  args: ContractFunctionArgs<typeof earnVaultAbi, 'nonpayable', Name>
}

function vaultRequest<const Name extends ContractFunctionName<typeof earnVaultAbi, 'nonpayable'>>(
  context: E2eContext,
  call: VaultCall<Name>,
) {
  // `call` is checked against the EarnVault ABI above; the spread cannot be re-narrowed.
  return { address: context.contracts.earnVault, abi: earnVaultAbi, ...call } as never
}

/** Sends one EarnVault call as `actor`, which must succeed. */
function control<const Name extends ContractFunctionName<typeof earnVaultAbi, 'nonpayable'>>(
  context: E2eContext,
  actor: E2eActor,
  call: VaultCall<Name>,
) {
  return write(context.actors[actor].wallet, vaultRequest(context, call))
}

/** Sends one EarnVault call as `actor`, which must revert. */
function expectRejectedVaultCall<
  const Name extends ContractFunctionName<typeof earnVaultAbi, 'nonpayable'>,
>(context: E2eContext, actor: E2eActor, call: VaultCall<Name>, message: string) {
  return expectRevertedWrite(
    context,
    () => context.actors[actor].wallet.writeContract(vaultRequest(context, call)),
    message,
  )
}

async function setPaused(context: E2eContext, paused: boolean, actor: E2eActor = 'operator') {
  await control(context, actor, { functionName: 'setDepositsPaused', args: [paused] })
  assert(
    (await readVault(context, 'depositsPaused')) === paused,
    `earnVault pause readback did not become ${paused}`,
  )
}

export const launchFeatures: Record<string, LaunchFeature> = {
  'earn-vault-controls': {
    dimensions: ['positive', 'negative', 'rollback', 'authorization', 'recovery'],
    applies: () => true,
  },
}

export const cases: readonly E2eCase[] = [
  {
    id: 'controls-operator-authority',
    description:
      'Only the operator pauses, rotates emergency roles, or migrates the engine; a pause blocks every entry while exits stay live, the guardian can pause but not unpause, and invalid migrations roll back.',
    default: false,
    launch: true,
    coverage: {
      'earn-vault-controls': ['positive', 'negative', 'rollback', 'authorization', 'recovery'],
    },
    async preflight(context) {
      if (await readVault(context, 'depositsPaused')) {
        throw new E2ePrerequisiteError('EarnVault deposits are already paused')
      }
    },
    async run(context) {
      await pauseBlocksEntryButPreservesExits(context)
      await guardianCanOnlyPause(context)
      await invalidMigrationsRollBack(context)
    },
  },
]

async function pauseBlocksEntryButPreservesExits(context: E2eContext) {
  const { earnShare, earnVault, engine, venue } = context.contracts
  const wallet = context.actors.user.wallet
  await mintVaultAsset(context, DEPOSIT + IN_KIND + CONTRIBUTION)
  const position = await deposit(context, { assets: DEPOSIT, receiver: context.user.address })
  const inKind = context.deployment.capabilities.inKindDeposit
    ? await depositIntoVenue(context, { assets: IN_KIND, receiver: context.user.address })
    : undefined
  await approve(context, wallet, context.assets.base, earnVault, CONTRIBUTION)
  const entryState = () =>
    Promise.all([
      tokenSupply(context, earnShare),
      tokenBalance(context, venue, engine),
      tokenBalance(context, venue, context.user.address),
    ])
  const before = await entryState()

  try {
    await expectRejectedVaultCall(
      context,
      'user',
      { functionName: 'setDepositsPaused', args: [true] },
      'non-operator unexpectedly paused deposits',
    )
    await setPaused(context, true)
    await expectRevertedWrite(
      context,
      async () =>
        wallet.earn.deposit({
          account: context.user,
          assetAmount: CONTRIBUTION,
          recipient: context.user.address,
          shareAmountMin: minimumOutput(await previewEarnDeposit(context, CONTRIBUTION)),
          vault: earnVault,
        }),
      'paused earnVault unexpectedly accepted an asset deposit',
    )
    if (inKind) {
      const expectedInKind = await context.l1Public.readContract({
        address: earnVault,
        abi: earnVaultAbi,
        functionName: 'convertEngineSharesToEarnShares',
        args: [inKind.venueShares],
      })
      await expectRevertedWrite(
        context,
        () =>
          wallet.earn.depositShares({
            account: context.user,
            earnShareAmountMin: minimumOutput(expectedInKind),
            recipient: context.user.address,
            vault: earnVault,
            venueShareAmount: inKind.venueShares,
            venueShareToken: venue,
          }),
        'paused earnVault unexpectedly accepted an in-kind deposit',
      )
    }
    await expectRejectedVaultCall(
      context,
      'user',
      { functionName: 'contribute', args: [CONTRIBUTION] },
      'paused earnVault unexpectedly accepted a contribution',
    )
    const after = await entryState()
    assert(after[0] === before[0], 'paused entry attempts changed supply')
    assert(after[1] === before[1], 'paused entry attempts changed backing')
    assert(after[2] === before[2], 'paused in-kind entry consumed venue shares')

    const exact = await withdrawExact(context, {
      assets: WITHDRAW,
      maxEarnShares: position.earnShares,
      receiver: context.user.address,
    })
    assert(exact.earnSharesBurned > 0n, 'exact withdrawal stopped while deposits were paused')
    await redeem(context, {
      earnShares: position.earnShares - exact.earnSharesBurned,
      receiver: context.user.address,
    })
  } finally {
    await setPaused(context, false)
  }
  if (inKind) await redeemVenueShares(context, inKind.venueShares)
}

async function guardianCanOnlyPause(context: E2eContext) {
  const [guardian, janitor] = await Promise.all([
    readVault(context, 'emergencyGuardian'),
    readVault(context, 'asyncJanitor'),
  ])
  await expectRejectedVaultCall(
    context,
    'user',
    { functionName: 'setEmergencyRoles', args: [context.outsider.address, janitor] },
    'non-operator unexpectedly rotated emergency roles',
  )
  try {
    await control(context, 'operator', {
      functionName: 'setEmergencyRoles',
      args: [context.outsider.address, janitor],
    })
    await setPaused(context, true, 'outsider')
    await expectRejectedVaultCall(
      context,
      'outsider',
      { functionName: 'setDepositsPaused', args: [false] },
      'guardian unexpectedly unpaused deposits',
    )
    assert(
      await readVault(context, 'depositsPaused'),
      'failed guardian unpause changed pause state',
    )
  } finally {
    await setPaused(context, false)
    await control(context, 'operator', {
      functionName: 'setEmergencyRoles',
      args: [guardian, janitor],
    })
  }
  assert(
    (await readVault(context, 'emergencyGuardian')) === guardian,
    'emergency guardian was not restored',
  )
}

/** Unauthorized, zero-address, and same-engine migrations leave the engine and its backing. */
async function invalidMigrationsRollBack(context: E2eContext) {
  const vault = { address: context.contracts.earnVault, abi: earnVaultAbi } as const
  const state = () =>
    Promise.all([
      context.l1Public.readContract({ ...vault, functionName: 'engine' }),
      context.l1Public.readContract({ ...vault, functionName: 'engineShares' }),
      context.l1Public.readContract({ ...vault, functionName: 'totalEarnShares' }),
    ])
  const before = await state()
  for (const [actor, engine, message] of [
    ['user', context.contracts.engine, 'non-operator unexpectedly migrated the engine'],
    ['operator', zeroAddress, 'operator unexpectedly migrated to the zero address'],
    ['operator', context.contracts.engine, 'operator unexpectedly migrated to the active engine'],
  ] as const) {
    await expectRejectedVaultCall(
      context,
      actor,
      { functionName: 'migrateEngine', args: [engine, 1n, 1n] },
      message,
    )
  }
  const after = await state()
  assert(after[0] === before[0], 'rejected migration changed the active engine')
  assert(after[1] === before[1], 'rejected migration changed engine backing')
  assert(after[2] === before[2], 'rejected migration changed EarnShare supply')
}
