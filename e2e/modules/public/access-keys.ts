import {
  custom,
  encodeFunctionData,
  erc20Abi,
  isAddressEqual,
  toFunctionSelector,
  type Address,
  type Hex,
} from 'viem'
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts'
import { simulateCalls } from 'viem/actions'
import { Abis, Account, Addresses, createClient } from 'viem/tempo'
import { earnVaultAbi } from '@tempoxyz/contracts/abis'
import { deposit, depositIntoVenue, expectUnchanged, redeem } from '../../harness/support/public.js'
import { ensureFeeBalance, mintVaultAsset, tokenBalance } from '../../harness/support/funding.js'
import { minimumOutput, previewEarnDeposit } from '../../harness/support/slippage.js'
import { waitForSuccessfulWrite, write } from '../../harness/support/transactions.js'
import { assert, TIMEOUT_MS } from '../../harness/support/utils.js'
import type { E2eCase } from '../../harness/case.js'
import type { E2eContext } from '../../harness/context.js'

const AMOUNT = 1_000_000n

/**
 * Native scoped access keys that may only act for their own user: approve-and-deposit, both exits,
 * and in-kind entry each succeed only to the user and reject receiver redirection atomically.
 */
export const accessKeyCase: E2eCase = {
  id: 'public-access-key-scopes',
  environments: ['local', 'moderato'],
  default: false,
  launch: false,
  requiredCapabilities: ['redeem', 'exactWithdraw'],
  description:
    'Native scoped access keys deposit, exit, and enter in kind only for their own user, rejecting receiver redirection and other spenders atomically.',
  coverage: {
    'public-deposit': ['positive', 'negative', 'authorization', 'rollback'],
    'immediate-redeem': ['positive', 'authorization', 'rollback'],
    'exact-withdraw': ['positive', 'authorization', 'rollback'],
    'in-kind-deposit': ['positive', 'authorization'],
  },
  async run(context) {
    await scopedDeposit(context)
    await scopedExits(context)
    if (context.deployment.capabilities.inKindDeposit) await scopedInKindEntry(context)
  },
}

async function scopedDeposit(context: E2eContext) {
  const vault = context.contracts.earnVault
  await mintVaultAsset(context, 3n * AMOUNT)
  await withScopedKey(
    context,
    [
      {
        address: context.assets.base,
        selector: 'approve(address,uint256)',
        recipients: [vault],
      },
      { address: vault, selector: 'deposit(uint256,uint256)' },
    ],
    async (wallet) => {
      assert(
        isAddressEqual(wallet.account.address, context.user.address),
        'access key changed the transaction sender',
      )
      const minimum = minimumOutput(await previewEarnDeposit(context, AMOUNT))
      const depositCall = {
        to: vault,
        data: encodeFunctionData({
          abi: earnVaultAbi,
          functionName: 'deposit',
          args: [AMOUNT, minimum],
        }),
      }
      const assetBefore = await tokenBalance(context, context.assets.base, context.user.address)
      const shareBefore = await tokenBalance(
        context,
        context.contracts.earnShare,
        context.user.address,
      )
      const receiverBefore = await tokenBalance(
        context,
        context.contracts.earnShare,
        context.operator.address,
      )
      const receipt = await waitForSuccessfulWrite(
        context,
        await wallet.sendTransaction({
          feePayer: wallet.feePayer,
          calls: [approvalCall(context.assets.base, vault, AMOUNT), depositCall],
        }),
      )
      const event = context.actors.user.wallet.earn.deposit.extractEvent(receipt.logs, { vault })
      const minted =
        (await tokenBalance(context, context.contracts.earnShare, context.user.address)) -
        shareBefore
      assert(minted >= minimum && minted === event.args.earnShares, 'self deposit output mismatch')
      assert(
        isAddressEqual(event.args.caller, context.user.address) &&
          isAddressEqual(event.args.receiver, context.user.address),
        'self deposit event did not identify the user',
      )
      assert(
        (await tokenBalance(context, context.assets.base, context.user.address)) ===
          assetBefore - AMOUNT,
        'self deposit did not spend user assets',
      )
      assert(
        (await tokenBalance(context, context.contracts.earnShare, context.operator.address)) ===
          receiverBefore,
        'self deposit credited another receiver',
      )

      // The first deposit would succeed, but the final forbidden selector must reject the whole batch.
      await assertScopedRejection(context, wallet, [
        approvalCall(context.assets.base, vault, 2n * AMOUNT),
        depositCall,
        {
          to: vault,
          data: encodeFunctionData({
            abi: earnVaultAbi,
            functionName: 'deposit',
            args: [AMOUNT, context.operator.address, minimum],
          }),
        },
      ])
      await assertScopedRejection(context, wallet, [
        approvalCall(context.assets.base, context.operator.address, AMOUNT),
      ])
      await redeem(context, { earnShares: minted, receiver: context.user.address })
    },
  )
}

