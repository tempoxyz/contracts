import { useState } from 'react'
import { Box, Button, Info, Input, Tabs } from 'regen-ui'
import { hasFaucet, type EngineKind, type PublicNetwork } from '@tempoxyz/contracts/deployments'
import { formatUnits, isAddressEqual } from 'viem'

import type { CatalogStack, PublicEnvironment } from '../../deployments/catalog.js'
import * as Environment from '../deployments/Environment.js'
import * as Support from '../deployments/Support.js'
import { actionIds, actions, type Action } from '../earn/Actions.js'
import * as Amount from '../earn/Amount.js'
import type { VerificationResult } from '../earn/Verification.js'
import { message as errorMessage } from '../Errors.js'
import { usePrivateEarn } from '../private/PrivateActions.js'
import { usePublicEarn } from '../public/PublicActions.js'
import { ConfigurationPanel } from '../stack/ConfigurationPanel.js'
import { ProductArchitecture } from '../stack/ProductArchitecture.js'
import { StackPreview } from '../stack/StackPreview.js'
import * as Tempo from '../Tempo.js'
import { useTransactionToasts } from '../transactions/Toasts.js'
import { useWalletAddress, type WalletMode } from '../wallet/Mode.js'
import { Balances } from './Balances.js'

type Access = Support.Access

const actionTabs = actionIds.map((id) => ({ id, label: actions[id].label }))

