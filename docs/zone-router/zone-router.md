# Zone router

[`ZoneRouter`](../../zone-router/src/ZoneRouter.sol) takes a Zone's withdrawal callbacks on Tempo: Earn
deposits and redemptions, and spends through settlers fixed at deployment.
[`ZoneRouterFactory`](../../zone-router/src/ZoneRouterFactory.sol) deploys it, and the
[settlers](#settlers) pay a spend: `SendSettler`, in [`src/settlers/`](../../zone-router/src/settlers/),
to a public address, and a card program's `CardSpender`, in [`cards/`](../../cards/README.md), through
its card provider. The router, its factory and `SendSettler` live in the
[`zone-router/`](../../zone-router/README.md) Foundry project, built with solc, which imports only Earn's
interfaces. Card spend through it is in the [card spend design](../cards/design.md).

`SingleZoneEarnRouter` ([Earn's zone router](../earn/modules/zone-router.md)) is the router Earn runs in
production today. `ZoneRouter`'s Earn ops accept its callback data byte for byte and report the same
views, so Earn clients can move to it.

## Modes

A router has no owner and no setters. Its mode is fixed at deployment; a different mode is a new
router.

- **`zoneId`**, the only source Zone (`allowedZoneId`).
- **`enabledOps`**, a bitmask of Deposit, Redeem and Spend. A disabled op reverts `OpDisabled`.
- **`settlers`**, the `ISpendSettler` contracts Spend may use, written once by the constructor.
  Required when Spend is enabled, empty otherwise.
- **`earnVault`, `privateAsset`, `pool`, `customerId`**, as `SingleZoneEarnRouter` binds them.
  Required when Deposit or Redeem is enabled (`pool` and `customerId` only when the private asset is
  not the vault asset), and all zero otherwise.

The constructor rejects inconsistent combinations. A profile states its mode as `ops`, `earn` and
`settlers`; the common modes are:

| Mode                       | Ops                    | Settlers      | Vault |
| -------------------------- | ---------------------- | ------------- | ----- |
| Earn                       | Deposit, Redeem        | —             | Yes   |
| Card, closed loop          | Spend                  | `CardSpender` | —     |
| Card and Earn, closed loop | Deposit, Redeem, Spend | `CardSpender` | Yes   |

One router per Zone can serve several programs by listing each one's `CardSpender`.

## Factory

- **Ownerless and permissionless.** `deploy(mode)` creates the router with CREATE2, salted by the
  mode's hash: one mode has one address, and deploying it again returns the existing router.
  `predict(mode)` gives the address in advance.
- **Provenance.** `isRouter(address)` and `RouterDeployed(router, modeHash, mode)` let a Zone admin
  check that a gateway came from the factory, with the expected mode, before admitting it.
- **One factory per router version.** A new version ships as a new factory; deployed routers keep
  working, and each customer moves by deploying its mode there and having its Zone admit it.
- **Size.** The router's runtime is 10.2 KiB and the factory's 13.4 KiB, under the 24 KiB limit.

Nobody can change a deployed router. Enabling a settler or op means deploying a new router through
the factory and having the Zone's Portal admin admit it as a gateway; the old router stays deployed
so callbacks already on their way finish or bounce. The only authority is the one Zones already
have: which gateways they admit.

## Deployment

A deployment profile's [`zoneRouter`](../../profiles/README.md#zone-routers) deploys one router
with `pnpm earn deploy` beside its Earn stack. The lifecycle runs [`zone-router/`](../../zone-router/README.md)'s
own `script/deploy/` scripts from `zone-router/`, compiled with solc and source-verified like Earn's
contracts:

1. `deploy-zone-router-factory`, unless the profile names a factory;
2. `deploy-zone-router`: `factory.deploy(mode)`, then a check of `isRouter`, `predict` and every
   immutable against the mode. When anyone, such as Bridge with its [router script](../cards/bridge/deploy.md#4-deploy-the-router-for-each-zone), already deployed the mode
   through the factory, the step adopts that router and records its `RouterDeployed` transaction,
   which is also what it records after its own run, so a router someone created in between keeps
   its real creation transaction;
3. activation, each verified onchain and otherwise handed off to its owner: `authorize-zone-router`
   (the PropAMM pool owner admits a converting Earn mode), `enable-zone-router-tokens` (the Zone
   enables EarnShare and the private asset for Earn ops), `register-zone-router-gateway` (the
   Portal administrator admits the router as a callback gateway when the Zone restricts gateways)
   and `admit-zone-router-account` (when the Zone enforces account access with open gateways, the
   router returns funds as an ordinary depositor, so the Portal administrator admits it with
   `setAllowedAccount`; the Portal holds one role per account, so a router needs only one of the
   two, and after the Zone changes gateway mode either step revokes the old role and grants the new
   one in one batch). The lifecycle grants pool, gateway and account admission with its own keys only when it
   deployed the factory itself; for a router from a factory the profile names, each is always handed
   off, for the pool owner or the Portal administrator to check that factory's verified source
   first.

The module also lists the router and its Zone's Portal, Messenger, Outbox and sequencers as
[required members](../earn/modules/access.md#required-members) of EarnShare's access policy.
`pnpm earn verify` rechecks the factory provenance and mode and reports gateway, account,
token and conversion readiness. A profile deploys no settler: it lists deployed ones in
`settlers`, such as a release's `SendSettler` or a card program's `CardSpender`.

Outside a profile, the **Zone Router Release** workflow deploys and source-verifies a
`ZoneRouterFactory`, a `SendSettler`, or a mode's router from
`main` ([Zone router releases](../deployment/deployment.md#zone-router-releases)). Each lands at an address its
build and settings fix: the factory and settlers through the CREATE2 deployer with Earn's release
salt, and a router at its factory's `predict(mode)`, so whoever deploys the same one, Tempo or an
integrator, gets the same contract, and a release reuses one that exists. Admission and pool
authorization stay with their owners, as above.

## Ops

The router reads the first callback word before decoding, so ops 0 and 1 keep
`SingleZoneEarnRouter`'s layout and `viem/tempo`'s `earnRouterCallbackData` works unchanged.

| Op        | Input                               | What the router does                                            | Back to the Zone |
| --------- | ----------------------------------- | --------------------------------------------------------------- | ---------------- |
| 0 Deposit | Private asset                       | As `SingleZoneEarnRouter`                                       | EarnShare        |
| 1 Redeem  | EarnShare                           | As `SingleZoneEarnRouter`                                       | Private asset    |
| 2 Spend   | Any token the source Portal enables | Transfers `maxInput` to a listed settler, measures what it used | Unused input     |

Every return to the source Zone is an encrypted deposit, with a refund recipient, of a token enabled
with deposits active. Ops 0 and 1 use `SingleZoneEarnRouter`'s `ZoneReturn`; Spend's `SpendReturn`
adds `maxDepositFee` and reverts if the Portal's deposit fee is above it. Any revert bounces the whole
input to the withdrawal's fallback recipient in the Zone.

### Spend

Callback data: `op`, `settler`, `maxInput`, `settlerData` and `SpendReturn`, 864 of the outbox's
1,024 bytes with a 64-byte ciphertext. A Spend callback:

1. authenticates as ops 0 and 1, and requires the settler to be listed;
2. requires `0 < maxInput <= amount`, transfers exactly `maxInput` to the settler and calls
   `settle(token, maxInput, settlerData)`; the settler hands back what it did not use;
3. requires `0 < used <= maxInput`, measured from its own balance;
4. returns the change, `amount - used`, to the source Zone when it is not zero, through a standing
   approval to that Portal (below);
5. emits `Spent(settler, token, used, change, zoneDepositHash)`, with a zero hash when there is no
   change, and no `senderTag`, action ID or Zone account. The settler emits its own detail.

`maxInput` is set in the sender's Zone transaction, not by the settler, so no settler can take more
than the sender allowed, and the change always returns. The router transfers rather than approves:
the settler never holds an allowance from it, and the callback skips the roughly 250k gas Tempo
charges for writing an allowance slot. A listed settler that keeps its input without paying looks
settled, within `maxInput`, so settlers are trusted to the extent of the sender's `maxInput`. The
router accepts any enabled token and leaves it to the settler to refuse one it cannot use.

The change goes back through a standing maximum approval to the source Portal, set on the first
spend of a token and topped up only when it runs low. Clearing it after each deposit would create
the allowance slot again on every callback, which Tempo charges (TIP-1000) against the callback's
gas limit; the Portal is the Zone's own, and the router holds nothing between callbacks. Anyone can
set it ahead of the first spend with `warm(token)`. An Earn op on a router that holds this approval uses and keeps it; without one, ops 0 and 1 keep
`SingleZoneEarnRouter`'s exact approval, cleared after the deposit, so an Earn-only router behaves
exactly like it.

## Settlers

A settler adapts one payee system to the Spend op through `ISpendSettler`. A generic one lives in
[`zone-router/src/settlers/`](../../zone-router/src/settlers/); one built for a single integrator lives
with that integration and imports the interface from here. Each has no owner and keeps none of a
callback's input. A mode lists the settlers it allows, and only those can be named in a
callback.

| Settler       | Pays                                                                                | `settlerData`           | Binding fixed at deployment              |
| ------------- | ----------------------------------------------------------------------------------- | ----------------------- | ---------------------------------------- |
| `SendSettler` | A public address, in the withdrawn token or redeemed from Earn                      | `abi.encode(Send)`      | Optional vault, par pool and customer ID |
| `CardSpender` | A destination its provider authorizes (Rain collateral, a Bridge settlement wallet) | `abi.encode(CardSpend)` | The provider                             |

`SendSettler` is released by [Zone Router Release](../deployment/deployment.md#zone-router-releases) and
a Bridge program's `CardSpender` by [Bridge Release](../deployment/deployment.md#bridge-releases), each at a
deterministic address, and listed in a profile's `zoneRouter.settlers`.

### `ISpendSettler`

```text
interface ISpendSettler {
    // Pays from the maxInput of token the router transferred to it before the call. Reverts
    // unless the payment it makes is complete. Transfers all unused input back to the router
    // before returning and keeps none.
    function settle(address token, uint256 maxInput, bytes calldata data) external;
}
```

### `SendSettler`

[`SendSettler`](../../zone-router/src/settlers/SendSettler.sol) pays a public address. A mode allows sends only if
it lists a `SendSettler`; a closed-loop mode, listing only its card program's settler, does not. It
has no owner or setters, and its only setting is an optional conversion binding fixed at deployment:
a vault, a pool pairing that vault's asset with one other stablecoin of equal decimals (its par
stablecoin), and a customer ID, all set or all zero. Its `settlerData` is
`abi.encode(Send(to, token, amount, vault, ref))`, and `to` receives exactly `amount` of `token`:

| `vault`         | `token`                     | Input         | How it pays                                                              |
| --------------- | --------------------------- | ------------- | ------------------------------------------------------------------------ |
| Zero            | The withdrawn token         | That token    | Transfers `amount` (a stablecoin or EarnShare)                           |
| Any vault       | The vault asset             | Its EarnShare | `withdrawExact(amount, to, maxInput)`                                    |
| Its bound vault | That vault's par stablecoin | Its EarnShare | `withdrawExact` to itself, then the pool at the oracle's exact par price |

Conversion runs only from the bound vault's asset into its par stablecoin; any other vault, token
or direction reverts with `ConversionNotAllowed`, so a vault the caller makes up cannot trade through
the pool. The constructor checks the pair and the equal decimals. The settler checks that `to`'s
balance rose by exactly `amount`, so a vault or pool that reports success without paying cannot
settle. For a [virtual address](https://github.com/tempoxyz/tempo/blob/main/tips/tip-1022.md), which
a TIP-20 transfer credits to its registered master, it measures the master that Tempo's address
registry resolves, redeems to itself and transfers to `to` (Earn's engines measure the literal
receiver), and reverts for an unregistered one, as the transfer would. It hands every unused unit
back to the router and keeps no balance or allowance. Whoever builds the callback picks `to` and
`vault` and spends only their own input, capped at `maxInput`. Conversion needs the pool owner to
admit the settler as a taker and recipient.
It emits `SendSettled(ref, to, inputToken, outputToken, amount, inputConsumed, inputReturned)` and
no Zone account or `senderTag`. Deploy one with the [Zone Router Release `sendSettler`](../deployment/deployment.md#zone-router-releases) and list it in a
profile's `zoneRouter.settlers`.

### `CardSpender`

[`CardSpender`](../../cards/src/core/CardSpender.sol) is a card program's settler: `settle` pays the
`CardSpend` in `settlerData` to a destination its provider authorizes for a private spend, directly or through
the provider's payout target (a Bridge program's spender clone and "TS" handler), and returns the unused
input. Its checks are in the [card spend design](../cards/design.md#what-the-program-checks).

## Invariants

1. No owner, setters or rescue; the mode is fixed at deployment.
2. Callbacks accept only the canonical Zone Messenger, the router's Zone and that Zone's
   Factory-registered Portal.
3. Every successful callback returns its output through the source Portal, except what a listed
   settler uses, at most the callback's `maxInput`.
4. Conversion happens only at the pool oracle's exact par price with measured 1:1 output.
5. No balance stays with the router after a callback, and no allowance except a spend's standing
   approval to its own Zone's Portal.
6. The router never emits or stores `senderTag`.

## Not built yet

- **One shared router.** Once modes settle, each mode becomes an immutable route on one ownerless
  router, and each Zone's Portal admin approves the routes it accepts. `routeId` adds 32 bytes per
  callback (Spend becomes 896).
