import { quoteEarnDeposit, type PublicEarnStack } from '@tempoxyz/earn/deployments'
import type { Address, Call, PublicClient } from 'viem'
import { Actions as TempoActions } from 'viem/tempo'

import * as Amount from './Amount.js'

/** A token an action spends or receives; `asset` is the private asset on the private path. */
type Token = 'asset' | 'earnShare'

/** Everything the app does differently per Earn action, so it looks the action up. */
export type ActionDefinition = ActionCommon & ActionSizing

type ActionCommon = {
  /** Tab and submit-button label. */
  label: string
  /** Noun in liquidity and pool copy. */
  noun: string
  /** Form label beside the vault or private asset symbol. */
  assetLabel: string
  /** Public transaction toast messages while preparing, after broadcast, and on success. */
  toast: { pending: string; confirming: string; confirmed: string }
  /** Public transaction success steps. */
  steps(names: {
    input: string
    output: string
    engineContract: string
    venueLabel: string
  }): string[]
  /** The token the action spends. */
  input: Token
  /** The token the action returns. */
  output: Token
  /** The amount field accepts only unsigned decimal keystrokes. */
  numericInput: boolean
  /** The access policy must admit the account before it acts. */
  requiresEligibility: boolean
  /** Flow-canvas edge direction: toward the venue, or back toward the user. */
  direction: 'forward' | 'reverse'
  /** Whether a stack advertises the action as the browser implements it. */
  available(capabilities: PublicEarnStack['capabilities']): boolean
  /**
   * The untyped side of the action through its authoritative quote path: the expected output of an
   * exact-input action, or the expected input of an exact-output action.
   */
  quote(client: PublicClient, deployment: PublicEarnStack, amount: bigint): Promise<bigint>
  /** An exact approval followed by the EarnVault action, bounded by `limits(...).bound`. */
  calls(options: {
    account: Address
    amount: bigint
    deployment: PublicEarnStack
    bound: bigint
  }): readonly Call[]
}

/**
 * Which of the action's tokens the typed amount is denominated in, and so which side the quote
 * bounds. An exact-input action bounds its minimum output; an exact-output action bounds its maximum
 * input. The private EarnRouter flows are exact-input.
 */
type ActionSizing =
  | {
      amountToken: 'input'
      bound: 'minimumOutput'
      /** The EarnRouter flow, when the action has a private path. */
      private?: PrivateFlow | undefined
    }
  | { amountToken: 'output'; bound: 'maximumInput'; private?: undefined }

/** One private action through the Zone's EarnRouter. */
export type PrivateFlow = {
  /** Pool inventory the 1:1 conversion consumes, and the token that inventory is held in. */
  inventory: 'depositLiquidity' | 'redeemLiquidity'
  inventoryToken: 'vaultAsset' | 'privateAsset'
  /** EarnRouter settlement event. */
  event: 'EarnDeposit' | 'EarnRedeem'
  /**
   * The bounded router callback, prepared by viem against the router's live bindings. The router's
   * pool converts exactly 1:1 at par, so `conversionAmount` is the private deposit input or the
   * expected redemption output.
   */
  prepare(
    client: PublicClient,
    options: {
      amount: bigint
      quote: (amount: bigint) => Promise<bigint>
      target: PrivateTarget
    },
  ): Promise<{ conversionAmount: bigint; prepared: PreparedPrivateAction }>
  /** Router activity steps. */
  steps(names: {
    token: string
    asset: string
    earnShare: string
    engineContract: string
    venueLabel: string
  }): string[]
  /** Router activity detail from formatted input, vault-asset, and output amounts. */
  detail(amounts: { input: string; vault: string; engine: string; output: string }): string
}

/** The router, Zone, private asset, and recipients of one private action. */
export type PrivateTarget = {
  assetToken: Address
  gateway: Address
  portalAddress: Address
  recipient: Address
  tempoRefundRecipient: Address
  vault: Address
  zoneId: number
}

/** A prepared private Zone withdrawal and its callback correlation. */
export type PreparedPrivateAction = TempoActions.earn.privateDeposit.prepare.ReturnValue

