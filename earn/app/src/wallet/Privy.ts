import {
  usePrivy,
  useWallets,
  type LinkedAccountWithMetadata,
  type User,
} from '@privy-io/react-auth'
import { toViemAccount } from '@privy-io/react-auth/tempo'
import { getAddress, isAddress, isAddressEqual, type Address } from 'viem'

/** Returns the primary user-owned Privy Ethereum wallet linked to a user. */
export function getEmbeddedEthereumWallet(user: User | null | undefined) {
  const wallets = user?.linkedAccounts.filter(isEmbeddedEthereumWallet) ?? []
  return wallets.sort((left, right) => (left.walletIndex ?? 0) - (right.walletIndex ?? 0))[0]
}

/** Exposes the authenticated user-owned Privy wallet as a browser viem account. */
export function usePrivyAccount() {
  const privy = usePrivy()
  const connected = useWallets()
  const linked = getEmbeddedEthereumWallet(privy.user)
  const wallet = linked
    ? connected.wallets.find(
        (candidate) =>
          candidate.connectorType === 'embedded' &&
          candidate.walletClientType === 'privy' &&
          isAddress(candidate.address) &&
          isAddressEqual(candidate.address, linked.address),
      )
    : undefined
  return {
    address: wallet && isAddress(wallet.address) ? getAddress(wallet.address) : undefined,
    getViemAccount: async () => {
      if (!wallet) throw new Error('The Privy wallet is not ready.')
      return await toViemAccount({ wallet })
    },
  }
}

function isEmbeddedEthereumWallet(
  account: LinkedAccountWithMetadata,
): account is LinkedAccountWithMetadata & {
  address: Address
  chainType: 'ethereum'
  connectorType: 'embedded'
  type: 'wallet'
  walletClientType: 'privy'
  walletIndex: number | null
} {
  return (
    account.type === 'wallet' &&
    account.chainType === 'ethereum' &&
    account.connectorType === 'embedded' &&
    account.walletClientType === 'privy' &&
    isAddress(account.address)
  )
}
