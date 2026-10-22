import { useConnection } from 'wagmi'

import { usePrivyAccount } from './Privy.js'

export type WalletMode = 'normal' | 'privy'

/** Returns the signing address of the selected wallet mode, if it is connected. */
export function useWalletAddress(mode: WalletMode) {
  const privy = usePrivyAccount()
  const connection = useConnection()
  return mode === 'privy' ? privy.address : connection.address
}
