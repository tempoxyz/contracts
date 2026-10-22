# Design decisions

This page records why the core stack is shaped as it is. The rules themselves are in the
[architecture pages](architecture/system.md); each capability module records its own decisions on its
[module page](README.md#capability-modules). Rationale does not replace contract-level security
review.

## Customer-agnostic core

**Decision:** keep customer policy, names, and custom flows outside EarnShare, `EarnVault`, and engine interfaces.

**Why:** the same ownership and custody model should support public Earn, private Zone access, and future integrations. Customer-specific contracts would fragment liquidity and make security review non-reusable.

## Native TIP-20 EarnShare

**Decision:** represent the user claim as a native, non-rebasing TIP-20 created by the Tempo factory.

**Why:** it composes with Tempo policies and Zones while keeping balances stable. Yield appears in redemption value, which avoids per-holder reward accounting and private reward claims.

## Persistent EarnVault, replaceable engine

**Decision:** integrations target one `EarnVault`; its operator may atomically replace the yield
engine only when the deployment-fixed migration mode permits it.

**Why:** venue selection will evolve faster than the public share address. A narrow engine seam permits a venue migration without changing EarnShare balances or downstream integrations.

**Consequence:** the transferable EarnVault operator is highly trusted and migration must be atomic,
same-asset, bounded by caller-supplied outputs, and blocked while async exits are open.

## Engine-owned venue shares

**Decision:** the engine, not the EarnVault, is the sole custodian of venue shares.

**Why:** venue-specific assets and operations stay inside the venue integration. The EarnVault measures one engine position through a uniform boundary and does not need approvals or custody branches for every venue.

## Capability-based engine interfaces

**Decision:** keep `IEarnEngine` to universal single-client custody and valuation, and advertise
immediate redemption, exact withdrawal, async redemption, and in-kind entry as separate ERC-165
capabilities.

**Why:** an engine is not a user-facing ERC-4626 vault. ERC-4626-shaped receiver and owner parameters would be ignored and make engines appear to support behavior they might not have. Capability discovery gives the chain a small extensible seam without inventing version numbers or venue-specific branches in `EarnVault`.

**Consequence:** initial installation and migration require the base interface plus at least one
advertised exit capability: immediate redemption, exact withdrawal, or async redemption. Async
request terms cross the EarnVault as opaque bytes and are decoded at the concrete engine edge.
`VedaEngine` uses the typed `VedaRedeemRequest` payload. The request lifecycle follows established
async-vault terminology where useful, but the EarnVault does not claim ERC-7540 compliance.

## Measured accounting

**Decision:** minting, redemptions, and swaps use observed balance/share deltas rather than trusting external return values.

**Why:** integrations may report values inconsistently, levy fees, or behave unexpectedly. Measurement anchors accounting to assets actually received.

## Re-anchor on migration or contribution

**Decision:** preserve EarnShare supply, then record the new engine-share conversion anchor after migration or a shareless contribution.

**Why:** venue share units are arbitrary, and a reward must increase the backing of existing EarnShare without minting claims to the funder. A fee-enabled contribution may still mint claimable fee EarnShare.

## Async EarnShare burn-at-request

**Decision:** accrue active fees, burn EarnShare when a queued redemption is requested, and represent the exit as a separate pending claim.

**Why:** queued backing has left active NAV and must not remain represented in active supply.
Finalization pays the fixed claim without another burn; cancellation re-enters at current value
under the [queued-withdrawal fee rules](architecture/fees.md#queued-withdrawals).

**Consequence:** active fees and contributions continue while claims are queued and benefit only live EarnShare. Engine migration stays blocked until every queued request closes.

## Isolated positive-accrual fees

**Decision:** keep all fee state and fee-token custody in one immutable, ownerless `EarnFees` module
per EarnVault. `EarnVault` remains the only fee mutation entrypoint and the only contract allowed to
mint the fee EarnShare calculated by the module.

**Why:** fee accounting has a large, independent state machine. Isolating it reduces the permanent
issuer's state and code surface while preserving a single trusted accounting context. User principal
must not be the fee base, while organic yield and contributed rewards should receive the same
treatment. Fee EarnShare keeps backing invested and lets recipients claim without blocking user
actions.

**Consequence:** `EarnFees` cannot mint, move engine backing, or configure itself, and engines must
expose credible base-asset NAV. A distributor may start at zero, reserving a dormant prospective
fee option that survives operator handoff without economic effect until an announced update
executes. Authorities and accounting rules are in [Earn fees](architecture/fees.md).

## Crystallize fees before fungible supply changes

**Decision:** settle pending Earn-level fees before deposits, redemptions, exact withdrawals, and
other actions that change fungible EarnShare supply.

**Why:** allowing supply to change while an earlier fee liability remains unsettled either lets a
redeemer escape that liability or makes a later depositor inherit or dilute it. A fixed daily or
monthly crystallization schedule would need virtual fee shares plus transfer-safe holder or cohort
equalization, separate share series, or restricted entry and exit windows. A single fungible
EarnShare with one aggregate high-water mark cannot distinguish those holder cohorts.

**Consequence:** ordinary actions remain nonblocking and checkpoint fees atomically without relying
on a keeper. Active checkpoints may take a no-accrual fast path when value per EarnShare has not
exceeded the high-water mark, but that optimization preserves target recovery and does not defer a
fee that could affect flow pricing. A fixed-interval policy would be an accounting redesign, not a
gas optimization.

## Fixed EarnVault implementation proxies

**Decision:** deploy one locked `EarnVault` implementation, bind a factory immutably to it, and have that factory create an ERC-1967 proxy with no upgrade function for each Earn stack.

**Why:** the complete fee and async implementation cannot be embedded in the factory's creation transaction within Tempo's 30M per-transaction gas cap. A separately deployed fixed implementation keeps each creation deployable while preserving atomic proxy initialization and isolated per-stack storage.

**Consequence:** the implementation cannot be replaced. A code change requires a new factory and new Earn deployment.

## Factory atomicity and separate scoped router

**Decision:** `EarnFactory` atomically creates EarnShare, a non-upgradeable EarnVault proxy, and a
deterministic one-to-one `EarnFees` clone, initializes both modules, attaches the optional existing
simple whitelist, and records the initial engine. `SingleZoneEarnRouter` is deployed separately
after the EarnVault exists.

**Why:** every accounting and issuer invariant should be complete when factory creation returns.
The router needs the final EarnVault address in its immutable constructor, and keeping it outside
the factory leaves public-only deployments free to omit a Zone router. Policy membership remains
under the external policy administrator; factory attachment does not create or mutate a policy.

## Permanent core versus optional offchain composition

**Decision:** retain only issuance, conversion anchors, engine coordination, async entitlement,
migration, and pause controls in `EarnVault`. Put fee state in `EarnFees`, venue custody in engines,
customer-specific swap and cross-domain execution in the scoped Earn router, and optional funding
orchestration in `EarnContributionController`.

**Why:** every EarnVault is a permanent accounting contract and its bytecode budget should be
reserved for state that protects ownership and backing. Each extracted component has one coherent
security boundary rather than being a generic externalization.

## Deployment catalog axes and boundaries

**Decision:** record engine kind and the scoped `earnRouter` on each stack, serve the browser an
allowlisted public stack with no separate product records, and expose the operational `EarnStack`
through `@tempoxyz/earn/deployments/operations` rather than the browser catalog entrypoint.

**Why:** the engine kind (`erc4626`, `veda`, or `propamm`) describes execution, not the asset, so it
belongs to the stack rather than a product indirection. Stack-scoped router addresses preserve the immutable Zone and EarnVault
bindings, and allowlisting public fields keeps the public/operational data boundary explicit.
