import { useQuery } from '@tanstack/react-query'
import { hasFaucet, type PublicNetwork } from '@tempoxyz/earn/deployments'
import { useEffect, useMemo, useState } from 'react'
import { isAddressEqual, type Account, type Address, type Client } from 'viem'
import { useConnection, useSwitchChain } from 'wagmi'

import type { CatalogStack, PrivateTransaction } from '../../deployments/catalog.js'
import { privateRouteAsset, tokenMetadata, zoneFundingTokens } from '../../deployments/tokens.js'
import * as Environment from '../deployments/Environment.js'
import { actions, amountToken, type Action } from '../earn/Actions.js'
import * as Amount from '../earn/Amount.js'
import type { VerificationResult } from '../earn/Verification.js'
import * as Errors from '../Errors.js'
import * as Tempo from '../Tempo.js'
import { useTransactionToasts, type TransactionToast } from '../transactions/Toasts.js'
import { usePrivyAccount } from '../wallet/Privy.js'
import { useWalletAddress, type WalletMode } from '../wallet/Mode.js'
import * as PrivateAction from './PrivateAction.js'
import * as Funding from './Funding.js'
import * as PasskeySession from './PasskeySession.js'
import * as Position from './Position.js'
import * as PrivySession from './PrivySession.js'
import * as Runtime from './Runtime.js'
import type * as Zone from './Zone.js'
import * as PrivateApi from './PrivateApi.js'

type Deployment = CatalogStack

