# How Bridge moves card money on Tempo today

A snapshot, read from `withbridge/spender-contract-evm` at `9675cb0` and `withbridge/monorail`
as of 2026-10-13. The harness runs these contracts as the "Bridge" setups. What Bridge's
backend needs for card spend on Tempo is in [`bridge-integration.md`](bridge-integration.md).

## Contracts

- **`SpenderFactory`** (UUPS, roles: admin/timelock, governance, manager, debitor, pauser).
  `createSpender` deploys one beacon-proxy clone per spender ID. monorail creates one per developer
  per chain, so allowances are scoped to a program, not global.
- **`SpenderDelegator`** routes each call by a 2-byte prefix to a registered handler by
  delegatecall.
- **Handlers:** `EA` ERC-20, `EP` permit, `P2` Permit2, `TF` Tempo Earn with fallback
  (`SpenderTEWF`). `EV` ERC-4626 is in unmerged, unaudited PR #14.
- **A pull:** the debitor calls `transferToDestination(spenderId, destination, data)`. The
  destination must be on the spender's allowlist, and the handler checks that the destination's
  balance rose by exactly the amount.
- **`SpenderTEWF`:** the user stores a vault preference (`publicCall "UP"`). A pull sizes shares
  from a live `previewWithdraw` with no cap, then calls `withdrawExact`. Disabling a vault does not
  affect users who already chose it.
- Handlers only pull. There is no on-chain refund path and no on-chain spend limit beyond the
  allowance.

## monorail (cards and crypto-pulls)

- Stripe calls `authorize_and_transfer`. Noncustodial just-in-time pulls on Tempo go through
  crypto-pulls and are approved after broadcast, not after confirmation. A revert after approval is
  recorded as a double spend that Bridge absorbs.
- Returns, refunds and reversals create a crypto-return trip that delivers the card's account
  currency (stablecoin) to the wallet. They never re-enter a vault.
- Vault configuration is one vault per developer per chain (`approval_config.vault_address`).