async function scopedExits(context: E2eContext) {
  await mintVaultAsset(context, AMOUNT)
  const { earnShares } = await deposit(context, {
    assets: AMOUNT,
    receiver: context.user.address,
  })
  const vault = context.contracts.earnVault
  await withScopedKey(
    context,
    [
      {
        address: context.contracts.earnShare,
        selector: 'approve(address,uint256)',
        recipients: [vault],
      },
      { address: vault, selector: 'redeem(uint256,uint256)' },
      { address: vault, selector: 'withdrawExact(uint256,uint256)' },
    ],
    async (wallet) => {
      for (const data of [
        encodeFunctionData({
          abi: earnVaultAbi,
          functionName: 'redeem',
          args: [earnShares, context.operator.address, 1n],
        }),
        encodeFunctionData({
          abi: earnVaultAbi,
          functionName: 'withdrawExact',
          args: [AMOUNT / 4n, context.operator.address, earnShares],
        }),
      ]) {
        await assertScopedRejection(context, wallet, [
          approvalCall(context.contracts.earnShare, vault, earnShares),
          { to: vault, data },
        ])
      }
      const before = await tokenBalance(context, context.assets.base, context.user.address)
      const receiverBefore = await tokenBalance(
        context,
        context.assets.base,
        context.operator.address,
      )
      const exactReceipt = await waitForSuccessfulWrite(
        context,
        await wallet.sendTransaction({
          feePayer: wallet.feePayer,
          calls: [
            approvalCall(context.contracts.earnShare, vault, earnShares),
            {
              to: vault,
              data: encodeFunctionData({
                abi: earnVaultAbi,
                functionName: 'withdrawExact',
                args: [AMOUNT / 4n, earnShares],
              }),
            },
          ],
        }),
      )
      const exact = context.actors.user.wallet.earn.withdrawExact.extractEvent(exactReceipt.logs, {
        vault,
      })
      assert(
        isAddressEqual(exact.args.receiver, context.user.address),
        'exact withdrawal used the wrong receiver',
      )
      assert(
        (await tokenBalance(context, context.assets.base, context.user.address)) ===
          before + AMOUNT / 4n,
        'exact withdrawal output mismatch',
      )
      const remaining = earnShares - exact.args.earnSharesBurned
      const minAssets = minimumOutput(
        await context.l1Public.earn.getRedeemQuote({ vault, shareAmount: remaining }),
      )
      const redeemReceipt = await waitForSuccessfulWrite(
        context,
        await wallet.writeContract({
          feePayer: wallet.feePayer,
          address: vault,
          abi: earnVaultAbi,
          functionName: 'redeem',
          args: [remaining, minAssets],
        }),
      )
      const redeemed = context.actors.user.wallet.earn.redeem.extractEvent(redeemReceipt.logs, {
        vault,
      })
      assert(
        isAddressEqual(redeemed.args.receiver, context.user.address),
        'redeem used the wrong receiver',
      )
      assert(
        (await tokenBalance(context, context.assets.base, context.user.address)) ===
          before + AMOUNT / 4n + redeemed.args.assets,
        'redeem output mismatch',
      )
      assert(
        (await tokenBalance(context, context.assets.base, context.operator.address)) ===
          receiverBefore,
        'self exit paid another receiver',
      )
    },
  )
}

async function scopedInKindEntry(context: E2eContext) {
  await mintVaultAsset(context, AMOUNT)
  const { venueShares } = await depositIntoVenue(context, {
    assets: AMOUNT,
    receiver: context.user.address,
  })
  await waitForSuccessfulWrite(
    context,
    await context.actors.user.wallet.sendTransaction(
      approvalCall(context.contracts.venue, context.contracts.engine, venueShares),
    ),
  )
  await withScopedKey(
    context,
    [{ address: context.contracts.earnVault, selector: 'depositVenueShares(uint256,uint256)' }],
    async (wallet) => {
      await assertScopedRejection(context, wallet, [
        {
          to: context.contracts.earnVault,
          data: encodeFunctionData({
            abi: earnVaultAbi,
            functionName: 'depositVenueShares',
            args: [venueShares, context.operator.address, 1n],
          }),
        },
      ])
      const before = await tokenBalance(context, context.contracts.earnShare, context.user.address)
      const venueBefore = await tokenBalance(context, context.contracts.venue, context.user.address)
      await waitForSuccessfulWrite(
        context,
        await wallet.writeContract({
          feePayer: wallet.feePayer,
          address: context.contracts.earnVault,
          abi: earnVaultAbi,
          functionName: 'depositVenueShares',
          args: [venueShares, 1n],
        }),
      )
      const minted =
        (await tokenBalance(context, context.contracts.earnShare, context.user.address)) - before
      assert(minted > 0n, 'in-kind entry did not mint to the user')
      assert(
        (await tokenBalance(context, context.contracts.venue, context.user.address)) ===
          venueBefore - venueShares,
        'in-kind entry did not consume user venue shares',
      )
      await redeem(context, { earnShares: minted, receiver: context.user.address })
    },
  )
}

