import { QueryClientProvider, useQuery } from '@tanstack/react-query'
import { PrivyProvider } from '@privy-io/react-auth'
import { useEffect, useMemo, useState } from 'react'
import { Info, Select, Tag } from 'regen-ui'
import { WagmiProvider } from 'wagmi'

import * as Environment from './deployments/Environment.js'
import { loadConfig, type AppConfig, type AppEnvironment } from './deployments/Config.js'
import { verifyDeployment, type VerificationResult } from './earn/Verification.js'
import * as Tempo from './Tempo.js'
import { TransactionToastProvider } from './transactions/Toasts.js'
import { WalletAccount, WalletModeSwitch } from './wallet/Account.js'
import { createPrivyConfig, createQueryClient, createWalletConfig } from './wallet/Config.js'
import type { WalletMode } from './wallet/Mode.js'
import { EarnWorkspace } from './workspace/EarnWorkspace.js'

/** Loads the Worker's environment catalog and mounts the configured Earn application. */
export function App() {
  const [config, setConfig] = useState<AppConfig>()
  const [configError, setConfigError] = useState<string>()

  useEffect(() => {
    let active = true
    loadConfig().then(
      (next) => {
        if (active) setConfig(next)
      },
      (error: unknown) => {
        if (active)
          setConfigError(error instanceof Error ? error.message : 'Configuration unavailable.')
      },
    )
    return () => {
      active = false
    }
  }, [])

  if (config) return <AppRuntime config={config} />

  return (
    <AppFrame>
      {configError ? (
        <Info message={configError} type="error" />
      ) : (
        <Info message="Loading deployment catalog…" type="info" />
      )}
    </AppFrame>
  )
}

function AppRuntime(props: { config: AppConfig }) {
  const { config } = props
  const [environmentId, setEnvironmentId] = useState(() => selectedEnvironmentId(config))
  const environment =
    config.environments.find((candidate) => candidate.id === environmentId) ??
    config.environments.find((candidate) => candidate.id === config.defaultEnvironmentId)
  if (!environment) {
    return (
      <AppFrame>
        <Info message="No hosted Earn environment is configured." type="error" />
      </AppFrame>
    )
  }
  function selectEnvironment(id: string) {
    setEnvironmentId(id)
    if (typeof window !== 'undefined') {
      const url = new URL(window.location.href)
      url.searchParams.set('environment', id)
      window.history.replaceState(null, '', url)
    }
  }
  return (
    <EnvironmentRuntime
      appEnvironment={config.environment}
      environment={environment}
      environments={config.environments}
      key={environment.id}
      onEnvironmentChange={selectEnvironment}
      privyAppId={config.privyAppId}
    />
  )
}

function EnvironmentRuntime(props: {
  appEnvironment: string
  environment: AppEnvironment
  environments: AppEnvironment[]
  onEnvironmentChange: (id: string) => void
  privyAppId: string
}) {
  const { environment } = props
  const network = environment.network
  const label = Environment.displayName(environment.id)
  const walletConfig = useMemo(
    () =>
      createWalletConfig({
        chainId: network.chainId,
        explorerUrl: network.explorerUrl,
        feeToken: network.pathUsd,
        name: label,
        rpcUrl: network.rpcUrl,
        sponsorUrl: environment.sponsorUrl,
      }),
    [
      label,
      environment.sponsorUrl,
      network.chainId,
      network.pathUsd,
      network.explorerUrl,
      network.rpcUrl,
    ],
  )
  const privyConfig = useMemo(
    () => createPrivyConfig(walletConfig.chains[0]),
    [walletConfig.chains],
  )
  const [queryClient] = useState(createQueryClient)
  const [walletMode, setWalletMode] = useState<WalletMode>('normal')
  return (
    <PrivyProvider appId={props.privyAppId} config={privyConfig}>
      <WagmiProvider config={walletConfig} reconnectOnMount>
        <QueryClientProvider client={queryClient}>
          <TransactionToastProvider>
            <EarnScreen {...props} onWalletModeChange={setWalletMode} walletMode={walletMode} />
          </TransactionToastProvider>
        </QueryClientProvider>
      </WagmiProvider>
    </PrivyProvider>
  )
}

