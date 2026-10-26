# Solidity implementation

For economic changes, read the relevant [system](../../docs/earn/architecture/system.md),
[fee](../../docs/earn/architecture/fees.md), and [flow](../../docs/earn/architecture/flows.md) sections alongside
[security assumptions](../../docs/earn/architecture/security-and-privacy.md). Those documents are the
accounting specification for contracts, tests, and integrations; this file is not a second one.

- Establish authorization, custody changes, supply changes, rounding, and rollback for every
  economic transition. Measured balance deltas are custody evidence; venue return scalars are not.
  Preserve caller output bounds and atomic rollback when the last external call fails.
- EarnVault owns issuance and the conversion anchor; EarnFees mutates only through its paired vault
  and pays only recorded claims. Never add an upgrade entrypoint to the fixed EarnVault proxy, and
  never let a setter broaden a deployment-fixed control or protected fee choice.
- Keep active managed backing, raw surplus, and queued claims separate. Capacity and reward-admission
  checks must never become exit restrictions or reclassify remaining holder backing.
- Every installed engine serves one vault, uses its immutable base asset, and advertises a usable
  exit; in-kind entry alone is insufficient. Keep venue-specific behavior behind engine capabilities.
  Veda requests stay bound to their originating Queue; settled assets are not sweepable dust.
- The router authenticates canonical callbacks, returns through the same source Portal, converts
  only at exact par with measured 1:1 output, and cleans up temporary balances and approvals. A
  same-asset router binds no pool. Do not add caller-selected tokens, vaults, or destinations.
- Reward periphery has no issuer authority; preserve measured solvency, domain-separated cumulative
  entitlements, settlement replay protection, and unpaid entitlement after failed transfers.
- `demo/` is test scaffolding; label experimental integrations honestly.

Domain references: the [engine contract](../../docs/earn/integrations/engines.md) and each capability's
[module page](../../docs/earn/README.md#capability-modules). Read the
[test guide](../test/AGENTS.md) when changing tests.
