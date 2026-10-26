# Agent integration guide

This guide is for an agent helping an application integrate Tempo Earn. It covers the decisions
and checks around an integration: which contract to call, which deployment and caller to verify,
which layer denied a call, and what to report. It keeps the application, EarnVault, engine, and
underlying venue distinct. Transaction sequences are owned by
[end-to-end flows](../architecture/flows.md); action construction, approvals, quotes, and revert
decoding by [client integration](client.md).

## Choose the entry point

The normal application path is `application -> EarnVault -> engine -> venue`. The application holds
EarnShare; the engine holds the venue's shares. Direct integration with a raw ERC-4626 venue is a
different path with a different API and share token.

An application already using `deposit(assets, receiver, minEarnShares)`,
`withdrawExact(assets, receiver, maxEarnShares)`, or `earnShare()` expects an EarnVault. A venue
exposing ERC-4626 `deposit(assets, receiver)` is not a drop-in replacement. Do not allowlist a raw
venue and assume the application's Earn calls will work. Preserve the Earn boundary unless the
user explicitly chooses direct venue integration.

For a simple public proof of concept, an immediate-execution ERC-4626 venue and `ERC4626Engine`
avoid Veda's separate Teller, Accountant, periphery registry, and optional Queue. Choose Veda when
the venue requires those facilities; `PropAMMEngine` serves only a DirectPropAMM pool route. No
engine guarantees withdrawal liquidity. See the [engine table](engines.md#yield-engines) and
[security assumptions](../architecture/security-and-privacy.md).

An integrator can deploy its own Earn stack over a compatible existing venue. There need not be a
single shared EarnVault for every application. An existing engine cannot serve two EarnVaults;
deploy a fresh engine rather than trying to rebind one that already belongs to another vault.

## Establish the deployment and caller

Before recommending an address or transaction, collect:

- the parent chain and RPC, distinguishing mainnet, Moderato, and any private Zone;
- the base asset and its decimals, plus the application's job, payout, or accounting asset;
- the application contract or user account that will actually call EarnVault;
- the current EarnVault, engine, and venue, or the intended venue for a new stack; and
- required exits: exact principal withdrawal, full redemption, or an explicitly delayed claim.

For existing deployments, verify the reads and capabilities listed in
[read the deployment](client.md#read-the-deployment), plus the engine's `earnVault()`, `asset()`,
and venue binding against its specific interface. Read EarnShare and venue-share decimals
separately. A selector absent from the deployed implementation may revert without an error body;
inspect a verified ABI before interpreting a failed read as stale valuation or broken accounting.

Tempo-owned stacks are recorded in the generated `deployment.json` beside
`profiles/<profile-id>/profile.json` and in the app catalog, `app/deployments/generated.json`. A
stack deployed elsewhere keeps its record in the deployments repository that holds its profile
([profiles in another repository](../../../profiles/README.md#profiles-in-another-repository)). No
record proves current readiness: verify live bindings and simulate the intended action on the
stated chain, and never copy a testnet address into a mainnet recommendation. See
[hosted environments](../../deployment/hosted-environments.md).

## Separate permission checks

Public EarnVault actions do not require a universal Tempo partner onboarding allowlist. Access can
still be restricted at several independent layers:

| Layer                    | What to verify                                                                                     | Who owns the decision                      |
| ------------------------ | -------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| Base asset and EarnShare | Live TIP-403 policy allows the required transfers, mint, and burn endpoints                        | Token policy administrator                 |
| Underlying venue         | Deposit, withdrawal, and transfer restrictions, including any venue gates                          | Venue administrator                        |
| Application              | Its own allowed assets and EarnVaults include the selected deployment                              | Application owner                          |
| Private Zone             | Account admission, router registration, boundary-token enablement, and router conversion readiness | Relevant Zone administrator and pool owner |

For a new open public profile, omit `tip403PolicyId` and the optional `zone` configuration. An open
EarnShare does not override the base asset's policy or a venue's restrictions. Do not infer access
from the protocol's general reputation as permissionless, and do not disable controls to resolve a
denied call. Use [deployment authority boundaries](../../deployment/deployment.md#authority-boundaries)
for required handoffs.

## Reuse or deploy an ERC-4626-backed stack

If a compatible Earn deployment already exists, verify it rather than changing the application's
API. If none has been verified, say so and offer a new deployment; do not invent a wrapper address.
The [deployment lifecycle](../../deployment/deployment.md) owns profile authoring and the read-only
`pnpm earn plan`, then the user-authorized `pnpm earn deploy` and `pnpm earn verify`. For a public
ERC-4626 profile, use `engine.kind: "erc4626"` with the verified existing venue, whose asset must
match the application's deposit and settlement asset, and reviewed owners and fees rather than demo
identities.

Configure the application with the resulting EarnVault address, not the venue or engine address.
Existing jobs or positions remain bound to their original deployment; do not overwrite those
references when adding a venue or changing the deposit asset. See
[holder migration](../modules/migration.md).

## Check contract-owned approvals and settlement

When an application calls EarnVault, the application contract grants the approvals in the
[approval matrix](client.md#approvals), including the EarnShare approval every exit needs; verify
that path, not only the human wallet's allowance. Keep nonzero output bounds and use
[execution-aware quotes](client.md#positions-and-quotes), never a hardcoded one-to-one ratio.

A deposit receipt alone does not establish payout readiness. Test the application's composed
funding, settlement, refund, and withdrawal paths. Verify measured asset delivery and remaining
shares, not only a successful transaction status or an event claiming payment. A fallback that
credits a worker from the payer's available balance only covers the amount actually available;
catching a venue failure cannot create missing principal. Keep loss handling and liquidity buffers
explicit in application design.

## Diagnose failures by layer

Decode the revert as in [decode reverts](client.md#decode-reverts) and preserve its parameters.
Record the chain, caller, contract, selector, and observed balances or allowances. Simulate the complete approval-plus-action
sequence, and where necessary the application's actual funding or settlement entry point. An
isolated call impersonating EarnVault may identify an engine guard but is not proof that the full
application works.

| Evidence                                                             | Next check                                                                                    |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `TokenCallFailed` on exit                                            | EarnShare allowance from the actual share holder to EarnVault; then token policy and balances |
| `PolicyForbids` or a venue access error                              | The denied transfer or venue gate, not a presumed universal Earn onboarding requirement       |
| `StaleAccountantRate(updatedAt, currentTime, maxAge)` (`0x323a44c7`) | The Veda Accountant report timestamp and engine `maxRateAge()`                                |
| PropAMM `InvalidOracle` on deposit                                   | The oracle observation time against the engine's `maxOracleAge()`                             |
| Unsupported selector or empty-data revert                            | The deployed contract generation and ABI before making an accounting diagnosis                |
| Withdraw or redeem fails despite sufficient shares                   | Capability, output limits, underlying venue liquidity, pause state, and token access          |

For a stale Veda report, follow [Veda stale reports](../modules/veda.md#stale-reports); for a stale
PropAMM price, follow [PropAMM freshness](../modules/propamm.md#freshness). Do not
fabricate a NAV report or price, or relax the age threshold.

## Validate and report the boundary reached

Use the [E2E catalog](../../deployment/e2e-environments.md) to select the smallest relevant public
case; for an ERC-4626 proof of concept, run `pnpm e2e:local -- --variant erc4626 --group public`.
Local fixture success validates the implementation, not a live external venue. Before production
use, verify the actual deployment, simulate with the application's caller and limits, and run only
the funded checks the user authorized. An Earn test stack is a hosted demo, not an assurance of
production yield or liquidity; the [audits page](../audit/README.md) lists audit coverage.

In the handoff, distinguish quotes, simulations, confirmed receipts, and complete application tests.
State which chain and deployment were checked, which access or liquidity assumptions remain, and
whether any user-visible application still uses an older deployment.
