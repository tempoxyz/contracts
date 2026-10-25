import { Box, Button, Choices, Info, Input, Tag } from 'regen-ui'
import { isAddressEqual, type Address } from 'viem'

import type { CatalogStack } from '../../deployments/catalog.js'
import { balanceTokens, tokenMetadata } from '../../deployments/tokens.js'
import * as Amount from '../earn/Amount.js'
import { shortHex } from '../Explorer.js'
import type { usePrivateEarn } from '../private/PrivateActions.js'
import type { usePublicEarn } from '../public/PublicActions.js'

type Deployment = CatalogStack

/** Public L1 and private Zone balances, with the Zone funding form and private activity. */
export function Balances(props: {
  deployment: Deployment
  faucetAvailable: boolean
  funding: boolean
  moveFundsOpen: boolean
  onFund: () => void
  onToggleMoveFunds: () => void
  onTransfer: () => void
  onTransferAmountChange: (value: string) => void
  privateConfigured: boolean
  privateController: usePrivateEarn.ReturnType
  publicController: usePublicEarn.ReturnType
  transferAmountValue: string
  zoneLabel: string
}) {
  const tokens = balanceTokens(props.deployment)
  const rows = [
    ...tokens.map((token) => {
      const metadata = tokenMetadata(props.deployment, token)
      return {
        decimals: metadata.decimals,
        key: token,
        privateValue: props.privateController.position?.privateTokens.get(token),
        publicValue: props.publicController.tokenBalances.get(token),
        symbol: metadata.symbol,
      }
    }),
    {
      decimals: props.deployment.expectedMetadata.earnShare.decimals,
      key: props.deployment.contracts.earnShare,
      privateValue: props.privateController.position?.privateEarnShares,
      publicValue: props.publicController.position?.shareBalance,
      symbol: props.deployment.expectedMetadata.earnShare.symbol,
    },
  ]

  return (
    <Box className="flex min-w-0 flex-col gap-4" padding={16}>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h3 className="text-heading-16">Balances</h3>
        <div className="flex flex-wrap items-center gap-2">
          {props.publicController.accountConnected && props.faucetAvailable ? (
            <Button
              loading={props.funding}
              onClick={props.onFund}
              size="small"
              type="button"
              variant="secondary"
            >
              Fund with faucet
            </Button>
          ) : null}
          {props.privateConfigured &&
          props.privateController.accountConnected &&
          props.privateController.runtimeReady ? (
            <Button
              aria-controls="deposit-to-zone-form"
              aria-expanded={props.moveFundsOpen}
              onClick={props.onToggleMoveFunds}
              size="small"
              type="button"
              variant="secondary"
            >
              {props.moveFundsOpen ? 'Close' : 'Deposit to Zone'}
            </Button>
          ) : null}
        </div>
      </div>

      {props.moveFundsOpen && props.privateController.runtimeReady ? (
        <DepositToZoneForm
          controller={props.privateController}
          onTransfer={props.onTransfer}
          onTransferAmountChange={props.onTransferAmountChange}
          transferAmountValue={props.transferAmountValue}
        />
      ) : null}

      <div className="min-w-0 overflow-x-auto border border-border">
        <table
          aria-label="Public and private token balances"
          className="w-full min-w-[360px] table-fixed border-collapse text-label-13"
        >
          <thead className="bg-pane text-foreground-secondary">
            <tr>
              <th className="w-1/3 px-3 py-2 text-left font-normal" scope="col">
                Token
              </th>
              <th className="px-3 py-2 text-right font-normal" scope="col">
                <span className="block text-foreground">Public</span>
                <span className="text-copy-12">Tempo L1</span>
              </th>
              {props.privateConfigured ? (
                <th className="px-3 py-2 text-right font-normal" scope="col">
                  <span className="block text-foreground">Private</span>
                  <span className="text-copy-12">{props.zoneLabel}</span>
                </th>
              ) : null}
            </tr>
          </thead>
          <tbody className="divide-y divide-border tabular-nums">
            {rows.map((row) => (
              <tr key={row.key}>
                <th className="px-3 py-2 text-left font-normal text-foreground" scope="row">
                  {row.symbol}
                </th>
                <td className="px-3 py-2 text-right text-foreground">
                  {Amount.formatBalance(
                    row.publicValue,
                    row.decimals,
                    props.publicController.accountConnected ? 'Reading…' : '—',
                  )}
                </td>
                {props.privateConfigured ? (
                  <td className="px-3 py-2 text-right text-foreground">
                    {Amount.formatBalance(
                      row.privateValue,
                      row.decimals,
                      props.privateController.runtimeReady ? 'Reading…' : '—',
                    )}
                  </td>
                ) : null}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {props.publicController.positionError ? (
        <Info message={props.publicController.positionError} type="error" />
      ) : null}
      {props.privateConfigured && !props.privateController.available ? (
        <Info
          message={props.privateController.modeReason ?? 'Private balances are unavailable.'}
          type="warning"
        />
      ) : null}

      {props.privateConfigured &&
      props.privateController.available &&
      !props.privateController.runtimeReady &&
      props.privateController.accountConnected ? (
        <Info message="Zone setup is required to read private balances." type="info" />
      ) : null}

      {props.privateConfigured && props.privateController.positionError ? (
        <Info message={props.privateController.positionError} type="error" />
      ) : null}

      {props.privateConfigured ? (
        <PrivateBalanceDetails controller={props.privateController} deployment={props.deployment} />
      ) : null}
    </Box>
  )
}

function PrivateBalanceDetails(props: {
  controller: usePrivateEarn.ReturnType
  deployment: Deployment
}) {
  const { controller, deployment } = props
  return (
    <>
      {controller.runtimeReady && controller.transactionHistoryAvailable ? (
        <div className="flex flex-col gap-3 border-t border-border pt-4">
          <div className="flex items-center justify-between gap-3">
            <h4 className="text-label-12 font-medium text-foreground">Private activity</h4>
            <Button
              loading={controller.transactionsReading}
              onClick={() => void controller.refetch()}
              size="small"
              type="button"
              variant="secondary"
            >
              Refresh
            </Button>
          </div>

          {controller.transactionsError ? (
            <Info message={controller.transactionsError} type="error" />
          ) : controller.transactions === undefined ? (
            <p className="text-label-12 text-foreground-secondary">Reading private activity…</p>
          ) : controller.transactions.length === 0 ? (
            <p className="text-label-12 text-foreground-secondary">No private transactions yet.</p>
          ) : (
            <ul className="divide-y divide-border">
              {controller.transactions.map((transaction) => (
                <li
                  className="flex min-w-0 items-start justify-between gap-3 py-3"
                  key={transaction.hash}
                >
                  <div className="min-w-0">
                    <div className="flex flex-wrap items-center gap-2">
                      <span className="text-label-12 text-foreground">
                        {privateTransactionTitle(transaction)}
                      </span>
                      <Tag intent={privateTransactionIntent(transaction.status)}>
                        {privateTransactionStatus(transaction.status)}
                      </Tag>
                    </div>
                    <p className="mt-1 truncate text-label-12 text-foreground-secondary">
                      {privateTransactionTarget(deployment, transaction.counterparty)}
                      {transaction.timestamp ? (
                        <>
                          {' · '}
                          <time dateTime={transaction.timestamp}>
                            {privateTransactionTime(transaction.timestamp)}
                          </time>
                        </>
                      ) : null}
                    </p>
                  </div>
                  <span
                    className="shrink-0 font-mono text-label-12 text-foreground-secondary"
                    title={transaction.hash}
                  >
                    {shortHex(transaction.hash)}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      ) : null}
    </>
  )
}

function DepositToZoneForm(props: {
  controller: usePrivateEarn.ReturnType
  onTransfer: () => void
  onTransferAmountChange: (value: string) => void
  transferAmountValue: string
}) {
  const { controller } = props
  return (
    <div className="flex flex-col gap-4 border-t border-border pt-4" id="deposit-to-zone-form">
      {controller.transferTokens.length > 1 ? (
        <Choices
          items={controller.transferTokens.map((token) => ({
            label: token.symbol,
            value: token.address,
          }))}
          label="Deposit asset"
          onChange={controller.selectTransferToken}
          value={controller.transferToken}
        />
      ) : (
        <div className="flex items-center justify-between gap-3 text-label-13 text-foreground-secondary">
          <span>Deposit asset</span>
          <span className="text-foreground">{controller.transferMetadata.symbol}</span>
        </div>
      )}
      <div className="flex flex-col gap-4 rounded-body bg-pane px-4 py-4">
        <div className="flex items-center justify-between gap-3 text-label-12">
          <span className="text-foreground-secondary">Amount</span>
          <span className="tabular-nums text-foreground-secondary">
            {Amount.formatBalance(controller.transferBalance, controller.transferMetadata.decimals)}{' '}
            {controller.transferMetadata.symbol} public
          </span>
        </div>
        <Input.Amount
          aria-label="Deposit to Zone amount"
          disabled={!controller.runtimeReady || !controller.expectedChain}
          error={controller.transferAmountError}
          onChange={props.onTransferAmountChange}
          suffix={controller.transferMetadata.symbol}
          value={props.transferAmountValue}
        />
      </div>
      <Button
        disabled={!controller.canTransfer}
        loading={controller.transferring}
        onClick={props.onTransfer}
        type="button"
        variant="secondary"
      >
        Deposit to Zone
      </Button>
    </div>
  )
}

function privateTransactionTitle(transaction: {
  direction: 'incoming' | 'outgoing'
  functionSelector: `0x${string}`
}) {
  if (transaction.functionSelector === '0x095ea7b3') return 'Token approval'
  if (
    transaction.functionSelector === '0xa9059cbb' ||
    transaction.functionSelector === '0x23b872dd'
  ) {
    return 'Token transfer'
  }
  return transaction.direction === 'incoming' ? 'Incoming transaction' : 'Private transaction'
}

function privateTransactionIntent(status: 'pending' | 'reverted' | 'success') {
  if (status === 'success') return 'positive'
  if (status === 'reverted') return 'negative'
  return 'warning'
}

function privateTransactionStatus(status: 'pending' | 'reverted' | 'success') {
  if (status === 'success') return 'Success'
  if (status === 'reverted') return 'Reverted'
  return 'Pending'
}

function privateTransactionTarget(deployment: Deployment, counterparty: Address | null) {
  if (!counterparty) return 'Contract creation'
  if (isAddressEqual(counterparty, deployment.contracts.earnShare)) {
    return deployment.expectedMetadata.earnShare.symbol
  }
  const privateAsset = deployment.modes.private?.privateAsset
  if (privateAsset && isAddressEqual(counterparty, privateAsset)) {
    return tokenMetadata(deployment, privateAsset).symbol
  }
  return shortHex(counterparty)
}

function privateTransactionTime(timestamp: string) {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(timestamp))
}
