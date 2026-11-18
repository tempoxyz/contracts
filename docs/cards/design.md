# Design

How a card from any provider pays from funds a cardholder keeps on Tempo, publicly or in a Zone, in
stablecoin or Tempo Earn shares. Every program is a `CardSpender` over one provider engine, its
`ICardProvider`, deployed by a `CardFactory`. The shape follows Tempo Earn: a stable contract users
point at (Earn's `EarnVault`, here the program), over a provider-specific engine (Earn's
`IEarnEngine`, here the provider contract) whose optional behavior is an ERC-165 capability. This page owns the
shared design; [bridge/](bridge/README.md) and [rain/](rain/README.md) own each provider.

## Components

| Contract                                                                    | Admin                    | Function                                                                                                       |
| --------------------------------------------------------------------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------- |
| [`CardSpender`](../../cards/src/core/CardSpender.sol)                       | None                     | Pays a `CardSpend` to a destination its provider authorizes; public entry point and the Zone router's spender. |
| [`CardFactory`](../../cards/src/core/CardFactory.sol)                       | None                     | Deploys a program at a CREATE2 address fixed by its ID, provider and router factory.                           |
| [`ICardProvider`](../../cards/src/core/interfaces/ICardProvider.sol) engine | The provider's contracts | Decides destinations, Earn vaults and the provider's pause; optionally names what the program pays through.    |
| [`ZoneRouter`](../../zone-router/src/ZoneRouter.sol) (Spend op)             | None                     | Receives the Zone withdrawal, hands `maxInput` to the program (its listed spender), returns the change.        |

| Provider | Provider contract                                                       | How the program pays                                                                       |
| -------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Rain     | [`RainProvider`](../../cards/src/providers/rain/RainProvider.sol)       | Directly, into a Rain collateral contract.                                                 |
| Bridge   | [`BridgeProvider`](../../cards/src/providers/bridge/BridgeProvider.sol) | Through the program's Bridge spender clone and the "TS" handler, into a settlement wallet. |

