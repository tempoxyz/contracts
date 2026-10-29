import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import {
  engineDefinitions,
  type PublicEarnStack,
  type PublicNetwork,
} from '@tempoxyz/contracts/deployments'
import { erc20Abi, isAddressEqual, type Address } from 'viem'
import { type Actions, tempoActions } from 'viem/tempo'
import { useConnection, usePublicClient, useSwitchChain, useWalletClient } from 'wagmi'

import { balanceTokens } from '../../deployments/tokens.js'
import { readDepositEligibility } from '../earn/AccessVerification.js'
import { actions, amountToken, type Action, type ActionDefinition } from '../earn/Actions.js'
import * as Amount from '../earn/Amount.js'
import type { VerificationResult } from '../earn/Verification.js'
import { message as errorMessage } from '../Errors.js'
import * as Tempo from '../Tempo.js'
import { useTransactionToasts } from '../transactions/Toasts.js'
import { usePrivyAccount } from '../wallet/Privy.js'
import { useWalletAddress, type WalletMode } from '../wallet/Mode.js'
import * as Write from './Write.js'

type Deployment = PublicEarnStack

/** Owns the public position, preview, and write path of the Earn workspace. */
export function usePublicEarn(options: usePublicEarn.Options): usePublicEarn.ReturnType {
  const {
    action,
    amountValue,
    deployment,
    network,
    networkLabel,
    onSubmitted,
    sponsorUrl,
    verification,
    walletMode,
  } = options
  const privy = usePrivyAccount()
  const connection = useConnection()
  const address = useWalletAddress(walletMode)
  const publicClient = usePublicClient({ chainId: network.chainId })
  const walletClient = useWalletClient({ chainId: network.chainId }).data
  const earnPublicClient = useMemo(() => publicClient?.extend(tempoActions()), [publicClient])
  const earnWalletClient = useMemo(() => walletClient?.extend(tempoActions()), [walletClient])
  const switchChain = useSwitchChain()
  const queryClient = useQueryClient()
  const transactionToasts = useTransactionToasts()
  const [preparing, setPreparing] = useState(false)
  const [submitting, setSubmitting] = useState(false)

  const definition = actions[action]
  const inputMetadata = deployment.expectedMetadata[definition.input]
  const outputMetadata = deployment.expectedMetadata[definition.output]
  const amountMetadata = deployment.expectedMetadata[amountToken(definition)]
  const quoteMetadata = definition.amountToken === 'input' ? outputMetadata : inputMetadata
  const verified = verification !== 'verifying' && verification.status === 'verified'
  const positionQuery = useQuery({
    enabled: address !== undefined && earnPublicClient !== undefined,
    queryFn: () => {
      if (!address || !earnPublicClient) {
        throw new Error('An account is not connected.')
      }
      return earnPublicClient.earn.getPosition({
        account: address,
        vault: deployment.contracts.earnVault,
      })
    },
    queryKey: ['public-position', deployment.id, walletMode, address],
  })
  const alternateTokens = balanceTokens(deployment).filter(
    (token) => !isAddressEqual(token, deployment.contracts.asset),
  )
  const alternateBalancesQuery = useQuery({
    enabled: address !== undefined && publicClient !== undefined && alternateTokens.length > 0,
    queryFn: async () => {
      if (!address || !publicClient) {
        throw new Error('An account is not connected.')
      }
      const balances = await Promise.all(
        alternateTokens.map((token) =>
          publicClient.readContract({
            address: token,
            abi: erc20Abi,
            functionName: 'balanceOf',
            args: [address],
          }),
        ),
      )
      return new Map(alternateTokens.map((token, index) => [token, balances[index] ?? 0n]))
    },
    queryKey: ['public-alternate-balances', deployment.id, walletMode, address],
  })
  const eligibilityQuery = useQuery({
    enabled:
      verified &&
      deployment.access.kind === 'tip403-whitelist' &&
      address !== undefined &&
      publicClient !== undefined,
    queryFn: () => {
      if (!address || !publicClient) {
        throw new Error('A demo account is not connected.')
      }
      return readDepositEligibility(publicClient, deployment, address)
    },
    queryKey: ['deposit-eligibility', deployment.id, walletMode, address],
  })
  const position = positionQuery.data
  const balance = position?.[positionBalance[definition.input]]
  const amountResult = useMemo(
    () => Amount.parseInput(amountValue, amountMetadata.decimals),
    [amountValue, amountMetadata.decimals],
  )
  const amount = amountResult.amount
  const debouncedAmount = useDebouncedValue(amount, 350)
  const previewQuery = useQuery({
    enabled: verified && publicClient !== undefined && debouncedAmount !== undefined,
    queryFn: () => {
      if (!publicClient || debouncedAmount === undefined) {
        throw new Error('Preview input is unavailable.')
      }
      return definition.quote(publicClient, deployment, debouncedAmount)
    },
    queryKey: ['public-preview', deployment.id, action, debouncedAmount?.toString()],
    staleTime: 30_000,
  })
  const preview = amount === debouncedAmount ? previewQuery.data : undefined
  const previewError =
    amount === debouncedAmount && previewQuery.error ? errorMessage(previewQuery.error) : undefined
  const positionError = positionQuery.error ? errorMessage(positionQuery.error) : undefined
  // An exact-output action knows what it spends only once its quote is read.
  const spent = definition.amountToken === 'input' ? amount : preview
  const balanceError = spent !== undefined && balance !== undefined && spent > balance
  const amountError = balanceError
    ? `Insufficient ${inputMetadata.symbol} balance.`
    : amountResult.error
  const eligibility = depositEligibility(definition, deployment, eligibilityQuery.data, {
    error: eligibilityQuery.error !== null,
  })
  const capability = definition.available(deployment.capabilities)
  const expectedChain = walletMode === 'privy' || connection.chainId === network.chainId
  const canSubmit =
    address !== undefined &&
    (walletMode === 'privy' || earnWalletClient !== undefined) &&
    expectedChain &&
    verified &&
    capability &&
    amount !== undefined &&
    !balanceError &&
    balance !== undefined &&
    preview !== undefined &&
    eligibility === 'eligible' &&
    !preparing &&
    !submitting
  const inputDisabled =
    address === undefined ||
    !expectedChain ||
    !verified ||
    !capability ||
    eligibility !== 'eligible'

  async function submit() {
    if (!canSubmit || !address || !publicClient || amount === undefined || preview === undefined) {
      return
    }
    const toastId = `public-${action}-${Date.now()}`
    transactionToasts.upsert({
      environment: networkLabel,
      id: toastId,
      message: definition.toast.pending,
      status: 'pending',
    })
    setPreparing(true)
    let transactionHash: `0x${string}` | undefined
    const onBroadcast = (hash: `0x${string}`) => {
      transactionHash = hash
      transactionToasts.upsert({
        environment: networkLabel,
        explorerUrl: network.explorerUrl,
        hash,
        id: toastId,
        message: definition.toast.confirming,
        status: 'pending',
      })
    }
    try {
      const privyAccount = walletMode === 'privy' ? await privy.getViemAccount() : undefined
      const walletClient = privyAccount
        ? Tempo.createAccountClient(network, privyAccount)
        : earnWalletClient
      if (!walletClient) throw new Error('The normal wallet is not ready.')
      const calls = await Write.prepare({
        account: address,
        action,
        amount,
        deployment,
        publicClient,
        reviewedQuote: preview,
      })
      setPreparing(false)
      setSubmitting(true)
      // Privy signs with the ejected embedded account; the normal wallet signs through its connector.
      transactionHash = await Write.send({
        account: privyAccount ?? address,
        calls,
        onBroadcast,
        publicClient,
        sponsored: walletMode === 'normal' && sponsorUrl !== undefined,
        walletClient,
      })
      const engine = engineDefinitions[deployment.engineKind]
      transactionToasts.upsert({
        environment: networkLabel,
        explorerUrl: network.explorerUrl,
        hash: transactionHash,
        id: toastId,
        message: definition.toast.confirmed,
        steps: definition.steps({
          engineContract: engine.engineContract,
          input: inputMetadata.symbol,
          output: outputMetadata.symbol,
          venueLabel: engine.venueLabel,
        }),
        status: 'success',
      })
      onSubmitted()
      await positionQuery.refetch()
    } catch (error) {
      if (error instanceof Write.UnsafeDeploymentError) {
        await queryClient.invalidateQueries({ queryKey: ['deployment-verification'] })
      }
      if (error instanceof Write.QuoteChangedError) {
        await queryClient.invalidateQueries({ queryKey: ['public-preview'] })
      }
      transactionToasts.upsert({
        environment: networkLabel,
        error,
        explorerUrl: transactionHash ? network.explorerUrl : undefined,
        hash: transactionHash,
        id: toastId,
        message: errorMessage(error),
        status: 'error',
      })
    } finally {
      setPreparing(false)
      setSubmitting(false)
    }
  }

  return {
    accountConnected: address !== undefined,
    amount,
    amountError,
    amountMetadata,
    balance,
    canSubmit,
    eligibility,
    expectedChain,
    inputDisabled,
    inputMetadata,
    networkLabel,
    position,
    positionError,
    preparing,
    preview,
    previewError,
    quoteMetadata,
    refetch: async () => {
      await Promise.all([positionQuery.refetch(), alternateBalancesQuery.refetch()])
    },
    submit,
    submitting,
    switchChain:
      walletMode === 'normal'
        ? () => switchChain.mutate({ chainId: network.chainId })
        : () => undefined,
    switchingChain: walletMode === 'normal' && switchChain.isPending,
    tokenBalances: new Map<Address, bigint>([
      ...(position ? ([[deployment.contracts.asset, position.assetBalance]] as const) : []),
      ...(alternateBalancesQuery.data?.entries() ?? []),
    ]),
    verified,
  }
}

