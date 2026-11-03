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
    CardSpend.sol             The one struct public and private spends settle
    CardSpender.sol           Pays a spend from stablecoin, Earn, or both, to a program-authorized destination
    CardSettler.sol           The Zone router settler for private spend
    interfaces/               ICardProgram (the provider seam), the Earn vault subset
  providers/                Ours, one directory per card provider
    bridge/                   "TS" handler (SpenderTempoSpend), BridgeSettler, Bridge interfaces
    rain/                     RainCardProgram (ICardProgram adapter), Rain interfaces
vendor/                     Providers' own contracts, unmodified (VENDORED.md)
  bridge/                   Bridge's spender factory, clone and handlers
  rain/                     Rain's collateral, factory and controller (verified Polygon sources)
  tempo-zones/              The Zones runtime the Bridge harness runs
test/
  core/                     The agnostic contracts with a second, Bridge-shaped provider
  bridge/                   Bridge harness, rails, card scenario matrix, unit, fork and smoke tests
  rain/                     Rain harness, unit and lifecycle tests, Rain bytecode fixture
script/
  bridge/                   Bridge deploy scripts, release, preflight, smoke test, Zone E2E deploys, matrix
  rain/                     Rain deployer, the Rain E2E deploy, fixture build
```

## How it works

- **Core.** `CardSpender` pays a `CardSpend` to a destination the program's `ICardProgram` adapter
  authorizes; the cardholder's account calls it for a public spend. `CardSettler` is the Zone router
  settler private spends reach it through. [docs/cards/design.md](../docs/cards/design.md).
- **Bridge.** Bridge's program runs inside its own spender factory, so its code is a spender handler
  ("TS") the factory routes to, with its own settler. [docs/cards/bridge/](../docs/cards/bridge/README.md).
- **Rain.** Rain has no spender system, so it uses the core contracts through `RainCardProgram`, which
  authorizes Rain collateral contracts. [docs/cards/rain/](../docs/cards/rain/README.md).

## Running it

```bash
scripts/solidity-deps.sh cards   # from the repository root
cd cards
FOUNDRY_PROFILE=ci forge test
```

The E2E runs need Docker, Node 22 and pnpm. From the repository root:

```bash
pnpm e2e:cards -- --earn         # Rain, on the core contracts
pnpm e2e:bridge -- --earn        # Bridge, through its clone and handler
```

`script/bridge/smoke.sh` runs Bridge's stack against a Tempo dev node, and
`script/rain/build-fixture.sh --verify` checks Rain's fixture against the bytecode Rain deployed on
Polygon.