function EarnScreen(props: {
  appEnvironment: string
  environment: AppEnvironment
  environments: AppEnvironment[]
  onWalletModeChange: (mode: WalletMode) => void
  onEnvironmentChange: (id: string) => void
  walletMode: WalletMode
}) {
  const { environment, walletMode } = props
  const { network } = environment
  const networkLabel =
    props.appEnvironment === 'local' ? 'Local Tempo' : Environment.displayName(network.name)
  const [selectedId, setSelectedId] = useState(environment.defaultStackId)
  const deployment = environment.stacks.find((candidate) => candidate.id === selectedId)

  const verificationClient = useMemo(() => Tempo.createClient(network), [network])
  const verificationQuery = useQuery({
    enabled: deployment !== undefined,
    queryFn: () => {
      if (!deployment) throw new Error('No deployment selected.')
      return verifyDeployment(verificationClient, network.chainId, deployment)
    },
    queryKey: ['deployment-verification', environment.id, network.chainId, deployment?.id],
    staleTime: 5 * 60_000,
  })
  const verification: VerificationResult | 'verifying' = verificationQuery.data ?? 'verifying'

  return (
    <AppFrame
      navigation={
        <nav
          aria-label="Earn controls"
          className="flex flex-wrap items-center gap-2 sm:justify-end"
        >
          {props.environments.length > 1 ? (
            <div className="w-[160px] shrink-0">
              <Select
                aria-label="Tempo environment"
                items={environmentItems(props.environments)}
                onChange={props.onEnvironmentChange}
                value={environment.id}
              />
            </div>
          ) : (
            <Tag dot intent="accent">
              {Environment.displayName(environment.id)}
            </Tag>
          )}
          <WalletModeSwitch
            chainId={network.chainId}
            mode={walletMode}
            onChange={props.onWalletModeChange}
          />
          <WalletAccount explorerUrl={network.explorerUrl} mode={walletMode} />
        </nav>
      }
    >
      {deployment ? (
        <EarnWorkspace
          deployment={deployment}
          environmentId={environment.id}
          environments={props.environments}
          network={network}
          networkLabel={networkLabel}
          onDeploymentChange={setSelectedId}
          sponsorUrl={environment.sponsorUrl}
          tempoApiZoneReads={environment.tempoApiZoneReads}
          verification={verification}
          walletMode={walletMode}
        />
      ) : (
        <Info message="No current live Earn deployment is registered." type="warning" />
      )}
    </AppFrame>
  )
}

function AppFrame(props: { children: React.ReactNode; navigation?: React.ReactNode | undefined }) {
  return (
    <main className="flex min-h-dvh min-w-[360px] justify-center bg-background text-foreground">
      <section
        aria-labelledby="earn-title"
        className="flex min-h-dvh w-full flex-col gap-3 px-4 pt-4 pb-4 sm:px-6"
      >
        <header className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <h1 className="text-heading-24" id="earn-title">
            Tempo Earn Playground
          </h1>
          {props.navigation}
        </header>
        {props.children}
      </section>
    </main>
  )
}

function environmentItems(environments: AppEnvironment[]) {
  return environments.map((environment) => {
    const label = Environment.displayName(environment.id)
    return { label, textValue: label, value: environment.id }
  })
}

function selectedEnvironmentId(config: AppConfig) {
  if (typeof window === 'undefined') return config.defaultEnvironmentId
  const requested = new URL(window.location.href).searchParams.get('environment')
  return config.environments.some((environment) => environment.id === requested)
    ? requested!
    : config.defaultEnvironmentId
}