/** Combines stack configuration, topology, balances, and live Earn actions in one workspace. */
export function EarnWorkspace(props: EarnWorkspace.Props) {
  const { deployment, environmentId, network, networkLabel, sponsorUrl, verification, walletMode } =
    props
  const [action, setAction] = useState<Action>('deposit')
  const [access, setAccess] = useState<Access>('public')
  const account = useWalletAddress(walletMode)
  const transactionToasts = useTransactionToasts()
  const [amountValue, setAmountValue] = useState('')
  const [funding, setFunding] = useState(false)
  const [moveFundsOpen, setMoveFundsOpen] = useState(false)
  const [transferAmountValue, setTransferAmountValue] = useState('')
  const zoneConfig = network.zone
  const resolve = (engine: EngineKind, nextAccess: Access) =>
    Support.resolve({
      access: nextAccess,
      engine,
      environmentId,
      environments: props.environments,
    })
  const support = resolve(deployment.engineKind, access)
  const blockedReason = 'message' in support ? support.message : undefined
  const privateConfigured =
    zoneConfig !== undefined && Support.supportsAccess(deployment, 'private')
  const publicEarn = usePublicEarn({
    action,
    amountValue,
    deployment,
    network,
    networkLabel,
    onSubmitted: clearAmount,
    sponsorUrl,
    verification,
    walletMode,
  })
  const privateEarn = usePrivateEarn({
    action,
    amountValue,
    deployment,
    environmentId,
    network,
    networkLabel,
    onSubmitted: clearAmount,
    onTransferred: () => setTransferAmountValue(''),
    sponsorUrl,
    tempoApiZoneReads: props.tempoApiZoneReads,
    transferAmountValue,
    verification,
    walletMode,
  })
  const active = access === 'public' ? publicEarn : privateEarn
  const assetSymbol =
    access === 'public'
      ? deployment.expectedMetadata.asset.symbol
      : privateEarn.privateAssetMetadata.symbol

  function select(engine: EngineKind, nextAccess: Access) {
    const resolution = resolve(engine, nextAccess)
    if ('message' in resolution) return
    setAccess(nextAccess)
    if (resolution.deploymentId !== deployment.id) {
      props.onDeploymentChange(resolution.deploymentId)
    }
  }

  function clearAmount() {
    setAmountValue('')
  }

  function setActionAmount(value: string) {
    if (!actions[action].numericInput || Amount.isInput(value)) setAmountValue(value)
  }

  function selectAction(next: Action) {
    setAction(next)
    clearAmount()
  }

  async function fundWallet() {
    if (!account) return
    const id = `faucet-${Date.now()}`
    transactionToasts.upsert({
      environment: networkLabel,
      id,
      message: 'Funding wallet',
      status: 'pending',
    })
    setFunding(true)
    try {
      const receipts = await Tempo.fundAccount(network, account)
      transactionToasts.upsert({
        detail: `${receipts.length} test-token transfers confirmed.`,
        environment: networkLabel,
        explorerUrl: network.explorerUrl,
        hashes: receipts.map((receipt) => receipt.transactionHash),
        id,
        message: 'Wallet funded',
        status: 'success',
      })
      await Promise.all([publicEarn.refetch(), privateEarn.refetch()])
    } catch (error) {
      transactionToasts.upsert({
        environment: networkLabel,
        error,
        id,
        message: errorMessage(error),
        status: 'error',
      })
    } finally {
      setFunding(false)
    }
  }

  function enablePrivateMode() {
    select(deployment.engineKind, 'private')
    clearAmount()
    void privateEarn.enable()
  }

  function toggleMoveFunds() {
    select(deployment.engineKind, 'private')
    clearAmount()
    setMoveFundsOpen((open) => !open)
    setTransferAmountValue('')
  }

  const interaction = (
    <Box className="flex min-w-0 shrink-0 flex-col gap-4 shadow-lg" padding={16}>
      <div className="flex flex-col gap-1">
        <h2 className="text-heading-16">Vault actions</h2>
      </div>

      <Tabs active={action} expand onChange={selectAction} tabs={actionTabs} />

      {blockedReason ? null : (
        <ActionStatus
          privateEarn={privateEarn}
          publicEarn={publicEarn}
          access={access}
          walletMode={walletMode}
        />
      )}

      <div className="flex items-center justify-between gap-3 text-label-13 text-foreground-secondary">
        <span>{actions[action].assetLabel}</span>
        <span className="text-foreground">{assetSymbol}</span>
      </div>

      <div className="flex flex-col gap-4 rounded-body bg-pane px-4 py-4">
        <div className="flex items-center justify-between gap-3 text-label-12">
          <span className="text-foreground-secondary">Amount</span>
          <span className="min-w-0 truncate tabular-nums text-foreground-secondary">
            {activeBalance(access, publicEarn, privateEarn)} {active.inputMetadata.symbol} {access}
          </span>
        </div>
        <Input.Amount
          aria-label={`${access} ${action} amount`}
          disabled={blockedReason !== undefined || active.inputDisabled}
          error={active.amountError}
          onChange={setActionAmount}
          suffix={active.amountMetadata.symbol}
          value={amountValue}
        />
        <div className="flex items-center justify-between gap-3 text-label-13">
          <span className="text-foreground-secondary">
            {quoteLabel[actions[action].amountToken]}
          </span>
          <span className="text-right tabular-nums text-foreground">
            {receiveLabel(access, publicEarn, privateEarn)}
          </span>
        </div>
      </div>

      {access === 'public' && publicEarn.previewError ? (
        <Info message={publicEarn.previewError} type="error" />
      ) : null}

      {access === 'private' &&
      !privateEarn.runtimeReady &&
      (privateEarn.canEnable || privateEarn.enabling) ? (
        <Button
          className="w-full"
          disabled={blockedReason !== undefined || !privateEarn.canEnable}
          loading={privateEarn.enabling}
          onClick={enablePrivateMode}
          type="button"
          variant="primary"
        >
          Enable Zone
        </Button>
      ) : (
        <Button
          className="w-full"
          disabled={blockedReason !== undefined || !active.canSubmit}
          loading={
            access === 'public'
              ? publicEarn.preparing || publicEarn.submitting
              : privateEarn.submitting
          }
          onClick={() => void active.submit()}
          type="button"
          variant="primary"
        >
          {submitLabel(action, access, publicEarn, privateEarn)}
        </Button>
      )}
    </Box>
  )

  return (
    <div className="flex min-w-0 flex-col gap-5">
      <StackPreview
        access={access}
        action={action}
        balances={
          publicEarn.accountConnected || privateEarn.accountConnected ? (
            <section aria-label="Connected wallet balances" className="min-w-0">
              <Balances
                deployment={deployment}
                faucetAvailable={
                  hasFaucet(network.chainId) &&
                  isAddressEqual(deployment.contracts.asset, network.pathUsd)
                }
                funding={funding}
                moveFundsOpen={moveFundsOpen}
                onFund={() => void fundWallet()}
                onToggleMoveFunds={toggleMoveFunds}
                onTransfer={() => void privateEarn.transfer()}
                onTransferAmountChange={setTransferAmountValue}
                privateConfigured={privateConfigured}
                privateController={privateEarn}
                publicController={publicEarn}
                transferAmountValue={transferAmountValue}
                zoneLabel={zoneConfig ? Environment.displayName(zoneConfig.name) : 'Zone'}
              />
            </section>
          ) : undefined
        }
        deployment={deployment}
        inspector={
          <ConfigurationPanel
            access={access}
            blockedReason={blockedReason}
            deployment={deployment}
            onAccessChange={(nextAccess) => select(deployment.engineKind, nextAccess)}
            onEngineChange={(engine) => select(engine, access)}
            onReset={() => {
              setAction('deposit')
              setAccess('public')
            }}
            resolve={resolve}
          />
        }
        interaction={interaction}
        network={network}
      />
      <section
        aria-label="Contract and routing details"
        className="border border-border bg-surface p-4"
      >
        <h2 className="text-label-13 text-foreground">Contract and routing details</h2>
        <div className="mt-3">
          <ProductArchitecture
            deployment={deployment}
            explorerUrl={network.explorerUrl}
            mode={access}
            verification={verification}
            zone={zoneConfig}
          />
        </div>
      </section>
    </div>
  )
}

