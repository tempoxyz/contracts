import { QueryClient } from '@tanstack/react-query'
import type { PrivyClientConfig } from '@privy-io/react-auth'
import { Keystore, Storage } from 'accounts'
import type { Address, Chain } from 'viem'
import { createConfig } from 'wagmi'
import { webAuthn } from 'wagmi/tempo'

import * as Tempo from '../Tempo.js'

export const DEMO_CONNECTOR_ID = 'webAuthn'

/** Creates the Tempo clients and normal passkey connector shared by both wallet modes. */
export function createWalletConfig(options: createWalletConfig.Options) {
  const chain = {
    ...Tempo.chain(options),
    blockExplorers: options.explorerUrl
      ? { default: { name: 'Tempo Explorer', url: options.explorerUrl } }
      : undefined,
    // Wallet sends pay fees in the environment's PATHUSD on every chain, Moderato included.
    feeToken: options.feeToken,
  }
  return createConfig({
    batch: Tempo.l1Batch,
    chains: [chain],
    connectors: [
      webAuthn({
        accessKey: { keystores: { p256: Keystore.webCryptoP256() } },
        ...(options.sponsorUrl
          ? {
              feePayer: {
                precedence: 'user-first',
                url: options.sponsorUrl,
              },
            }
          : {}),
        name: 'Demo passkey',
        storage: Storage.idb({ key: 'tempo-earn-demo' }),
        testnet: chain.testnet === true,
      }),
    ],
    multiInjectedProviderDiscovery: false,
    ssr: true,
    transports: { [chain.id]: Tempo.transport(options.rpcUrl, options.sponsorUrl) },
  })
}

/** Restricts Privy onboarding to email OTP and creates one user-owned Ethereum wallet. */
export function createPrivyConfig(chain: Chain): PrivyClientConfig {
  return {
    appearance: {
      landingHeader: 'Sign in to Tempo Earn',
      loginMessage: 'Use the code sent to your email.',
      showWalletLoginFirst: false,
      walletChainType: 'ethereum-only',
    },
    defaultChain: chain,
    embeddedWallets: {
      ethereum: { createOnLogin: 'all-users' },
      showWalletUIs: false,
    },
    externalWallets: {
      disableAllExternalWallets: true,
    },
    loginMethods: ['email'],
    supportedChains: [chain],
  }
}

/** Creates an isolated query cache for one mounted application runtime. */
export function createQueryClient() {
  return new QueryClient({
    defaultOptions: {
      queries: { refetchOnWindowFocus: false, retry: false, staleTime: 10_000 },
    },
  })
}

export declare namespace createWalletConfig {
  type Options = {
    chainId: number
    explorerUrl?: string | undefined
    feeToken: Address
    name: string
    rpcUrl: string
    sponsorUrl?: string | undefined
  }
}