type ScopedWallet = ReturnType<typeof scopedWallet>
type ScopedCall = { to: Address; data: Hex }

function scopedWallet(
  context: E2eContext,
  account: Account.AccessKeyAccount,
  feePayer?: ReturnType<typeof privateKeyToAccount>,
) {
  return createClient({
    account,
    chain: context.actors.user.wallet.chain,
    transport: custom(context.actors.user.wallet),
    pollingInterval: context.pollingInterval,
  }).extend(() => ({ feePayer }))
}

async function withScopedKey(
  context: E2eContext,
  scopes: readonly { address: Address; selector: string; recipients?: readonly Address[] }[],
  run: (wallet: ScopedWallet) => Promise<void>,
) {
  assert(
    !isAddressEqual(context.user.address, context.operator.address),
    'Scoped-key E2E requires END_USER_PRIVATE_KEY distinct from DEPLOYER_PRIVATE_KEY',
  )
  // Keep transaction fees outside the balances whose rollback these cases assert.
  const feePayer = isAddressEqual(context.assets.base, context.deployment.network.pathUsd)
    ? privateKeyToAccount(generatePrivateKey())
    : undefined
  if (feePayer) await ensureFeeBalance(context, feePayer.address)
  const account = Account.fromSecp256k1(generatePrivateKey(), { access: context.user })
  const block = await context.l1Public.getBlock()
  const allowedCalls: {
    target: Address
    selectorRules: { selector: Hex; recipients: Address[] }[]
  }[] = []
  for (const scope of scopes) {
    let target = allowedCalls.find((call) => call.target === scope.address)
    if (!target) {
      target = { target: scope.address, selectorRules: [] }
      allowedCalls.push(target)
    }
    target.selectorRules.push({
      selector: toFunctionSelector(scope.selector),
      recipients: [...(scope.recipients ?? [])],
    })
  }
  // Use the native keychain ABI for authorization; the pinned local node rejects
  // the SDK's scoped keyAuthorization transaction envelope. Signing still uses viem.
  await write(context.actors.user.wallet, {
    address: Addresses.accountKeychain,
    abi: Abis.accountKeychain,
    functionName: 'authorizeKey',
    args: [
      account.accessKeyAddress,
      0,
      {
        expiry: block.timestamp + 3_600n,
        enforceLimits: false,
        limits: [],
        allowAnyCalls: false,
        allowedCalls,
      },
    ],
  })
  try {
    await run(scopedWallet(context, account, feePayer))
  } finally {
    await waitForSuccessfulWrite(
      context,
      await context.actors.user.wallet.accessKey.revoke({ accessKey: account }),
    )
  }
}

function approvalCall(token: Address, spender: Address, amount: bigint): ScopedCall {
  return {
    to: token,
    data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [spender, amount] }),
  }
}

/** A failed root simulation or RPC submission is not evidence of access-key enforcement. */
async function assertScopedRejection(
  context: E2eContext,
  wallet: ScopedWallet,
  calls: ScopedCall[],
) {
  const simulation = await simulateCalls(context.l1Public, {
    account: context.user.address,
    calls,
    validation: false,
  })
  assert(
    simulation.results.every((result) => result.status === 'success'),
    'negative scope test is not executable by the root account',
  )
  await expectUnchanged(
    context,
    'scope rejection',
    async () => {
      // Bypass estimation so the native keychain check is exercised by an actual signed transaction.
      const hash = await wallet.sendTransaction({
        calls,
        gas: 5_000_000n,
        feePayer: wallet.feePayer,
      })
      const receipt = await context.l1Public.waitForTransactionReceipt({
        hash,
        timeout: TIMEOUT_MS,
      })
      assert(receipt.status === 'reverted', 'access key executed a call outside its scope')
    },
    {
      owners: [context.user.address, context.operator.address],
      spenders: [context.operator.address],
    },
  )
}
