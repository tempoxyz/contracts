# Tempo Zone router

One ownerless router per mode for a Zone's withdrawal callbacks on Tempo: Earn deposits and
redemptions, and spends through settlers fixed at deployment. The design, its invariants and each
settler are in [docs/zone-router/zone-router.md](../docs/zone-router/zone-router.md).

This is a separate Foundry project beside [Earn](../earn/README.md) and the
[Bridge integration](../bridge/README.md), compiled with solc. It imports Earn's interfaces from
[`earn/src/`](../earn/src/) rather than a copy. Bridge's "TS" handler in `bridge/` imports the
`Spend` struct from here, so the handler and `BridgeSettler` encode the same spend.

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
  - [`BridgeSettler`](src/settlers/BridgeSettler.sol) settles a card spend through one Bridge card
    program's spender clone and its "TS" handler. [`settlers/bridge/`](src/settlers/bridge/IBridgeSpender.sol)
    holds the `Spend` struct and the two Bridge calls it makes.
- [`ISpendSettler`](src/interfaces/ISpendSettler.sol): what a settler implements.
- [`script/deploy/`](script/deploy/): the steps `pnpm earn deploy` runs here for a profile's
  [`zoneRouter`](../profiles/README.md#zone-routers), and `DeployRouterRelease.s.sol`, which the
  [Zone Router Release](../docs/deployment/deployment.md#zone-router-releases) workflow runs for the
  factory, each settler and routers.

## Running it

```bash
scripts/solidity-deps.sh zone-router   # from the repository root
cd zone-router
forge build
FOUNDRY_PROFILE=ci forge test
```
