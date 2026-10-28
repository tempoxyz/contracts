# Zone router

[`ZoneRouter`](../../zone-router/src/ZoneRouter.sol) takes a Zone's withdrawal callbacks on Tempo: Earn
deposits and redemptions, and spends through settlers fixed at deployment.
[`ZoneRouterFactory`](../../zone-router/src/ZoneRouterFactory.sol) deploys it, and the
[settlers](#settlers) in [`src/settlers/`](../../zone-router/src/settlers/) pay a spend: `SendSettler`
to a public address, `BridgeSettler` through a Bridge card program. All live in the
[`zone-router/`](../../zone-router/README.md) Foundry project, built with solc, which imports only Earn's
interfaces. Card spend through it is in the [Bridge integration's design](../bridge/design.md).

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

| Mode                       | Ops                    | Settlers        | Vault |
| -------------------------- | ---------------------- | --------------- | ----- |
| Earn                       | Deposit, Redeem        | —               | Yes   |
| Card, closed loop          | Spend                  | `BridgeSettler` | —     |
| Card and Earn, closed loop | Deposit, Redeem, Spend | `BridgeSettler` | Yes   |

One router per Zone can serve several programs by listing each one's settler.

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
   immutable against the mode. When anyone, such as Bridge's deploy script, already deployed the mode
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
`settlers`, such as a release's `SendSettler` or a card program's `BridgeSettler`.

Outside a profile, the **Zone Router Release** workflow deploys and source-verifies a
`ZoneRouterFactory`, a `SendSettler`, a card program's `BridgeSettler`, or a mode's router from
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

A settler adapts one payee system to the Spend op. Each lives in
[`zone-router/src/settlers/`](../../zone-router/src/settlers/), has no owner, and keeps none of a
callback's input. A settler may carry a minimal interface for the external system it pays into,
never that system's code. A mode lists the settlers it allows, and only those can be named in a
callback.

| Settler         | Pays                                                           | `settlerData`       | Binding fixed at deployment              |
| --------------- | -------------------------------------------------------------- | ------------------- | ---------------------------------------- |
| `SendSettler`   | A public address, in the withdrawn token or redeemed from Earn | `abi.encode(Send)`  | Optional vault, par pool and customer ID |
| `BridgeSettler` | A Bridge card program's destination, through its clone         | `abi.encode(Spend)` | Bridge's factory and the program's ID    |

Both are released by [Zone Router Release](../deployment/deployment.md#zone-router-releases) at a
deterministic address and listed in a profile's `zoneRouter.settlers`.

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

### `BridgeSettler`

[`BridgeSettler`](../../zone-router/src/settlers/BridgeSettler.sol) settles a card spend through one
Bridge card program: one deployment per program (`SPENDER_ID`) of one Bridge `SpenderFactory`
(`FACTORY`), both fixed at deployment, so one program's approval can never pay through another's.
Its `settlerData` is `abi.encode(Spend)`, the struct Bridge's "TS" handler
(`SpenderTempoSpend`, in [`bridge/`](../../bridge/README.md)) settles for public spend too.
[`settlers/bridge/IBridgeSpender.sol`](../../zone-router/src/settlers/bridge/IBridgeSpender.sol) holds
that struct, its only definition, and the two Bridge calls the settler makes: the factory's
`getSpenderAddress` and the clone's `publicCall`. A `settle`:

1. requires the `Spend` to be for its program (`WrongProgram`) and `0 < maxInput <= type(uint128).max`
   (`InvalidAmount`);
2. requires the input to be the spend's token, or, when the vault funds all of it
   (`fromVault == amount`), that vault's EarnShare (`WrongInputToken`); a spend split between both
   cannot come from one withdrawal;
3. requires the `maxInput` the router sent (`InsufficientInput`), makes sure its standing approval
   to the program's clone covers it, and calls `publicCall("TS" "PS" abi.encode(spend))`, so the
   handler sees the settler as the payer;
4. requires the handler to have used some input and no more than it was given (`NothingSettled`),
   and the destination's balance of `Spend.token` to have risen by exactly `amount`
   (`DestinationNotPaid`), so a replaced handler cannot look settled;
5. hands the unused input back to the router and requires its own balance to be what it held before
   the router's input arrived (`ResidualBalance`).

It emits `SpendSettled(ref, inputToken, inputConsumed, inputReturned)`, with no cardholder address or
`senderTag`. Its approval to the clone stays at the maximum for the same reason as the router's to
the Portal; between spends the settler holds nothing the clone could take, and the router's
`maxInput` transfer still bounds what a spend can use. `warm(token)` sets it ahead of the first spend.
Tokens sent to it outside a `settle` call are not rescued: a later `settle` caller can
spend them, only to a destination the program authorizes, and gets back what the spend did not use.
Deploy one per program with the [Zone Router Release `bridgeSettler`](../deployment/deployment.md#zone-router-releases),
after Bridge has created the program, and list it in the card mode's `settlers`. The flows, Bridge's
governance and the decisions behind it are in the [Bridge integration's design](../bridge/design.md).

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
