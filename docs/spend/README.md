# Card spend

Card spend on Tempo from balances cardholders keep in their own accounts: public or private (in a
Zone), in stablecoin or in Tempo Earn shares, for each card provider. Two providers are integrated:
[Bridge](bridge/README.md), on its spender factory and clones, and [Rain](rain/README.md), on its
collateral contracts. Both providers' contracts are used as they are.

The `spend` domain sits in the repository's one Foundry project beside [Earn](../earn/overview.md)
and the [Zone router](../zone/README.md). It imports Earn from [`src/earn/`](../../src/earn/) and the
Zone router from [`src/zone/`](../../src/zone/) by relative path rather than copies.

## Layout

Paths are relative to the repository root.

```text
src/spend/                  Ours, provider-agnostic
  CardSpender.sol             One program: public spends, and the Zone router's spender for private ones
  CardFactory.sol             Deploys programs at addresses fixed by their ID, provider and router factory
  CardSpend.sol               The one struct public and private spends settle
  providers/                Ours, one directory per card provider
    bridge/                   BridgeProvider, the "TS" handler (SpenderTempoSpend), Bridge interfaces
    rain/                     RainProvider, Rain interfaces
src/interfaces/spend/       ICardProvider and ICardProviderPayout (the provider engine), the Earn vault subset
vendor/                     Providers' own contracts, unmodified (VENDORED.md)
  bridge/                   Bridge's spender factory, clone and handlers
  rain/                     Rain's collateral, factory and controller (verified Polygon sources)
  tempo-zones/              The Zones runtime the Bridge harness runs
test/spend/
  core/                     CardSpender paying directly and through a payout target, CardFactory, mock providers
  bridge/                   Bridge harness, rails, card scenario matrix, unit, fork and smoke tests
  rain/                     Rain harness, unit and lifecycle tests, Rain bytecode fixture
  gas/                      Gas snapshots of the TIP-20 spend paths (snapshots/)
script/spend/
  bridge/                   Bridge deploy scripts, release, preflight, smoke test, Zone E2E deploys, matrix
  rain/                     Rain deployer, the Rain E2E deploy, fixture build
```

## How it works

- **Core.** Every program is a `CardSpender` over one provider engine, its `ICardProvider`, deployed by
  `CardFactory`, as an Earn vault sits over an engine. The program is the address cardholders' access keys
  and the Zone's router point at: `spend` for a public spend, `spendFrom` for a private one, which only a
  router its `ZoneRouterFactory` deployed and that lists it may call. It never changes; a provider replaces
  it with a new one. [design.md](design.md).
- **Bridge.** `BridgeProvider` has the program pay through its Bridge spender clone and the "TS" handler, so
  Bridge's factory governs every spend. [bridge/](bridge/README.md).
- **Rain.** `RainProvider` authorizes Rain collateral contracts, and the program pays into them directly.
  [rain/](rain/README.md).

## Running it

Spend tests run on Tempo's real precompiles, under their own Foundry profile. From the repository
root:

```bash
pnpm deps
FOUNDRY_PROFILE=spend-ci forge test
```

The E2E runs need Docker, Node 22 and pnpm. From the repository root:

```bash
pnpm e2e:cards -- --earn         # Rain, on the core contracts
pnpm e2e:bridge -- --earn        # Bridge, on a CardSpender through its clone and handler
```

`script/spend/bridge/smoke.sh` runs Bridge's stack against a Tempo dev node, and
`script/spend/rain/build-fixture.sh --verify --check` checks a fresh build of Rain's contracts against the
bytecode Rain deployed on Polygon, and the committed fixture against that build, without rewriting it.
