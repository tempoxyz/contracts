# Tempo Zone router

One ownerless router per mode for a Zone's withdrawal callbacks on Tempo: Earn deposits and
redemptions, and spends through spenders fixed at deployment. The design, its invariants and each
spender are in [zone-router.md](zone-router.md).

The `zone` domain sits in the repository's one Foundry project beside [Earn](../earn/overview.md)
and [card spend](../spend/README.md). It imports Earn's interfaces from
[`src/interfaces/earn/`](../../src/interfaces/earn/) rather than a copy. Card spend's `CardSpender`
implements `ISpender` from here; nothing in `src/zone/` imports from `src/spend/`.

## What is here

- [`ZoneRouter`](../../src/zone/ZoneRouter.sol): ops 0 (Deposit) and 1 (Redeem), byte-compatible with
  `SingleZoneEarnRouter`, and 2 (Spend), which hands at most the sender's `maxInput` to a listed
  spender and returns the rest to the source Zone.
- [`ZoneRouterFactory`](../../src/zone/ZoneRouterFactory.sol): permissionless CREATE2 deployment at an
  address fixed by the mode, with `predict`, `isRouter` and `RouterDeployed` for Zone admins.
- [`src/zone/spenders/`](../../src/zone/spenders/): the spenders a Spend mode can list, each adapting one
  payee system. A mode allows a spender only if it lists it, and
  [`SpenderAuth`](../../src/zone/spenders/SpenderAuth.sol) lets a spender accept only its factory's
  routers that list it.
  - [`SendSpender`](../../src/zone/spenders/SendSpender.sol) pays a public address in the withdrawn
    token, in the vault asset redeemed from EarnShare, or, for the one vault it is bound to at
    deployment, in the stablecoin that vault's asset converts into at par, for the routers of the
    factory it binds.
  - A card program's `CardSpender` implements the same interface in [`src/spend/`](../../src/spend/).
- [`ISpender`](../../src/interfaces/zone/ISpender.sol): what a spender implements.
- [`script/zone/deploy/`](../../script/zone/deploy/): the steps `pnpm earn deploy` runs here for a
  profile's [`zoneRouter`](../../profiles/README.md#zone-routers), and `DeployRouterRelease.s.sol`, which
  the [Zone Router Release](../deployment/deployment.md#zone-router-releases) workflow runs for the
  factory, a `SendSpender` and routers.
- [`test/zone/`](../../test/zone/): the router, factory and spender tests.

## Running it

From the repository root:

```bash
pnpm deps
forge build
FOUNDRY_PROFILE=ci forge test --match-path 'test/zone/**'
```