export declare namespace usePublicEarn {
  type Options = {
    action: Action
    amountValue: string
    deployment: Deployment
    network: PublicNetwork
    networkLabel: string
    onSubmitted: () => void
    sponsorUrl?: string | undefined
    verification: VerificationResult | 'verifying'
    walletMode: WalletMode
  }

  type ReturnType = {
    accountConnected: boolean
    amount: bigint | undefined
    amountError: string | undefined
    /** The token the typed amount is denominated in. */
    amountMetadata: Deployment['expectedMetadata']['asset']
    balance: bigint | undefined
    canSubmit: boolean
    eligibility: DepositEligibility
    expectedChain: boolean
    inputDisabled: boolean
    inputMetadata: Deployment['expectedMetadata']['asset']
    networkLabel: string
    position: Actions.earn.getPosition.ReturnValue | undefined
    positionError: string | undefined
    preparing: boolean
    preview: bigint | undefined
    previewError: string | undefined
    /** The token `preview` is denominated in: the side of the action the user does not type. */
    quoteMetadata: Deployment['expectedMetadata']['asset']
    refetch: () => Promise<void>
    submit: () => Promise<void>
    submitting: boolean
    switchChain: () => void
    switchingChain: boolean
    tokenBalances: Map<Address, bigint>
    verified: boolean
  }
}

type DepositEligibility = 'checking' | 'eligible' | 'error' | 'ineligible'

/** The position balance of each token an action spends. */
const positionBalance = { asset: 'assetBalance', earnShare: 'shareBalance' } as const

function depositEligibility(
  definition: ActionDefinition,
  deployment: Deployment,
  eligible: boolean | undefined,
  state: { error: boolean },
): DepositEligibility {
  if (!definition.requiresEligibility || deployment.access.kind === 'open') return 'eligible'
  if (state.error) return 'error'
  if (eligible === undefined) return 'checking'
  return eligible ? 'eligible' : 'ineligible'
}

function useDebouncedValue<T>(value: T, delay: number) {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const timeout = window.setTimeout(() => setDebounced(value), delay)
    return () => window.clearTimeout(timeout)
  }, [delay, value])
  return debounced
}