const definitions = {
  deposit: {
    label: 'Deposit',
    noun: 'deposit',
    assetLabel: 'Deposit asset',
    toast: {
      pending: 'Depositing',
      confirming: 'Confirming deposit',
      confirmed: 'Deposit confirmed',
    },
    steps: ({ input, output, engineContract, venueLabel }) => [
      `Approved ${input} for EarnVault`,
      `Deposited ${input} through EarnVault`,
      `EarnVault deposited through ${engineContract} into the ${venueLabel}`,
      `Minted ${output} to the connected account`,
    ],
    input: 'asset',
    output: 'earnShare',
    amountToken: 'input',
    bound: 'minimumOutput',
    numericInput: true,
    requiresEligibility: true,
    direction: 'forward',
    available: (capabilities) => capabilities.deposit,
    quote: (client, deployment, amount) => quoteEarnDeposit(client, deployment, amount),
    calls: ({ account, amount, deployment, bound }) =>
      TempoActions.earn.deposit.calls({
        assetAmount: amount,
        assetToken: deployment.contracts.asset,
        recipient: account,
        shareAmountMin: bound,
        vault: deployment.contracts.earnVault,
      }),
    private: {
      inventory: 'depositLiquidity',
      inventoryToken: 'vaultAsset',
      event: 'EarnDeposit',
      async prepare(client, { amount, quote, target }) {
        // The router's par swap delivers exactly its input or reverts, so only the share quote
        // takes the tolerance.
        const vaultAssetAmountMin = amount
        const shareAmountMin = Amount.minimumOutput(await quote(amount))
        return {
          conversionAmount: amount,
          prepared: await TempoActions.earn.privateDeposit.prepare(client, {
            ...target,
            assetAmount: amount,
            shareAmountMin,
            vaultAssetAmountMin,
          }),
        }
      },
      steps: ({ token, asset, earnShare, engineContract, venueLabel }) => [
        `EarnRouter received ${token}`,
        `Swapped ${token} to ${asset}`,
        `EarnVault deposited ${asset}`,
        `${engineContract} deposited into the ${venueLabel}`,
        `EarnVault minted ${earnShare}`,
      ],
      detail: ({ input, vault, engine, output }) =>
        `${input} → ${vault} in EarnVault/${engine} → ${output}.`,
    },
  },
  redeem: {
    label: 'Redeem',
    noun: 'redemption',
    assetLabel: 'Receive asset',
    toast: {
      pending: 'Redeeming',
      confirming: 'Confirming redemption',
      confirmed: 'Redemption confirmed',
    },
    steps: ({ input, output, engineContract, venueLabel }) => [
      `Burned ${input} through EarnVault`,
      `EarnVault redeemed through ${engineContract} from the ${venueLabel}`,
      `Returned ${output} to the connected account`,
    ],
    input: 'earnShare',
    output: 'asset',
    amountToken: 'input',
    bound: 'minimumOutput',
    numericInput: false,
    requiresEligibility: false,
    direction: 'reverse',
    // The browser submits only redemptions with a minimum-assets bound.
    available: (capabilities) => capabilities.redeem && capabilities.boundedRedeem,
    quote: (client, deployment, amount) =>
      TempoActions.earn.getRedeemQuote(client, {
        shareAmount: amount,
        vault: deployment.contracts.earnVault,
      }),
    calls: ({ account, amount, deployment, bound }) =>
      TempoActions.earn.redeem.calls({
        assetAmountMin: bound,
        recipient: account,
        shareAmount: amount,
        shareToken: deployment.contracts.earnShare,
        vault: deployment.contracts.earnVault,
      }),
    private: {
      inventory: 'redeemLiquidity',
      inventoryToken: 'privateAsset',
      event: 'EarnRedeem',
      async prepare(client, { amount, quote, target }) {
        const expectedAssets = await quote(amount)
        // At par the router's output equals its vault assets, so viem applies one bound to both.
        return {
          conversionAmount: expectedAssets,
          prepared: await TempoActions.earn.privateRedeem.prepare(client, {
            ...target,
            assetAmountMin: Amount.minimumOutput(expectedAssets),
            shareAmount: amount,
          }),
        }
      },
      steps: ({ token, asset, earnShare, engineContract, venueLabel }) => [
        `EarnRouter received ${earnShare}`,
        `EarnVault burned ${earnShare}`,
        `${engineContract} redeemed from the ${venueLabel}`,
        `EarnVault returned ${asset}`,
        `Swapped ${asset} to ${token}`,
      ],
      detail: ({ input, vault, engine, output }) =>
        `${input} → ${vault} from EarnVault/${engine} → ${output}.`,
    },
  },
} satisfies Record<string, ActionDefinition>

/** Earn action supported by the browser application. */
export type Action = keyof typeof definitions

/** Every Earn action, in tab order. A new action is one entry here. */
export const actions: Readonly<Record<Action, ActionDefinition>> = definitions

export const actionIds = Object.keys(definitions) as Action[]

/** The private flow of an action; throws when the action has none. */
export function privateFlow(action: Action): PrivateFlow {
  const flow = actions[action].private
  if (!flow) throw new Error('This action is unavailable privately.')
  return flow
}

/** The token an action's typed amount is denominated in. */
export function amountToken(definition: ActionDefinition): Token {
  return definition[definition.amountToken]
}

/**
 * The expected input and output of one public action from its typed amount and quote, and the
 * bound its calls carry on the quoted side.
 */
export function limits(
  definition: ActionDefinition,
  amount: bigint,
  quote: bigint,
): { input: bigint; output: bigint; bound: bigint } {
  return definition.bound === 'minimumOutput'
    ? { input: amount, output: quote, bound: Amount.minimumOutput(quote) }
    : { input: quote, output: amount, bound: Amount.maximumInput(quote) }
}
