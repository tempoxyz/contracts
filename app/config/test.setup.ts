import { vi } from 'vitest'

// Privy's browser package pulls in wallet integrations that cannot execute in the
// Worker-backed test runner. App tests exercise the local integration boundary.
vi.mock('@privy-io/react-auth', () => ({}))

vi.mock('@privy-io/react-auth/tempo', () => ({
  toViemAccount: vi.fn(),
}))
