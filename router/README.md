# Tempo Zone router

One ownerless router per mode for a Zone's withdrawal callbacks: Earn deposits and redemptions,
and spends through settlers fixed at deployment. The design, its invariants and the card flows are
in [docs/router/zone-router.md](../docs/router/zone-router.md).

This is a separate Foundry project beside [Earn](../earn/README.md) and [Spend](../spend/README.md),
compiled with solc. It imports Earn's interfaces from [`earn/src/`](../earn/src/) rather than a copy,
and Spend's settlers implement its [`ISpendSettler`](src/interfaces/ISpendSettler.sol).

## What is here

- [`ZoneRouter`](src/ZoneRouter.sol): ops 0 (Deposit) and 1 (Redeem), byte-compatible with
  `SingleZoneEarnRouter`, and 2 (Spend), which hands at most the sender's `maxInput` to a listed
  settler and returns the rest to the source Zone.
- [`ZoneRouterFactory`](src/ZoneRouterFactory.sol): permissionless CREATE2 deployment at an address
  fixed by the mode, with `predict`, `isRouter` and `RouterDeployed` for Zone admins.
- [`SendSettler`](src/SendSettler.sol): a settler that pays a public address in the withdrawn
  token, in the vault asset redeemed from EarnShare, or in a stablecoin converted from it at par. A
  mode allows sends only if it lists it.
- [`ISpendSettler`](src/interfaces/ISpendSettler.sol): what a settler implements.
- [`script/deploy/`](script/deploy/): the steps `pnpm earn deploy` runs here for a profile's
  [`zoneRouter`](../profiles/README.md#zone-routers), and `DeploySendSettler.s.sol`.

## Running it

```bash
scripts/solidity-deps.sh router   # from the repository root
cd router
forge build
FOUNDRY_PROFILE=ci forge test
```
