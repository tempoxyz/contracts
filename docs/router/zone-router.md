# Zone router

[`ZoneRouter`](../../router/src/ZoneRouter.sol) takes a Zone's withdrawal callbacks on Tempo: Earn
deposits and redemptions, and spends through settlers fixed at deployment.
[`ZoneRouterFactory`](../../router/src/ZoneRouterFactory.sol) deploys it. Both live in the
[`router/`](../../router/README.md) Foundry project, built with solc, which imports only Earn's
interfaces. Card spend through it is in [Spend's design](../spend/design.md).

`SingleZoneEarnRouter` ([Earn's zone router](../earn/modules/zone-router.md)) is the router Earn runs in
production today. `ZoneRouter`'s Earn ops accept its callback data byte for byte and report the same
views, so Earn clients can move to it.

## Modes

A router has no owner and no setters. Its mode is fixed at deployment; a different mode is a new
router.

- **`enabledOps`**, a bitmask of Deposit, Redeem and Spend. A disabled op reverts `OpDisabled`.
- **`settlers`**, the `ISpendSettler` contracts Spend may use, written once by the constructor.
  Required when Spend is enabled, empty otherwise.
- **`earnVault`, `privateAsset`, `pool`, `customerId`**, as `SingleZoneEarnRouter` binds them.
  Required when Deposit or Redeem is enabled, and all zero otherwise.

The constructor rejects inconsistent combinations. Profiles name presets:

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
- **Size.** The router's runtime is 9.9 KB and the factory's 13.2 KB, under the 24 KB limit.

Nobody can change a deployed router. Enabling a settler or op means deploying a new router through
the factory and having the Zone's Portal admin admit it as a gateway; the old router stays deployed
so callbacks already on their way finish or bounce. The only authority is the one Zones already
have: which gateways they admit.

## Ops

The router reads the first callback word before decoding, so ops 0 and 1 keep
`SingleZoneEarnRouter`'s layout and `viem/tempo`'s `earnRouterCallbackData` works unchanged.

| Op        | Input                               | What the router does                                                   | Back to the Zone |
| --------- | ----------------------------------- | ---------------------------------------------------------------------- | ---------------- |
| 0 Deposit | Private asset                       | As `SingleZoneEarnRouter`                                              | EarnShare        |
| 1 Redeem  | EarnShare                           | As `SingleZoneEarnRouter`                                              | Private asset    |
| 2 Spend   | Any token the source Portal enables | Approves at most `maxInput` to a listed settler, measures what it used | Unused input     |

Every return to the source Zone is an encrypted deposit, with a refund recipient, of a token enabled
with deposits active. Ops 0 and 1 use `SingleZoneEarnRouter`'s `ZoneReturn`; Spend's `SpendReturn`
adds `maxDepositFee` and reverts if the Portal's deposit fee is above it. Any revert bounces the whole
input to the withdrawal's fallback recipient in the Zone.

### Spend

Callback data: `op`, `settler`, `maxInput`, `settlerData` and `SpendReturn`, 864 of the outbox's
1,024 bytes with a 64-byte ciphertext. A Spend callback:

1. authenticates as ops 0 and 1, and requires the settler to be listed;
2. requires `0 < maxInput <= amount`, approves `maxInput` to the settler, calls
   `settle(token, maxInput, settlerData)`, and resets the approval;
3. requires `0 < used <= maxInput`, measured from its own balance;
4. returns `amount - used` to the source Zone;
5. emits `Spent(settler, token, used, change, zoneDepositHash)`, with no `senderTag`, action ID or
   Zone account. The settler emits its own detail.

`maxInput` is set in the sender's Zone transaction, not by the settler, so no settler can take more
than the sender allowed, and the change always returns. The router accepts any enabled token and
leaves it to the settler to refuse one it cannot use.

### `ISpendSettler`

```text
interface ISpendSettler {
    // Pays from the router's approved token, using at most maxInput. Reverts unless the
    // payment it makes is complete. Returns all unused input to the router.
    function settle(address token, uint256 maxInput, bytes calldata data) external;
}
```

[`BridgeSettler`](../../spend/src/settler/BridgeSettler.sol) is the card program's settler.

## Invariants

1. No owner, setters or rescue; the mode is fixed at deployment.
2. Callbacks accept only the canonical Zone Messenger, the router's Zone and that Zone's
   Factory-registered Portal.
3. Every successful callback returns its output through the source Portal, except what a listed
   settler uses, at most the callback's `maxInput`.
4. Conversion happens only at the pool oracle's exact par price with measured 1:1 output.
5. No balance or allowance stays with the router after a callback.
6. The router never emits or stores `senderTag`.

## Not built yet

- **`SendSettler`.** A Tempo-owned settler in `router/` that pays a public address in EarnShare, in
  stablecoin, or in stablecoin redeemed from EarnShare through the Earn vault's `withdrawExact` and
  par conversion. A router allows sends only if it lists it; closed-loop routers do not.
- **One shared router.** Once modes settle, each mode becomes an immutable route on one ownerless
  router, and each Zone's Portal admin approves the routes it accepts. `routeId` adds 32 bytes per
  callback (Spend becomes 896).
