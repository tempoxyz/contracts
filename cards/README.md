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
    CardProgram.sol           One program: public spends, and the Zone router's settler for private ones
    CardFactory.sol           Deploys programs at addresses fixed by their ID, issuer and guardian
    CardSpend.sol             The one struct public and private spends settle
    interfaces/               ICardIssuer and ICardIssuerPayout (the provider engine), the Earn vault subset
  providers/                Ours, one directory per card provider
    bridge/                   BridgeIssuer, the "TS" handler (SpenderTempoSpend), Bridge interfaces
    rain/                     RainIssuer, Rain interfaces
vendor/                     Providers' own contracts, unmodified (VENDORED.md)
  bridge/                   Bridge's spender factory, clone and handlers
  rain/                     Rain's collateral, factory and controller (verified Polygon sources)
  tempo-zones/              The Zones runtime the Bridge harness runs
test/
  core/                     CardProgram paying directly and through a payout target, CardFactory, mock issuers
  bridge/                   Bridge harness, rails, card scenario matrix, unit, fork and smoke tests
  rain/                     Rain harness, unit and lifecycle tests, Rain bytecode fixture
script/
  bridge/                   Bridge deploy scripts, release, preflight, smoke test, Zone E2E deploys, matrix
  rain/                     Rain deployer, the Rain E2E deploy, fixture build
```

## How it works

- **Core.** Every program is a `CardProgram` over one provider engine, its `ICardIssuer`, deployed by
  `CardFactory`, as an Earn vault sits over an engine. The program is the address cardholders' access keys
  and the Zone's router point at: `spend` for a public spend, `settle` for a private one. It never changes;
  a provider replaces it with a new one. [docs/cards/design.md](../docs/cards/design.md).
- **Bridge.** `BridgeIssuer` has the program pay through its Bridge spender clone and the "TS" handler, so
  Bridge's factory governs every spend. [docs/cards/bridge/](../docs/cards/bridge/README.md).
- **Rain.** `RainIssuer` authorizes Rain collateral contracts, and the program pays into them directly.
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
pnpm e2e:bridge -- --earn        # Bridge, on a CardProgram through its clone and handler
```

`script/bridge/smoke.sh` runs Bridge's stack against a Tempo dev node, and
`script/rain/build-fixture.sh --verify` checks Rain's fixture against the bytecode Rain deployed on
Polygon.
