# Card spend

Card spend on Tempo from balances cardholders keep in their own accounts: public or private (in a
Zone), in stablecoin or in Tempo Earn shares, for each card provider. Two providers are integrated:
[Bridge](../docs/cards/bridge/README.md), on its spender factory and clones, and
[Rain](../docs/cards/rain/README.md), on its collateral contracts. Both providers' contracts are used as
they are.

This is a separate Foundry project beside [Earn](../earn/README.md) and the
[Zone router](../zone-router/README.md). It imports Earn from [`earn/src/`](../earn/src/) and the Zone
router from [`zone-router/src/`](../zone-router/src/) rather than copies.

## Layout

```text
src/
  core/                     Ours, provider-agnostic
    CardSpender.sol           One program: public spends, and the Zone router's spender for private ones
    CardFactory.sol           Deploys programs at addresses fixed by their ID, provider and router factory
    CardSpend.sol             The one struct public and private spends settle
    interfaces/               ICardProvider and ICardProviderPayout (the provider engine), the Earn vault subset
  programs/                 Ours, card programs on the reservation core
    CardProgram.sol           An issuer's cards, limits, mandates and funding order; purchases as one to three holds
    SavingsFacility.sol       Payee of savings legs: captures Earn shares, redeems them, pays the settlement account
    CreditLine.sol            Lender lines whose draws are holds on the lender's balance, optionally pledge-secured
    interfaces/               IReservationCore (the reservation core precompile)
  providers/                Ours, one directory per card provider
    bridge/                   BridgeProvider, the "TS" handler (SpenderTempoSpend), Bridge interfaces
    rain/                     RainProvider, Rain interfaces
vendor/                     Providers' own contracts, unmodified (VENDORED.md)
  bridge/                   Bridge's spender factory, clone and handlers
  rain/                     Rain's collateral, factory and controller (verified Polygon sources)
  tempo-zones/              The Zones runtime the Bridge harness runs
test/
  core/                     CardSpender paying directly and through a payout target, CardFactory, mock providers
  programs/                 Card programs, the savings facility and credit lines on a model of the reservation core
  bridge/                   Bridge harness, rails, card scenario matrix, unit, fork and smoke tests
  rain/                     Rain harness, unit and lifecycle tests, Rain bytecode fixture
script/
  bridge/                   Bridge deploy scripts, release, preflight, smoke test, Zone E2E deploys, matrix
  rain/                     Rain deployer, the Rain E2E deploy, fixture build
```

## How it works

- **Core.** Every program is a `CardSpender` over one provider engine, its `ICardProvider`, deployed by
  `CardFactory`, as an Earn vault sits over an engine. The program is the address cardholders' access keys
  and the Zone's router point at: `spend` for a public spend, `spendFrom` for a private one, which only a
  router its `ZoneRouterFactory` deployed and that lists it may call. It never changes; a provider replaces
  it with a new one. [docs/cards/design.md](../docs/cards/design.md).
- **Card programs.** `CardProgram` is an issuer's holder contract on the reservation core: it keeps card
  records and limits and turns a purchase into holds on the cardholder's cash and Earn shares and a draw on a
  `CreditLine`, captured, released and refunded in one call each.
  [docs/cards/design.md](../docs/cards/design.md#card-programs).
- **Bridge.** `BridgeProvider` has the program pay through its Bridge spender clone and the "TS" handler, so
  Bridge's factory governs every spend. [docs/cards/bridge/](../docs/cards/bridge/README.md).
- **Rain.** `RainProvider` authorizes Rain collateral contracts, and the program pays into them directly.
  [docs/cards/rain/](../docs/cards/rain/README.md).

## Running it

```bash
scripts/solidity-deps.sh cards   # from the repository root
cd cards
FOUNDRY_PROFILE=ci forge test
```

The E2E runs need Docker, Node 22 and pnpm. From the repository root:

```bash
pnpm e2e:cards -- --earn         # Rain, on the core contracts
pnpm e2e:bridge -- --earn        # Bridge, on a CardSpender through its clone and handler
```

`script/bridge/smoke.sh` runs Bridge's stack against a Tempo dev node, and
`script/rain/build-fixture.sh --verify --check` checks a fresh build of Rain's contracts against the
bytecode Rain deployed on Polygon, and the committed fixture against that build, without rewriting it.
