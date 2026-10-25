# Existing vault migration

This page owns migration into and between Earn stacks: holder opt-in from an existing ERC-4626
vault, holder-composed exits from other source vaults, whole-pool engine migration, and per-holder
replacement of a `UserOnly` stack. It has no deployment module of its own: it uses the core
`EarnVault` (`depositVenueShares`, `migrateEngine`), the [ERC-4626 engine](erc4626-engine.md)'s
in-kind entry, and optionally the [Zone router](zone-router.md).

Two operations are easy to conflate:

- **Holder migration:** each holder opts in by exchanging existing vault shares, or the base assets
  they redeem to, for EarnShare.
- **Engine migration:** on an `OperatorEnabled` stack, the EarnVault operator moves the entire active
  pool from one engine to another without changing EarnShare balances.

The choice is fixed at deployment by the profile's `core.migrationMode` (`UserOnly` by default; only
`OperatorEnabled` is authored, see the [profile schema](../../../profiles/README.md#schema)). `UserOnly`
permanently disables `migrateEngine`, and no setter can enable it later.

## Entry with existing venue shares

The simplest path is to deploy Earn with an `ERC4626Engine` around the existing vault, so its shares
become valid in-kind input. A holder can enter in kind when:

1. they hold transferable shares of an ERC-4626 vault;
2. that exact vault is the current engine's immutable `vault`;
3. it uses the same base asset as the Earn stack;
4. its transfer policy lets the engine receive the shares; and
5. the client can supply a recent, nonzero `minEarnShares`.

`depositVenueShares` accepts only the current engine's vault token and does not discover a venue.
Any other source position must be redeemed or converted first
([source-vault composition](#source-vault-composition)).

**Deploy around the existing vault.** Name it as the profile's `engine.venue`, or, when the vault
reports an empty or unsuitable name or symbol, create the engine through `ERC4626EngineFactory` with
reviewed metadata overrides and name it as `engine.address` ([ERC-4626 deployment](erc4626-engine.md#deployment)).
Overrides affect EarnShare metadata only. Set Earn-level fees knowing any fee the existing vault
already charges, or holders pay twice for the same accrual. No position moves until its holder
opts in.

**Opt in publicly.** The holder approves the engine for the venue shares and calls
`depositVenueShares(venueShares, receiver, minEarnShares)` (or the self-recipient overload
`depositVenueShares(venueShares, minEarnShares)` for scoped access keys). The
[in-kind entry sequence](../architecture/flows.md#existing-erc-4626-share-entry) pulls the shares
straight into engine custody and mints EarnShare at the current rate; the EarnVault never holds
them. Paused deposits block it.

**Opt in privately.** The client atomically batches the share approval, `depositVenueShares`, the
EarnShare approval, and `ZonePortal.depositEncrypted`.

Afterwards, confirm the engine (not the EarnVault) received the shares and `isAccountingAligned()`
is still true. An integration may prepend a claim from its source reward system; that claim is not
part of Earn and must be reviewed against the source deployment.

**Close the window.** Define the opt-in deadline, late-holder treatment, and reward cutoff before
announcing the migration. Earn cannot disable an external vault; close its rules, rewards, or fees
through its own controls. Late holders can keep using `depositVenueShares` while that vault is the
current engine's and accepts transfers. On an `OperatorEnabled` stack, the operator may then
[move the active pool](#whole-pool-engine-migration).

## Source-vault composition

Earn has no source-vault entrypoint, and the router does not grow one. A holder leaves a source
vault by composing approvals, the source's own redemption, an EarnVault deposit, and an optional
Zone deposit in one Tempo Transaction. Tempo Transactions already compose atomically, and a router
scoped to its closed loop stays easier to inspect.

Each leg carries its own bounds; if any leg, including the Portal deposit, fails, the whole
transaction reverts. EarnVault measures only what it receives. ERC-4626 conformance of the source
does not establish its solvency, liquidity, valuation, or callback safety, so each supported source
needs its own review.

### Wrapped positions

A fee wrapper may allocate into the ERC-4626 vault the engine holds while giving holders a
different share token, so the holder does not own the vault token `depositVenueShares` accepts. Keep
the underlying vault as the engine's `vault` and compose the wrapper redemption. For a private
replacement position the transaction is:

1. `wrapper.redeem(sourceShares, holder, holder)`;
2. base-asset approval and `EarnVault.deposit(assets, holder, minEarnShares)`; and
3. EarnShare approval and `ZonePortal.depositEncrypted`.

To migrate a whole position, read the holder's wrapper balance, quote the wrapper redemption and the
EarnVault deposit, and simulate the redemption-plus-deposit prefix to get the exact EarnShare amount
for the Portal call. If execution no longer matches the simulation, the batch reverts; a favorable
one-unit rounding remainder stays fully backed and owned by the holder and can be moved privately
later.

## Whole-pool engine migration

Only `OperatorEnabled` stacks permit `migrateEngine(newEngine, minNewEngineShares,
minAssetsRetained)`. The replacement must already be bound to this EarnVault.

```mermaid
sequenceDiagram
    participant O as EarnVault operator
    participant A as EarnVault
    participant F as EarnFees
    participant Old as Old engine
    participant New as New engine

    O->>A: migrateEngine(newEngine, minNewEngineShares, minAssetsRetained)
    A->>A: require OperatorEnabled and zero open requests
    A->>New: require base interface, this EarnVault binding, nonzero share scale, same asset, and an exit capability
    A->>F: accrueFees()
    A->>Old: redeem(all raw engine shares, A, 0)
    Old-->>A: measured assets
    A->>New: deposit(all assets)
    New-->>A: measured newEngineShares
    A->>A: require exact asset consumption and zero old custody; preserve managed/surplus value split within 1 bp
    A->>A: enforce managed-share floor and retained-value floor
    A->>A: switch engine and re-anchor unchanged EarnShare supply
```

When the old engine holds custody, it must advertise immediate redemption, and both bounds must be
nonzero (`ZeroMinimumEngineShares`, `ZeroMinimumAssets`). Derive them from a fresh quote and the
operator's explicit loss tolerance, and simulate the full redemption and replacement deposit against
real venue state first. Both the whole replacement position and its managed portion must meet the
bounds. EarnShare balances, including those held privately in a Zone, and total supply do not
change; the managed/surplus split carries over within one basis point, and the re-anchor starts a
new reward-rate baseline ([accounting anchors](../architecture/system.md#accounting-anchors)).

The migration is atomic. It reverts, leaving the old engine current and its position intact, if an
async request is open (`PendingRedeemsOpen`), the replacement's binding, share scale, asset, or exit
capability is invalid, the old position cannot be fully redeemed, the replacement does not consume
the full measured amount, its share granularity cannot preserve the split, or either bound is
missed. The retained-assets bound matters when the replacement venue's share price can be
manipulated before migration; a share-count bound alone does not prove the new shares preserve NAV.

The operator can point the EarnVault at arbitrary engine code, so on `OperatorEnabled` stacks it
must be a timelock or multisig. Atomicity does not prove the replacement stays safe afterwards: its
code, permissions, valuation, liquidity, and venue behavior need separate review.

## User-only stack replacement

A `UserOnly` stack is replaced by deploying a separate engine, EarnShare, and EarnVault. Each holder
chooses whether to move:

- if the old engine redeems immediately, batch the old redemption and the new deposit with
  independent bounds;
- if the old position is the exact vault token of the new `ERC4626Engine`, use `depositVenueShares`;
- if the source is a conforming same-asset ERC-4626 wrapper, batch its redemption and the new
  deposit; or
- if the old engine needs a queued exit (for example a Veda stack with a dry buffer), request and
  finalize to base assets, then deposit; this cannot be one atomic batch. The deposit pause does not
  block async requests, so a dry buffer plus a pause cannot freeze withdrawals.

The new EarnShare has a different address, so applications, TIP-403 policy, Zone enablement,
accounting, and reward configuration must all be updated. A private holder moves between stacks
with two Zone callbacks: redeem through the old stack's router to the private asset, then deposit
through the new stack's router. Each leg has its own bounds and bounces independently. Private
EarnShare cannot start an async exit, so a queued-only old stack first needs a Zone route to a
public account.

## Accounting

| Action                | Input                                      | EarnShare minted                                      | Who benefits                           |
| --------------------- | ------------------------------------------ | ----------------------------------------------------- | -------------------------------------- |
| `depositVenueShares`  | Shares of the current ERC-4626 vault       | Proportional, to the chosen receiver                  | Depositing holder                      |
| Wrapped-position exit | Wrapper shares redeemed in one transaction | Proportional, from the EarnVault deposit              | Only the consenting holder moves       |
| `contribute`          | Base asset                                 | None to the funder; fee crystallization may mint fees | Existing active holders, net of fees   |
| `migrateEngine`       | The whole active engine position           | None                                                  | No ownership change; the venue changes |
| User-only replacement | Old EarnShare, redeemed to the base asset  | New EarnShare from the replacement EarnVault          | Only the consenting holder moves       |

Existing vault shares are holder principal, so their entry mints EarnShare; reward funding mints
nothing and raises the value of existing EarnShare instead. `minEarnShares` protects a holder from
a contribution, rate change, fee checkpoint, or rounding change after the quote; a missed minimum
reverts the share transfer and the mint together.

## Privacy

Moving a public position into a Zone does not erase its public history: the source account,
approval, share amount, `depositVenueShares` call, EarnShare mint, Portal deposit amount, and timing
are public and can be correlated. Do not describe this as unlinking the position; the rest follows
the [privacy model](../architecture/security-and-privacy.md#privacy-model).

## Failure and recovery

| Failure                                   | Result                                                             | Recovery                                                                  |
| ----------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Wrong venue-share token                   | The engine cannot pull it; the transaction reverts                 | Use the current engine's vault token, or convert through a separate route |
| Portal call fails in an atomic batch      | Every earlier leg and approval in the batch reverts                | Fix Zone enablement, policy, payload, balance, or allowance and retry     |
| Portal accepts but Zone credit is delayed | The public Portal deposit stays accepted while the Zone catches up | Follow the Zone protocol's deposit status                                 |

Out of scope: forced migration of nonconsenting `UserOnly` holders (they stay redeemable in the old
stack), migration across base assets, transfer of private identity or history from another privacy
system, source reward claims, tax treatment, holder communications, offchain eligibility, and
guaranteed Zone settlement after the Portal accepts a deposit.

## Tests

- Foundry: [`EarnVaultVenueShares.t.sol`](../../../earn/test/core/EarnVaultVenueShares.t.sol) and
  [`EarnVaultMigration.t.sol`](../../../earn/test/core/EarnVaultMigration.t.sol), plus migration cases in
  the engine suites.
- E2E: `public-deposit-existing-venue-shares` (group `public`), `controls-operator-authority`
  (group `controls`, including rolled-back invalid migrations), and in group `zone`
  [`migration-existing-vault-shares-to-zone`](../../../e2e/modules/zone/migration.ts) and the local-only
  `migration-morpho-fee-wrapper-to-private-earn`, which runs the wrapped-position composition against
  localnet's Morpho fee-wrapper fixture over the ERC-4626 venue.
