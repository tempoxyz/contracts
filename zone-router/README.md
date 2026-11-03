# Tempo Zone router

One ownerless router per mode for a Zone's withdrawal callbacks on Tempo: Earn deposits and
redemptions, and spends through settlers fixed at deployment. The design, its invariants and each
settler are in [docs/zone-router/zone-router.md](../docs/zone-router/zone-router.md).

This is a separate Foundry project beside [Earn](../earn/README.md) and the
[card integration](../docs/cards/bridge/README.md), compiled with solc. It imports Earn's interfaces from
[`earn/src/`](../earn/src/) rather than a copy. `cards/`' `CardProgram` implements
`ISpendSettler` from here; this project never imports from `cards/`.

## What is here

- [`ZoneRouter`](src/ZoneRouter.sol): ops 0 (Deposit) and 1 (Redeem), byte-compatible with
  `SingleZoneEarnRouter`, and 2 (Spend), which hands at most the sender's `maxInput` to a listed
  settler and returns the rest to the source Zone.
- [`ZoneRouterFactory`](src/ZoneRouterFactory.sol): permissionless CREATE2 deployment at an address
  fixed by the mode, with `predict`, `isRouter` and `RouterDeployed` for Zone admins.
- [`src/settlers/`](src/settlers/): the settlers a Spend mode can list, each adapting one payee
  system. A mode allows a settler only if it lists it.
  - [`SendSettler`](src/settlers/SendSettler.sol) pays a public address in the withdrawn token, in
    the vault asset redeemed from EarnShare, or, for the one vault it is bound to at deployment, in
    the stablecoin that vault's asset converts into at par.
  - A card program's `CardProgram` implements the same interface in [`cards/src/core/`](../cards/src/core/).
- [`ISpendSettler`](src/interfaces/ISpendSettler.sol): what a settler implements.
- [`script/deploy/`](script/deploy/): the steps `pnpm earn deploy` runs here for a profile's
  [`zoneRouter`](../profiles/README.md#zone-routers), and `DeployRouterRelease.s.sol`, which the
  [Zone Router Release](../docs/deployment/deployment.md#zone-router-releases) workflow runs for the
  factory, a `SendSettler` and routers.

## Running it

```bash
scripts/solidity-deps.sh zone-router   # from the repository root
cd zone-router
forge build
FOUNDRY_PROFILE=ci forge test
```
