import { erc20Abi, isAddressEqual, type Address } from 'viem'
import { demoStablecoinFunderAbi } from '@tempoxyz/contracts/abis'
import { hasFaucet } from '@tempoxyz/contracts/deployments'
import type { E2eActor, E2eContext, E2eWallet } from '../context.js'
import { write } from './transactions.js'
import { TIMEOUT_MS } from './utils.js'

/** PATHUSD every acting account keeps for transaction fees. */
export const FEE_BALANCE = 2_000_000n

export async function ensureFeeBalance(context: E2eContext, owner: Address) {
  const balance = await tokenBalance(context, context.deployment.network.pathUsd, owner)
  if (balance >= FEE_BALANCE) return
  if (!hasFaucet(context.deployment.network.chainId)) {
    if (isAddressEqual(owner, context.operator.address)) {
      throw new Error('Without a faucet the operator needs at least 2 PATHUSD for E2E fees')
    }
    await transferOperatorPathUsd(context, owner, FEE_BALANCE - balance)
    return
  }
  await context.l1Public.faucet.fundSync({ account: owner, timeout: TIMEOUT_MS })
}

function transferOperatorPathUsd(context: E2eContext, owner: Address, amount: bigint) {
  return write(context.actors.operator.wallet, {
    address: context.deployment.network.pathUsd,
    abi: erc20Abi,
    functionName: 'transfer',
    args: [owner, amount],
  })
}

/** Funds an actor's L1 `token` balance up to `amount` from the fixture funder or PATHUSD sources. */
export async function fundAsset(
  context: E2eContext,
  token: Address,
  amount: bigint,
  actor: E2eActor = 'user',
) {
  const { account, wallet } = context.actors[actor]
  await ensureFeeBalance(context, account.address)
  if (isAddressEqual(token, context.deployment.network.pathUsd)) {
    await fundPathUsd(context, account.address, amount)
    return
  }
  if ((await tokenBalance(context, token, account.address)) >= amount) return
  const funder = context.funding?.funder
  if (!funder) {
    throw new Error(
      `Production profile E2E requires ${account.address} to be prefunded with at least ${amount} units of ${token}`,
    )
  }
  await write(wallet, {
    address: funder,
    abi: demoStablecoinFunderAbi,
    functionName: 'fund',
    args: [token, account.address, amount],
  })
}

/**
 * PATHUSD, a PATHUSD vault's input, has no fixture issuer: the faucet funds it above fees, and
 * without one the operator transfers the shortfall from its own balance.
 */
async function fundPathUsd(context: E2eContext, owner: Address, amount: bigint) {
  const pathUsd = context.deployment.network.pathUsd
  const required = amount + FEE_BALANCE
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const balance = await tokenBalance(context, pathUsd, owner)
    if (balance >= required) return
    if (!hasFaucet(context.deployment.network.chainId)) {
      if (isAddressEqual(owner, context.operator.address)) break
      await transferOperatorPathUsd(context, owner, required - balance)
      continue
    }
    await context.l1Public.faucet.fundSync({ account: owner, timeout: TIMEOUT_MS })
  }
  if ((await tokenBalance(context, pathUsd, owner)) < required) {
    throw new Error(`${owner} needs ${required} PATHUSD units for this E2E input and its fees`)
  }
}

export async function mintVaultAsset(context: E2eContext, minimum: bigint, actor?: E2eActor) {
  await fundAsset(context, context.assets.base, minimum, actor)
}

/** Approves `spender` for `amount` of `token` from `wallet` unless the allowance already covers it. */
export async function approve(
  context: E2eContext,
  wallet: E2eWallet,
  token: Address,
  spender: Address,
  amount: bigint,
) {
  const allowance = await context.l1Public.readContract({
    address: token,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [wallet.account.address, spender],
  })
  if (allowance >= amount) return
  await write(wallet, {
    address: token,
    abi: erc20Abi,
    functionName: 'approve',
    args: [spender, amount],
  })
}

export function tokenBalance(context: E2eContext, token: Address, owner: Address) {
  return context.l1Public.readContract({
    address: token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [owner],
  })
}

export function tokenSupply(context: E2eContext, token: Address) {
  return context.l1Public.readContract({
    address: token,
    abi: erc20Abi,
    functionName: 'totalSupply',
  })
}