/** Owns the Zone session, balances, transfers, and private Earn write path. */
export function usePrivateEarn(options: usePrivateEarn.Options): usePrivateEarn.ReturnType {
  const {
    action,
    amountValue,
    deployment,
    network,
    networkLabel,
    environmentId,
    onSubmitted,
    onTransferred,
    sponsorUrl,
    tempoApiZoneReads,
    transferAmountValue,
    verification,
    walletMode,
  } = options
  const mode = deployment.modes.private
  const zoneConfig = network.zone
  const connection = useConnection()
  const privy = usePrivyAccount()
  const address = useWalletAddress(walletMode)
  const switchChain = useSwitchChain()
  const transactionToasts = useTransactionToasts()
  const connector =
    connection.status === 'connected' && typeof connection.connector.getProvider === 'function'
      ? connection.connector
      : undefined
  const zoneLabel = Environment.displayName(zoneConfig?.name ?? 'zone')
  const l1Client = useMemo(() => Tempo.createClient(network), [network])
  const fundTestnetAccount =
    !sponsorUrl && hasFaucet(network.chainId)
      ? (account: Address) => Tempo.fundAccount(network, account)
      : undefined
  const [runtime, setRuntime] = useState<PrivateRuntime>()
  // The router is fixed to one private asset: it enters on deposit and returns on redemption.
  const privateAsset = privateRouteAsset(deployment) ?? deployment.contracts.asset
  const privateMetadata = tokenMetadata(deployment, privateAsset)
  // The Zone can be funded with the private asset or, to pay private fees, PATHUSD.
  const fundingTokens = zoneFundingTokens(deployment, network.pathUsd)
  const [fundingChoice, setFundingChoice] = useState<Address>()
  const fundingToken =
    fundingTokens.find((token) => fundingChoice && isAddressEqual(token, fundingChoice)) ??
    fundingTokens[0]!
  const fundingMetadata = tokenMetadata(deployment, fundingToken)
  const [enabling, setEnabling] = useState(false)
  const [restoring, setRestoring] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [transferring, setTransferring] = useState(false)
  const verified = verification !== 'verifying' && verification.status === 'verified'
  const runtimeReady =
    runtime !== undefined && runtime.address === address && runtime.walletMode === walletMode
  const expectedChain = walletMode === 'privy' || connection.chainId === network.chainId
  const definition = actions[action]
  // The private path spends and returns the private asset where the public path uses the vault asset.
  const metadata = { asset: privateMetadata, earnShare: deployment.expectedMetadata.earnShare }
  const inputMetadata = metadata[definition.input]
  const outputMetadata = metadata[definition.output]
  const amountMetadata = metadata[amountToken(definition)]
  const amountResult = Amount.parseInput(amountValue, amountMetadata.decimals)
  const transferAmountResult = Amount.parseInput(transferAmountValue, fundingMetadata.decimals)
  const balanceQuery = useQuery({
    enabled: runtimeReady,
    queryFn: () => {
      if (!runtime || !address || !zoneConfig) throw new Error('Private runtime is unavailable.')
      return Position.read({
        account: address,
        deployment,
        fundingTokens,
        l1Client,
        readPrivateBalances: tempoApiZoneReads
          ? () =>
              PrivateApi.readBalances({
                account: address,
                deploymentId: deployment.id,
                environmentId,
                zone: zoneConfig,
              })
          : undefined,
        zoneClient: runtime.zoneClient,
      })
    },
    queryKey: [
      'private-position',
      walletMode,
      deployment.id,
      address,
      privateAsset,
      runtime?.address,
      tempoApiZoneReads,
    ],
    staleTime: 5_000,
  })
  const fundingBalance = balanceQuery.data?.publicFunding.get(fundingToken)
  const transactionQuery = useQuery({
    enabled: tempoApiZoneReads && runtimeReady,
    queryFn: async () => {
      if (!runtime || !address || !zoneConfig) throw new Error('Private runtime is unavailable.')
      return await PrivateApi.readTransactions({
        account: address,
        deploymentId: deployment.id,
        environmentId,
        zone: zoneConfig,
      })
    },
    queryKey: [
      'private-transactions',
      walletMode,
      environmentId,
      deployment.id,
      address,
      runtime?.address,
    ],
  })
  const balance =
    definition.input === 'asset'
      ? balanceQuery.data?.privateTokens.get(privateAsset)
      : balanceQuery.data?.privateEarnShares
  const balanceError =
    amountResult.amount !== undefined && balance !== undefined && amountResult.amount > balance
  const transferBalanceError =
    transferAmountResult.amount !== undefined &&
    fundingBalance !== undefined &&
    transferAmountResult.amount > fundingBalance
  const earnRouter = deployment.contracts.earnRouter
  const available =
    mode?.availability === 'available' &&
    definition.private !== undefined &&
    definition.available(deployment.capabilities) &&
    zoneConfig !== undefined &&
    earnRouter !== undefined
  const canSubmit =
    runtimeReady &&
    expectedChain &&
    verified &&
    available &&
    amountResult.amount !== undefined &&
    balance !== undefined &&
    !balanceError &&
    !submitting &&
    // Funding and a private action move the same Zone balance, so their credit checks cannot overlap.
    !transferring
  const canTransfer =
    runtimeReady &&
    (walletMode === 'privy' || connector !== undefined) &&
    expectedChain &&
    verified &&
    available &&
    transferAmountResult.amount !== undefined &&
    fundingBalance !== undefined &&
    !transferBalanceError &&
    !transferring &&
    !submitting
  const canEnable =
    address !== undefined &&
    (walletMode === 'privy' || connector !== undefined) &&
    expectedChain &&
    verified &&
    available &&
    !enabling &&
    !restoring
  const inputDisabled = !runtimeReady || !expectedChain || !verified || !available

  useEffect(() => {
    setRuntime(undefined)
  }, [address, connection.chainId, deployment.id, walletMode])

  useEffect(() => {
    if (
      walletMode !== 'normal' ||
      !address ||
      !connector ||
      !mode ||
      !zoneConfig ||
      !earnRouter ||
      !expectedChain ||
      !verified ||
      !available
    ) {
      setRestoring(false)
      return
    }

    let active = true
    setRestoring(true)
    void (async () => {
      try {
        const account = await PasskeySession.restorePrivateAccessKeyAccount({
          chainId: network.chainId,
          connector,
          expected: address,
        })
        if (!account) return

        const zoneClient = PasskeySession.createPrivateZoneClient({
          account,
          environmentId,
          sourceId: network.chainId,
          zone: zoneConfig,
        })
        const restored = await PasskeySession.restorePrivateZoneSession({
          account,
          zone: zoneConfig,
          zoneClient,
        })
        if (!restored) return

        await Runtime.verify({ deployment, earnRouter, l1Client, zone: zoneConfig, zoneClient })
        if (!active) return
        setRuntime({
          account,
          address: account.address,
          fundingAccount: account,
          walletMode,
          zoneClient,
        })
      } catch {
        // Restoration is best-effort. The explicit Enable flow reports actionable failures.
      } finally {
        if (active) setRestoring(false)
      }
    })()

    return () => {
      active = false
    }
  }, [
    address,
    available,
    connector,
    deployment,
    earnRouter,
    environmentId,
    expectedChain,
    l1Client,
    mode,
    network.chainId,
    verified,
    walletMode,
    zoneConfig,
  ])

  async function enable() {
    if (!canEnable || !address || !mode || !zoneConfig || !earnRouter) return
    const setupId = `private-authorization-${Date.now()}`
    let setupStage: 'publication' | 'zone' = 'publication'
    setEnabling(true)
    try {
      if (walletMode === 'privy') {
        setupStage = 'zone'
        transactionToasts.upsert({
          environment: zoneLabel,
          id: `${setupId}-zone`,
          message: `Authorizing ${zoneLabel} with Privy`,
          status: 'pending',
        })
        const account = await privy.getViemAccount()
        const zone = PrivySession.createPrivateZoneClient({
          account,
          environmentId,
          sourceId: network.chainId,
          zone: zoneConfig,
        })
        await Runtime.verify({
          deployment,
          earnRouter,
          l1Client,
          zone: zoneConfig,
          zoneClient: zone.client,
        })
        setRuntime({
          account: zone.account,
          address: account.address,
          fundingAccount: account,
          walletClient: Tempo.createAccountClient(network, account),
          walletMode,
          zoneClient: zone.client,
        })
        transactionToasts.upsert({
          detail: 'Privy wallet connected to the private Zone.',
          environment: zoneLabel,
          id: `${setupId}-zone`,
          message: 'Private session ready',
          status: 'success',
        })
        return
      }
      if (!connection.address || !connector) throw new Error('The normal wallet is not ready.')
      const connectedAddress = connection.address
      const account = await PasskeySession.getPrivateAccessKeyAccount({
        chainId: network.chainId,
        connector,
        deployment,
        expected: connectedAddress,
        fundPublication: fundTestnetAccount
          ? () => fundTestnetAccount(connectedAddress)
          : undefined,
        onProgress: onSetupProgress,
        rpcUrl: network.rpcUrl,
        sponsorUrl,
      })
      setupStage = 'zone'
      const zoneClient = PasskeySession.createPrivateZoneClient({
        account,
        environmentId,
        sourceId: network.chainId,
        zone: zoneConfig,
      })
      await PasskeySession.authorizePrivateZone({
        account,
        connector,
        expected: connectedAddress,
        onProgress: onSetupProgress,
        zone: zoneConfig,
        zoneClient,
      })
      await Runtime.verify({ deployment, earnRouter, l1Client, zone: zoneConfig, zoneClient })
      setRuntime({
        account,
        address: account.address,
        fundingAccount: account,
        walletMode,
        zoneClient,
      })
    } catch (error) {
      transactionToasts.upsert({
        environment: setupStage === 'zone' ? zoneLabel : 'Tempo L1',
        error,
        id: `${setupId}-${setupStage}`,
        message:
          setupStage === 'zone'
            ? `Private setup failed: ${Errors.message(error)}`
            : `Access key failed: ${Errors.message(error)}`,
        status: 'error',
      })
    } finally {
      setEnabling(false)
    }

    function onSetupProgress(progress: PasskeySession.PrivateSetupProgress) {
      transactionToasts.upsert(privateSetupToast(setupId, progress, network.explorerUrl))
    }
  }

  async function submit() {
    if (!canSubmit || !runtime || amountResult.amount === undefined || !zoneConfig || !earnRouter)
      return
    const flowId = `private-${action}-${Date.now()}`
    setSubmitting(true)
    try {
      await Runtime.verify({
        deployment,
        earnRouter,
        l1Client,
        zone: zoneConfig,
        zoneClient: runtime.zoneClient,
      })
      await PrivateAction.execute({
        account: runtime.account,
        action,
        amount: amountResult.amount,
        deployment,
        earnRouter,
        feeToken: network.pathUsd,
        flowId,
        l1Client,
        onTransaction,
        zone: zoneConfig,
        zoneClient: runtime.zoneClient,
      })
      onSubmitted()
    } catch (error) {
      reportFailure(flowId, zoneLabel, error)
    } finally {
      await refetchPrivateReads()
      setSubmitting(false)
    }
  }

  async function transfer() {
    if (
      !canTransfer ||
      !runtime ||
      transferAmountResult.amount === undefined ||
      !zoneConfig ||
      !earnRouter
    ) {
      return
    }
    const flowId = `private-fund-${Date.now()}`
    setTransferring(true)
    try {
      await Runtime.verify({
        deployment,
        earnRouter,
        l1Client,
        zone: zoneConfig,
        zoneClient: runtime.zoneClient,
      })
      const walletClient =
        runtime.walletClient ??
        (connector
          ? await PasskeySession.createPrivateL1Client({
              chainId: network.chainId,
              connector,
              rpcUrl: network.rpcUrl,
              sponsorUrl,
            })
          : undefined)
      if (!walletClient) throw new Error('The normal wallet is not ready.')
      await Funding.execute({
        account: runtime.fundingAccount,
        amount: transferAmountResult.amount,
        deployment,
        flowId,
        fundFees: fundTestnetAccount ? () => fundTestnetAccount(runtime.address) : undefined,
        l1Client,
        onTransaction,
        sponsorUrl: walletMode === 'normal' ? sponsorUrl : undefined,
        token: fundingToken,
        walletClient,
        zone: zoneConfig,
        zoneClient: runtime.zoneClient,
      })
      onTransferred()
    } catch (error) {
      reportFailure(flowId, 'Tempo L1', error)
    } finally {
      await refetchPrivateReads()
      setTransferring(false)
    }
  }

  function onTransaction(transaction: TransactionToast) {
    transactionToasts.upsert({
      ...transaction,
      explorerUrl: transaction.environment === 'Tempo L1' ? network.explorerUrl : undefined,
    })
  }

  /** Reports a failure no step reported; the toast stack ignores an error already shown. */
  function reportFailure(id: string, environment: string, error: unknown) {
    transactionToasts.upsert({
      environment,
      error,
      id,
      message: Errors.message(error),
      status: 'error',
    })
  }

  async function refetchPrivateReads() {
    const requests: Promise<unknown>[] = [balanceQuery.refetch()]
    if (tempoApiZoneReads) requests.push(transactionQuery.refetch())
    await Promise.all(requests)
  }

  return {
    accountConnected: address !== undefined && (walletMode === 'privy' || connector !== undefined),
    amount: amountResult.amount,
    amountError: balanceError
      ? `Insufficient ${inputMetadata.symbol} private balance.`
      : amountResult.error,
    amountMetadata,
    available,
    balance,
    canEnable,
    canSubmit,
    canTransfer,
    enable,
    enabling: enabling || restoring,
    expectedChain,
    inputDisabled,
    inputMetadata,
    modeReason: mode?.reason,
    networkLabel,
    outputMetadata,
    position: balanceQuery.data,
    positionError: balanceQuery.error ? Errors.message(balanceQuery.error) : undefined,
    refetch: async () => {
      if (runtimeReady) await balanceQuery.refetch()
    },
    runtimeReady,
    submit,
    submitting,
    switchChain: () => {
      if (walletMode === 'normal') switchChain.mutate({ chainId: network.chainId })
    },
    switchingChain: walletMode === 'normal' && switchChain.isPending,
    transactionHistoryAvailable: tempoApiZoneReads,
    transactions: transactionQuery.data,
    transactionsError: transactionQuery.error ? Errors.message(transactionQuery.error) : undefined,
    transactionsReading: transactionQuery.isFetching,
    transfer,
    transferAmountError: transferBalanceError
      ? `Insufficient ${fundingMetadata.symbol} public balance.`
      : transferAmountResult.error,
    transferBalance: fundingBalance,
    transferMetadata: fundingMetadata,
    transferToken: fundingToken,
    transferTokens: fundingTokens.map((token) => ({
      address: token,
      symbol: tokenMetadata(deployment, token).symbol,
    })),
    selectTransferToken: setFundingChoice,
    privateAssetMetadata: privateMetadata,
    transferring,
    verified,
  }
}