export declare namespace EarnWorkspace {
  type Props = {
    deployment: CatalogStack
    environmentId: string
    environments: readonly PublicEnvironment[]
    network: PublicNetwork
    /** The L1's user-facing name. */
    networkLabel: string
    onDeploymentChange: (deploymentId: string) => void
    sponsorUrl?: string | undefined
    tempoApiZoneReads: boolean
    verification: VerificationResult | 'verifying'
    walletMode: WalletMode
  }
}

function ActionStatus(props: {
  privateEarn: usePrivateEarn.ReturnType
  publicEarn: usePublicEarn.ReturnType
  access: Access
  walletMode: WalletMode
}) {
  const { privateEarn, publicEarn, access } = props
  const active = access === 'public' ? publicEarn : privateEarn
  if (!active.accountConnected) {
    return (
      <Info
        message={
          props.walletMode === 'privy'
            ? 'Sign in with email to enable Earn actions.'
            : 'Continue with a passkey to enable Earn actions.'
        }
        type="info"
      />
    )
  }
  if (!active.expectedChain) {
    return (
      <div className="flex flex-col gap-3">
        <Info
          message={`Switch the connected account to ${active.networkLabel} to continue.`}
          type="warning"
        />
        <Button
          loading={active.switchingChain}
          onClick={active.switchChain}
          type="button"
          variant="secondary"
        >
          Switch to {active.networkLabel}
        </Button>
      </div>
    )
  }
  if (!active.verified) {
    return (
      <Info message="Earn actions stay disabled until the deployment verifies." type="warning" />
    )
  }
  if (access === 'public') {
    // Eligibility is `eligible` for an action that does not require it.
    if (publicEarn.eligibility === 'error') {
      return <Info message="Deposit eligibility is temporarily unavailable." type="warning" />
    }
    if (publicEarn.eligibility === 'ineligible') {
      return (
        <Info
          message="This wallet is not eligible to deposit. Existing positions can still be redeemed."
          type="warning"
        />
      )
    }
    return null
  }
  if (!privateEarn.available) {
    return (
      <Info message={privateEarn.modeReason ?? 'Private mode is unavailable.'} type="warning" />
    )
  }
  return null
}

/** The quoted row: what an exact-input action returns, or what an exact-output action spends. */
const quoteLabel = { input: 'You receive', output: 'You spend' } as const

function receiveLabel(
  access: Access,
  publicEarn: usePublicEarn.ReturnType,
  privateEarn: usePrivateEarn.ReturnType,
) {
  if (access === 'private') {
    return privateEarn.amount === undefined ? '—' : `${privateEarn.outputMetadata.symbol} privately`
  }
  if (publicEarn.preview === undefined) return publicEarn.amount === undefined ? '—' : 'Reading…'
  return `≈ ${formatUnits(publicEarn.preview, publicEarn.quoteMetadata.decimals)} ${publicEarn.quoteMetadata.symbol}`
}

function submitLabel(
  action: Action,
  access: Access,
  publicEarn: usePublicEarn.ReturnType,
  privateEarn: usePrivateEarn.ReturnType,
) {
  if (access === 'public') {
    if (publicEarn.preparing) return 'Preparing transaction'
    if (publicEarn.submitting) return 'Confirm transaction'
  }
  if (privateEarn.submitting) return 'Waiting for Zone and vault settlement'
  return `${actions[action].label} ${access === 'private' ? 'privately' : 'publicly'}`
}

function activeBalance(
  access: Access,
  publicEarn: usePublicEarn.ReturnType,
  privateEarn: usePrivateEarn.ReturnType,
) {
  if (access === 'public') {
    return Amount.formatBalance(
      publicEarn.balance,
      publicEarn.inputMetadata.decimals,
      publicEarn.accountConnected ? 'Reading…' : '—',
    )
  }
  return Amount.formatBalance(
    privateEarn.balance,
    privateEarn.inputMetadata.decimals,
    privateEarn.runtimeReady ? 'Reading…' : '—',
  )
}
