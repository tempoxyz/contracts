# Provider-agnostic card spend

Card spend on Tempo for any card provider, from balances cardholders keep in their own accounts:
public or private (in a Zone), in stablecoin or in Tempo Earn shares. The first provider is
[Rain](../docs/cards/rain.md), integrated against Rain's own collateral contracts as they are.

This is a separate Foundry project beside [Earn](../earn/README.md), the
[Zone router](../zone-router/README.md) and the [Bridge integration](../bridge/README.md). It imports
Earn from [`earn/src/`](../earn/src/) and the Zone router from [`zone-router/src/`](../zone-router/src/).

## What is here

- **Two provider-agnostic contracts.** [`CardSpender`](src/CardSpender.sol) pays a spend to a
  destination the program authorizes, from stablecoin, Earn shares or both; the cardholder's account
  calls it for a public spend. [`CardSettler`](src/CardSettler.sol) is the Zone router settler through
  which private spends reach it. Both take one [`CardSpend`](src/CardSpend.sol).
- **One seam per provider.** [`ICardProgram`](src/interfaces/ICardProgram.sol) answers the two
  questions that differ between providers: may this payer pay this destination in this token, and
  may spends redeem from this Earn vault. Rain's adapter is
  [`RainCardProgram`](src/providers/rain/RainCardProgram.sol).
- **Rain's contracts, unchanged.** `RainCollateral`, `RainCollateralFactory` and
  `RainCollateralController`, vendored from their verified Polygon sources and built to the same
  bytecode ([`vendor/VENDORED.md`](vendor/VENDORED.md)).
- **Tests and an E2E.** Foundry tests against Rain's real contracts and Tempo's precompiles, and
  [`e2e/cards`](../e2e/cards/), which runs every flow on a disposable Tempo L1 and Zone.

## How it works

- Public: the provider's access key, which the cardholder scoped to approving the `CardSpender` and
  calling `spend`, sends one L1 transaction from the cardholder's account: approve the exact amount,
  spend, clear the approval. For Rain the spend funds the cardholder's own collateral contract, as
  Rain's real-time funding commits a purchase at authorization.
- Private: the provider's Zone key withdraws to the Zone's `ZoneRouter`, which hands `maxInput` to the
  program's `CardSettler`. The settler spends through the same `CardSpender` and returns the change,
  and the router deposits it back into the Zone, so the settlement names no cardholder. For Rain the
  spend funds the program's pooled collateral contract.
- After the money lands, the provider's own contracts take over. For Rain: the daily payment to its
  treasury and refunds, each authorized by Rain's controller admin's signature.

[`docs/cards/design.md`](../docs/cards/design.md) owns the design and how Bridge's integration maps
onto it; [`docs/cards/rain.md`](../docs/cards/rain.md) owns the Rain provider.

## Running it

```bash
scripts/solidity-deps.sh cards   # from the repository root
cd cards
FOUNDRY_PROFILE=ci forge test
```

The E2E needs Docker, Node 22 and pnpm:

```bash
forge build
pnpm e2e:cards -- --earn         # from the repository root; --provider rain is the default
```

`script/rain/build-fixture.sh --verify` rebuilds `test/fixtures/rain.json` from `vendor/rain` and checks
each contract against the bytecode Rain deployed on Polygon, through Sourcify.

## Layout

```text
src/
  CardSpend.sol             The one struct public and private spends settle
  CardSpender.sol           Pays a spend: stablecoin, Earn, or both, to a program-authorized destination
  CardSettler.sol           The Zone router settler for private spend
  interfaces/               ICardProgram (the provider seam), the Earn vault subset
  providers/rain/           RainCardProgram and the Rain interfaces it reads
script/
  CardsE2EDeploy.s.sol      A Rain program on a disposable L1 for e2e/cards
  RainStack.sol             Deploys Rain's contracts from the fixture
  rain/                     Builds the fixture with Rain's own compiler settings
test/
  harness/                  Tempo, Earn and Rain world
  unit/                     Spender, settler, Rain lifecycle, and a second provider
  fixtures/rain.json        Rain's creation code
vendor/rain/                Rain's verified sources (VENDORED.md)
```