export declare namespace usePrivateEarn {
  type Options = {
    action: Action
    amountValue: string
    deployment: Deployment
    environmentId: string
    network: PublicNetwork
    networkLabel: string
    onSubmitted: () => void
    onTransferred: () => void
    sponsorUrl?: string | undefined
    tempoApiZoneReads: boolean
    transferAmountValue: string
    verification: VerificationResult | 'verifying'
    walletMode: WalletMode
  }

  type ReturnType = {
    accountConnected: boolean
    amount: bigint | undefined
    amountError: string | undefined
    /** The token the typed amount is denominated in. */
    amountMetadata: Deployment['expectedMetadata']['asset']
    available: boolean
    balance: bigint | undefined
    canEnable: boolean
    canSubmit: boolean
    canTransfer: boolean
    enable: () => Promise<void>
    enabling: boolean
    expectedChain: boolean
    inputDisabled: boolean
    inputMetadata: Deployment['expectedMetadata']['asset']
    modeReason: string | undefined
    networkLabel: string
    outputMetadata: Deployment['expectedMetadata']['asset']
    position: Position.Snapshot | undefined
    positionError: string | undefined
    refetch: () => Promise<void>
    runtimeReady: boolean
    submit: () => Promise<void>
    submitting: boolean
    switchChain: () => void
    switchingChain: boolean
    transactionHistoryAvailable: boolean
    transactions: PrivateTransaction[] | undefined
    transactionsError: string | undefined
    transactionsReading: boolean
    transfer: () => Promise<void>
    transferAmountError: string | undefined
    transferBalance: bigint | undefined
    transferMetadata: Deployment['expectedMetadata']['asset']
    /** The token the Zone funding form moves, chosen from `transferTokens`. */
    transferToken: Address
    transferTokens: readonly { address: Address; symbol: string }[]
    selectTransferToken: (token: Address) => void
    privateAssetMetadata: Deployment['expectedMetadata']['asset']
    transferring: boolean
    verified: boolean
  }
}