A program has one address for its life, and cardholders' access keys and the Zone's router name it. It
is never upgraded or migrated: its constructor takes only its provider and the `ZoneRouterFactory` whose
routers may call `spendFrom` (its `CardFactory`'s), and a provider replaces a program by deploying a new one, which means cardholders authorize a new key and the Zone admits a new
router. The program is ownerless, with no setter, no pause of its own and no operator key in the audit
scope.

A program needs no pause of its own. Bridge's spender factory pause stops its programs through
`BridgeProvider.paused()`, which also reads as paused while the factory would not route the clone's "TS"
calls. Rain's contracts have no pause, so Rain has no on-chain stop: it stops a program by revoking its
access keys and Zone keys, the only senders of its spends, which can pay only destinations the provider
authorizes (for Rain, collateral Rain controls). Cardholders can revoke their keys, and a
fix to the core means a new program either way.

## The provider

`ICardProvider` answers three questions on every spend:

- `isAuthorizedDestination(payer, destination, token, hint, isPrivate)`: may this payer's spend of this
  token pay this destination? `hint` is the provider's evidence about the destination, carried in
  `CardSpend.destinationHint`. `isPrivate` comes from the program, true only for `spendFrom`, so a provider
  contract applies "a private spend must not name the cardholder" without inspecting the payer. A private
  spend has no payer: the program passes zero.
- `isAllowedVault(vault)`: may spends redeem this Earn vault's shares? A vault's `withdrawExact` decides
  where redeemed value goes, so allowing one is as strong as adding a destination.
- `paused()`: have the provider's own contracts stopped spends?

The optional `ICardProviderPayout` capability names a `payoutTarget` and the `payoutData` for a spend. When
the provider declares it (ERC-165, read once in the constructor), the program pays by approving the target
for the spend's input and calling it as the payer. Bridge needs this because its factory must govern
every spend through its own clone; a provider without such contracts, like Rain, lets the program pay
directly. Either way the program checks the destination got exactly the amount.

## Flows

```mermaid
sequenceDiagram
    participant P as Provider backend
    participant A as Cardholder account
    participant Z as Cardholder Zone account
    participant R as ZoneRouter
    participant C as CardSpender
    participant T as Payout target (Bridge clone) or none
    participant D as Provider destination
    Note over P,A: Public
    P->>A: L1 tx, provider access key
    A->>C: approve(exact), spend, approve(0)
    C->>D: pay directly, or through T
    Note over P,Z: Private
    P->>Z: Zone tx, provider Zone key
    Z->>R: requestWithdrawal (callback)
    R->>C: transfer maxInput, spendFrom
    C->>D: pay directly, or through T
    C->>R: return unused input
    R->>Z: depositEncrypted(change)
```

- **Public.** The provider sends one L1 transaction from the cardholder's account, signed with an access
  key the cardholder scoped to `token.approve(recipient = program)` and `program.spend`, with a periodic
  limit. It approves the exact amount (and, for Earn, the share quote), spends and clears the approval.
  The provider approves the card on the L1 receipt.
- **Private.** The provider sends one Zone transaction from the cardholder's Zone account, signed with a
  Zone key scoped to the outbox, that withdraws `maxInput` plus change to the router with Spend callback
  data naming the program as spender. The provider approves the card on the Zone receipt; the L1 settles
  about a second later on a local Zone. If settlement reverts, the portal returns the whole withdrawal to
  the Zone and the provider's reserve covers the card.

The withdrawal parameters, fees, change and callback gas follow the Bridge design's
[private spend](bridge/design.md#withdrawal-parameters); the `CardSpend` callback is 896 bytes of the
outbox's 1,024. Bridge's callback gas figures were measured on its payout path. `warm` does nothing
for a program that pays directly (Rain); anyone calls `warmVault(vault)` instead, for a vault the provider
allows, so its first Earn spend does not create the standing approval to that vault (a new allowance slot,
TIP-1000). Anyone may also send a program one unit of each token it handles: `spendFrom` treats what the
program holds as its baseline and leaves it there, so a spend never creates the program's balance slot
(about 250k gas). The Rain E2E requests 3,000,000.

## Card programs

On the reservation core (the precompile at `0x5245…`, gated at T15) a card authorization is a native hold
rather than an immediate spend. The core keeps only what must be atomic with TIP-20 balances: holds,
captures, refunds, capped debt and liens. Everything card-specific lives in holder contracts an owner
approves per token with `approveHolder`, whose allowance caps what the holder has outstanding even if
the program is wrong. Programs read the core through
[`IReservationCore`](../../cards/src/programs/interfaces/IReservationCore.sol); tests run them on a model
of it, [`MockReservationCore`](../../cards/test/programs/harness/MockReservationCore.sol).

| Contract                                                            | Admin                     | Function                                                                                                    |
| ------------------------------------------------------------------- | ------------------------- | ----------------------------------------------------------------------------------------------------------- |
| [`CardAuth`](../../cards/src/programs/CardAuth.sol)                 | The issuer, within owners | Cards, limits, mandates, operators, funding orders and purchases (one slot each); a waterfall over sources. |
| [`CashSource`](../../cards/src/programs/CashSource.sol)             | None                      | Cash legs: holds on a stablecoin, debt within the owner's caps, stand-ins, conversion at a locked rate.     |
| [`SavingsSource`](../../cards/src/programs/SavingsSource.sol)       | None (a fixed funder)     | Savings legs: holds on Earn shares, redeemed at capture and paid to the settlement account.                 |
| [`CreditSource`](../../cards/src/programs/CreditSource.sol)         | Each line's lender        | Credit legs: holds on the lender's balance, statements and autopay, optionally secured by locked shares.    |
| [`IssuerTreasury`](../../cards/src/programs/IssuerTreasury.sol)     | The issuer                | Issuer funds that advance payouts within the program's exposure; the settlement token change.               |
| [`IssuerDesk`](../../cards/src/programs/IssuerDesk.sol)             | The issuer                | Provisional credit while a dispute runs, and its recovery when the merchant wins.                           |
| [`MerchantReserves`](../../cards/src/programs/MerchantReserves.sol) | The issuer                | Reserves held back on merchants' balances as core pledges, collected to the settlement account.             |

- **Cards.** A card has an owner, a status (active, frozen, closed), an expiry, the source kinds it may
  draw on (cash, savings, credit) and limits per purchase, per day and per 30-day month. The owner
  freezes, unfreezes and closes it, lowers its limits and sets the ceiling the issuer may raise them to;
  the issuer issues, replaces and raises within that ceiling. Owners revoke merchants or cap a merchant's
  monthly spend, and grant the program terms across their cards. Limits and operator caps are kept in the
  program's first settlement token, so they survive a change of settlement token.
- **Funding order.** Each owner lists up to four entries, each a source the issuer approved and a
  position at it: for cash the token and the most a conversion may cost, for credit the line. A purchase
  keeps the order it was placed under. A source implements
  [`ISource`](../../cards/src/programs/interfaces/ISource.sol) and places, captures, releases and
  refunds its own core holds (it is their placer and payee), paying what it takes to the settlement
  account in the same call.
- **Authorize.** `authorize(card, ref, amount, merchant, expiresAt, flags)` checks the card, its windows
  and the mandate on the amount the sources hold, asking each entry in order to hold what is still
  missing; with `PARTIAL` it approves less. Any failure reverts every leg. A purchase is one storage
  slot, never deleted, so a reference never repeats; a leg's id is `keccak256(ref, entry)`. A stand-in
  approved offline is one cash hold: the core reserves what is there and captures the shortfall as debt
  within the owner's offline cap.
- **Capture, release, refund.** `capture(ref, amount, isFinal)` takes each leg's hold in order; what the
  holds lack comes from the first cash leg's free funds and then debt within the owner's caps, and the
  issuer absorbs the rest. A capture past the open amount stays within the owner's capture tolerance.
  `release` frees every leg (the issuer at any time, anyone after expiry). `refund` pays credit legs back up
  to what each captured, in reverse order, and the cash or savings leg the rest, never past what the
  sources covered; debt the owner owes a source is forgiven first. `charge` posts with no hold: the
  owner's cash sources cover it, debt included, and the issuer absorbs the rest.
- **Conversion.** A cash leg in a stablecoin other than the settlement token locks the rate when placed
  and converts what it captures through the program's `Conversion`: at the locked rate while the market
  stays within the owner's tolerance, at today's price past it, never past the owner's maximum cost and
  always above the conversion's slippage floor. Converted legs never create debt.
- **Settlement log.** Every step emits one event with the purchase reference and a sequence number;
  captures, charges and refunds carry what the sources covered, and credit a won dispute keeps
  (`creditBack`) counts as a refund. The issuer's
  `acknowledgeSettlement(throughSeq)` moves a settled-through cursor, so what is owed rebuilds from events.
  `exposure()` reports what open purchases hold, the stand-in part, and the unacknowledged net, which the
  issuer treasury keeps funds behind. With the treasury registered as its exposure guard
  (`setExposureGuard`, after the settings delay), CardAuth refuses an authorization, increase or charge
  that takes held plus unsettled past the sponsor collateral; decreases, captures and releases still go through.
- **Savings.** The savings source captures only its own legs, never beyond what the hold reserves plus
  the owner's budget, so no share debt arises; it keeps standing approvals to its vault. When the vault
  quotes but cannot redeem, the float pays and the shares wait for the funder.
- **Out of scope.** Interest beyond credit lines' simple rate, fees, rewards, escheat and estates are
  issuer services, built from plain transfers, holds and charges.

## What the program checks

- `CardSpend.program` is this program (`WrongProgram`); `amount` is above zero and `fromVault` at most
  `amount` (`InvalidAmount`).
- `token` is a TIP-20 (`UnsupportedToken`), so no transfer callback, fee or rebase can upset the
  exact-credit checks. An Earn spend's vault holds `token`, so its asset is a TIP-20 too.
- A program that pays directly asks its provider: it has not paused the program (`ProgramPaused`), it
  authorizes the destination for this payer, token and path (`DestinationNotAuthorized`), and an Earn
  spend's vault is allowed and holds `token` (`VaultNotAllowed`, `IncorrectAssetForVault`). A program
  that pays through a payout target leaves those rules to the target, which enforces them in the same call
  (`ICardProviderPayout`); asking the provider first would only repeat them. Either way a spend burns at
  most `maxShares` (`ShareCostExceeded`; zero accepts the live price).
- The destination's balance of `token` rises by exactly `amount` (`DestinationNotCredited`).
- A private destination may be neither the calling router nor an alias resolving to it
  (`DestinationNotAuthorized`): the router returns only unused input, not the redeemed asset.
- A public Earn refund is what the program measurably still holds of the shares it pulled, not what the
  vault reports burning, so a vault that under-reports cannot make it refund its own balance
  (`ShareCostExceeded` if the vault took more). The refund increases the payer's share balance by
  exactly the unused amount (`RefundNotCredited`). A receive policy that redirects the refund reverts the entire spend, including
  the redemption and provider payment; allowing the program to refund shares permits a retry.
- A virtual destination (TIP-1022) is credited through its master, so the program checks the master's
  balance, and redeems Earn shares for one to itself first and transfers them on, since Earn's engines
  check the literal receiver.
- `spendFrom`: the caller is a router the program's `ROUTER_FACTORY` deployed whose mode lists the program
  (`NotRouter`), so `maxInput` is what a router measured and sent; the input is the stablecoin, or the
  vault's EarnShare when Earn funds all of it (`WrongInputToken`); the program holds at least `maxInput`
  (`InsufficientInput`) and spends from no more than it; the spend consumes some input (`NothingSpent`);
  the unused input goes back to the caller and the program ends at its baseline (`ResidualBalance`). On
  the direct path the vault prices the shares, capped by the lower of `maxInput` and `maxShares`.
- A payout through the provider's target uses exactly the stablecoin part, and for Earn at most the share
  cost the program quoted before the call (`InputNotConsumed`), so a replaced target can neither keep the
  rest of the input nor burn more shares than the amount costs and keep the surplus assets. Anything
  beyond the spend's input reverts.
- A transient lock stops reentry. Standing approvals (to an allowed vault, or to the payout target) are
  harmless because the program holds at most a one-unit seed between spends.
- Events: `CardSpent(ref, payer, destination, token, amount, fromVault, sharesUsed, isPrivate)`, and for a
  private spend `InputSpent(ref, inputToken, inputConsumed, inputReturned)`. A private spend's payer is
  the router, so neither names a cardholder or the Zone `senderTag`.

## Invariants

The [card spend threat model](../threat-models/card-spend.md#security-invariants) owns the invariants every program keeps.

Tests: [`cards/test/core/`](../../cards/test/core/) runs every program behavior twice, paying directly and
through a payout target, with mock provider contracts and no real provider; each provider's tests run its provider contract on a
real program ([bridge](bridge/harness.md), [rain](rain/README.md#evidence)), and
[`e2e/cards`](../../e2e/cards/) runs both on a real L1 and Zone.

## Privacy

"Private" means the L1 settlement does not name the cardholder: the payer is the router, the destination
is one the program shares across cardholders, and the change returns as an encrypted deposit. The Zone's
sequencer sees the cardholder's withdrawal, and the L1 shows each spend's amount, token, destination and
time. A provider contract that authorized a cardholder-specific destination when `isPrivate` is true would break
this, so providers authorize only pooled destinations for a private spend (Rain:
[destinations](rain/README.md#destinations)). `BridgeProvider` answers alike for both paths, so Bridge
governance must authorize only settlement wallets every cardholder shares. A spend's `ref` is public on
the L1: a provider uses a reference that cannot be linked to the cardholder for a private spend, such as
`keccak256(pullId, programSecret)` with a secret of its own per program.

### Reconciliation

Spend events are not proof of payment, and `ref` is advisory: it comes from callback data anyone can
write. A provider reconciles a spend by its transaction and log index, and binds a private spend's
`CardSpent` and `InputSpent` to the Portal's `WithdrawalProcessed` and the router's `Spent` in the same
transaction, a public one to its own access key's transaction. `availableBalance` is an upper bound on what
one spend can pay: it values shares with `previewRedeem`, while a spend pays at the `previewWithdraw`
cost, which rounds against the payer, and a private spend carries one token, so it never mixes the
stablecoin and shares.

## Accepted risks

The [card spend threat model](../threat-models/card-spend.md#accepted-risks) owns the risks the design accepts.

## Adding a provider

1. Vendor the provider's contracts unmodified under `cards/vendor/<provider>/` and record their provenance
   in [VENDORED.md](../../cards/vendor/VENDORED.md).
2. Write its `ICardProvider` in `cards/src/providers/<provider>/`, reading the provider's contracts as they
   are. Authorize only pooled destinations when `isPrivate` is true. Implement `ICardProviderPayout` only if
   the provider's own contracts must move the funds.
3. Deploy a program with `CardFactory.deploy(programId, provider)`, on the `CardFactory` for the
   `ZoneRouterFactory` whose routers may call it, and a Spend-mode router from that factory that lists it.
4. Add a provider to [`e2e/cards/src/providers/`](../../e2e/cards/src/providers/) implementing
   [`CardProvider`](../../e2e/cards/src/provider.ts): deploy, the three destinations, and its own
   settlement.
