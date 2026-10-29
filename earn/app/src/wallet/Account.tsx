import { usePrivy } from '@privy-io/react-auth'
import { hostedEnvironment } from '@tempoxyz/contracts/deployments'
import { useState } from 'react'
import { Button, Choices } from 'regen-ui'
import { useConfig, useConnect, useConnection, useDisconnect } from 'wagmi'

import { ExplorerAddress } from '../Explorer.js'
import { getEmbeddedEthereumWallet } from './Privy.js'
import { DEMO_CONNECTOR_ID } from './Config.js'
import type { WalletMode } from './Mode.js'

/** Renders the account controls for the selected wallet mode. */
export function WalletAccount(options: WalletAccount.Props) {
  return (
    <div className="flex min-w-[320px] justify-end">
      {options.mode === 'privy' ? (
        <PrivyWalletAccount explorerUrl={options.explorerUrl} />
      ) : (
        <NormalWalletAccount explorerUrl={options.explorerUrl} />
      )}
    </div>
  )
}

export declare namespace WalletAccount {
  type Props = {
    explorerUrl?: string | undefined
    mode: WalletMode
  }
}

/** Switches transaction signing between Privy and the normal passkey account. */
export function WalletModeSwitch(options: WalletModeSwitch.Props) {
  return (
    <Choices
      className="h-10 bg-secondary [&>*]:h-9"
      // Privy serves only hosted chains.
      items={
        hostedEnvironment(options.chainId)
          ? [
              { label: 'Privy', value: 'privy' as const },
              { label: 'Normal', value: 'normal' as const },
            ]
          : [{ label: 'Normal', value: 'normal' as const }]
      }
      label="Wallet mode"
      onChange={options.onChange}
      value={options.mode}
      variant="compact"
    />
  )
}

export declare namespace WalletModeSwitch {
  type Props = {
    chainId: number
    mode: WalletMode
    onChange: (mode: WalletMode) => void
  }
}

function PrivyWalletAccount(options: { explorerUrl?: string | undefined }) {
  const { authenticated, error, login, logout, ready, user } = usePrivy()
  const wallet = getEmbeddedEthereumWallet(user)

  if (authenticated) {
    return (
      <div className="flex flex-col items-end gap-1">
        <div className="flex items-center gap-1">
          <span className="text-label-12 text-foreground-secondary">Privy</span>
          {wallet ? (
            <ExplorerAddress address={wallet.address} explorerUrl={options.explorerUrl} />
          ) : (
            <span>Creating wallet…</span>
          )}
          <Button.Text onClick={() => void logout()} size="small" type="button">
            Sign out
          </Button.Text>
        </div>
        {error ? (
          <span className="max-w-[260px] text-right text-label-12 text-negative">
            {error.message}
          </span>
        ) : null}
      </div>
    )
  }

  return (
    <div className="flex flex-col items-end gap-1">
      <Button
        disabled={!ready}
        onClick={() => login({ loginMethods: ['email'] })}
        type="button"
        variant="primary"
      >
        Sign in with email
      </Button>
      {error ? (
        <span className="max-w-[260px] text-right text-label-12 text-negative">
          {error.message}
        </span>
      ) : null}
    </div>
  )
}

function NormalWalletAccount(options: { explorerUrl?: string | undefined }) {
  const connection = useConnection()
  const config = useConfig()
  const connect = useConnect()
  const disconnect = useDisconnect()
  const [setup, setSetup] = useState<'idle' | 'continuing' | 'connecting'>('idle')
  const [setupError, setSetupError] = useState<string>()
  const demoConnector = config.connectors.find((connector) => connector.id === DEMO_CONNECTOR_ID)

  async function connectDemo(mode: 'continue' | 'existing') {
    if (!demoConnector) return
    setSetupError(undefined)
    setSetup(mode === 'continue' ? 'continuing' : 'connecting')
    try {
      const result = await connect.mutateAsync({
        connector: demoConnector,
        ...(mode === 'continue'
          ? { capabilities: { method: 'register' as const, name: 'Tempo Earn demo' } }
          : {}),
      })
      if (!result.accounts[0]) throw new Error('The demo passkey returned no account.')
      setSetup('idle')
    } catch (error) {
      setSetup('idle')
      setSetupError(error instanceof Error ? error.message : 'Demo account setup failed.')
    }
  }

  if (connection.address) {
    return (
      <div className="flex flex-col items-end gap-1">
        <div className="flex items-center gap-1">
          <span className="text-label-12 text-foreground-secondary">Normal</span>
          <ExplorerAddress address={connection.address} explorerUrl={options.explorerUrl} />
          <Button.Text
            disabled={disconnect.isPending}
            onClick={() => {
              setSetup('idle')
              setSetupError(undefined)
              disconnect.disconnect()
            }}
            size="small"
            type="button"
          >
            Sign out
          </Button.Text>
        </div>
        {setupError ? (
          <span className="max-w-[260px] text-right text-label-12 text-negative">{setupError}</span>
        ) : null}
        {disconnect.error ? (
          <span className="max-w-[260px] text-right text-label-12 text-negative">
            {disconnect.error.message}
          </span>
        ) : null}
      </div>
    )
  }

  return (
    <div className="flex flex-col items-end gap-1">
      <div className="flex flex-wrap justify-end gap-1">
        <Button
          disabled={!demoConnector || setup !== 'idle'}
          loading={setup === 'continuing'}
          onClick={() => void connectDemo('continue')}
          type="button"
          variant="primary"
        >
          Continue with passkey
        </Button>
        <Button
          disabled={!demoConnector || setup !== 'idle'}
          loading={setup === 'connecting'}
          onClick={() => void connectDemo('existing')}
          type="button"
          variant="secondary"
        >
          Use existing passkey
        </Button>
      </div>
      {setupError ? (
        <span className="max-w-[320px] text-right text-label-12 text-negative">{setupError}</span>
      ) : connect.error ? (
        <span className="max-w-[260px] text-right text-label-12 text-negative">
          {connect.error.message}
        </span>
      ) : null}
    </div>
  )
}