type PrivateRuntime = {
  account: Account
  address: Address
  fundingAccount: Account
  walletClient?: Client | undefined
  walletMode: WalletMode
  zoneClient: Zone.Client
}

function privateSetupToast(
  setupId: string,
  progress: PasskeySession.PrivateSetupProgress,
  explorerUrl: string | undefined,
) {
  const copy = PRIVATE_SETUP_TOAST_COPY[progress.phase]
  return {
    detail: progress.status === 'success' ? copy.detail : undefined,
    environment: copy.environment,
    error: progress.status === 'error' ? progress.error : undefined,
    explorerUrl: progress.phase === 'l1-access-key-publication' ? explorerUrl : undefined,
    hash: progress.status === 'pending' ? undefined : progress.receipt?.transactionHash,
    id: `${setupId}-${progress.phase}`,
    message:
      progress.status === 'pending'
        ? copy.pending
        : progress.status === 'success'
          ? copy.success
          : `${copy.error}: ${progress.message}`,
    status: progress.status,
  } as const
}

const PRIVATE_SETUP_TOAST_COPY: Record<
  PasskeySession.PrivateSetupPhase,
  { detail: string; environment: string; error: string; pending: string; success: string }
> = {
  'l1-access-key-authorization': {
    detail: 'Tempo L1 permission saved.',
    environment: 'Tempo L1',
    error: 'Browser key approval failed',
    pending: 'Approve browser key',
    success: 'Browser key approved',
  },
  'l1-access-key-funding': {
    detail: 'Testnet fee tokens credited to the passkey.',
    environment: 'Tempo L1',
    error: 'Testnet funding failed',
    pending: 'Funding passkey for registration',
    success: 'Passkey funded',
  },
  'l1-access-key-publication': {
    detail: 'Browser key registered on Tempo L1.',
    environment: 'Tempo L1',
    error: 'Browser key registration failed',
    pending: 'Registering browser key',
    success: 'Browser key registered',
  },
  'zone-access-key-authorization': {
    detail: 'Browser key authorized for the Zone.',
    environment: 'Zone',
    error: 'Zone browser key approval failed',
    pending: 'Approve Zone browser key',
    success: 'Zone browser key approved',
  },
}
