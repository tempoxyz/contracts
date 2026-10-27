# Card E2E harness

Card scenarios are written once and run against every contract setup. Each setup ("rail") adapts
a small set of hooks, so a new design gets the whole suite by writing one adapter.

## What is real and what is modeled

| Layer                                    | In the harness                                                                                 | Real or modeled                |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------ |
| TIP-20, AccountKeychain, TIP-403, fees   | Tempo precompiles in Foundry (`hardfork = "tempo:T8"`)                                         | Real                           |
| Access-key transactions                  | Signed Tempo transactions via `vm.executeTransaction`                                          | Real                           |
| Tempo Earn                               | `EarnFactory`, `EarnVault`, native EarnShare, `ERC4626Engine` over a demo venue                | Real contracts, demo venue     |
| Bridge                                   | `SpenderFactory`, EA, P2 (with Uniswap Permit2), TF and the unmerged EV handler                | Real contracts                 |
| Zone, Tempo side                         | `ZonePortal`, `ZoneMessenger`, `Verifier` at canonical addresses, with the Zone factory mocked | Real contracts, mocked factory |
| Zone, Zone side                          | `ZoneEnv`: shadow TIP-20 balances, outbox, sequencer, encrypted deposits                       | Modeled                        |
| Stripe Issuing and Bridge's card backend | `CardProgram`                                                                                  | Modeled                        |

`e2e/spend` runs the private path on a real L1 and Zone, so it covers what the model cannot, such
as the Zone's ban on contract creation.

**The Zone model.** The Zone side runs in the same EVM. Zone balances are shadow TIP-20s, so the
real keychain enforces Zone key limits and scopes. `ZoneEnv` plays sequencer:

- it submits batches to the real portal and processes withdrawals, running real callbacks;
- it decrypts deposits and credits bounce-backs;
- its simulated outbox applies the real outbox's recipient policy.

Deposit payloads are XOR-encrypted with a per-deposit nonce, so Tempo data never carries the
recipient.

**The card program model.** `CardProgram` follows monorail's noncustodial just-in-time cards:

- An authorization pulls its hold first: the amount, a 20% buffer for restaurants, bars, taxis
  and car rentals, a $100 hold for a $1 fuel-pump preauthorization, plus any estimated fee.
- A capture above the hold pulls the difference.
- A final capture, reversal or expiry returns the unused hold. Holds expire after 7 days, or 31
  for lodging, airlines and rentals.
- Refunds and won disputes credit the cardholder from Bridge liquidity.
- A pull that fails after approval is paid by the platform reserve and becomes cardholder debt.

## Structure

```text
TempoEnv        tokens, Earn, Bridge factory with EA/P2/TF/EV/TS
  ZoneEnv       real portal and messenger, modeled Zone sequencer
    AccessKeys  keychain authorization and access-key transactions
      SpendRail       the hooks a setup implements
        CardProgram   Stripe Issuing and Bridge model, drives the hooks
          CardScenarios  every scenario
          RailDefaults   default hook bodies
            BridgeErc20Rail, BridgePermit2Rail, BridgeTewfRail, BridgeErc4626Rail
            TempoAccessKeyRail, TempoPrivateRail
```

`test/e2e/Matrix.t.sol` crosses scenarios with rails and funding, for example
`contract Tempo_Private_Earn is CardScenarios, TempoPrivateRail { ... }`.

## Hooks a rail implements

| Hook                                              | Meaning                                                              |
| ------------------------------------------------- | -------------------------------------------------------------------- |
| `_railName()`                                     | The setup's name in the matrix                                       |
| `_railCaps()`                                     | Capabilities, which decide how capability-dependent scenarios assert |
| `_railSetUp()`                                    | Deploy anything beyond the shared world                              |
| `_railEnroll(user, amount)`                       | Fund the funding source and link the card                            |
| `_railPull(user, amount, actionId)`               | Bridge pulls: `Settled`, `Rejected` or `FailedAfterApproval`         |
| `_railCredit(user, amount, actionId)`             | Bridge returns funds                                                 |
| `_railValue(user)`, `_railShares(user)`           | What the cardholder holds                                            |
| `_railSetSpendLimit`, `_railRevoke`, `_railDrain` | Cardholder controls and adversarial moves                            |
| `_railPullSplit`                                  | One pull from stablecoin and Earn (with `splitFunding`)              |
| `_railZoneKeyWithdrawTo`                          | Uses Bridge's Zone key as if leaked (private rails)                  |

## Extending it

- **A setup:** write `abstract contract MyRail is RailDefaults` in `test/rails/`, add one contract
  per funding source to `test/e2e/Matrix.t.sol` and to `SETUPS` in `script/matrix.py`, then run
  `forge test --match-contract MySetup -vv` and `python3 script/matrix.py`.
- **A scenario:** add a `test_` function to `CardScenarios` that drives `CardProgram` and asserts
  through `_railValue`, `_assertSpent`, `_assertSettled` and `_assertLedger`. If a setup lacks a
  capability, branch on `_railCaps()`, pin what the setup does, and call `_gap("reason")` so the
  matrix lists it. Use `vm.skip` only when the scenario cannot apply.

## Pitfalls

- `vm.prank` applies to the next external call, including calls made while evaluating arguments.
  Compute quotes and view results before the prank.
- With `via_ir`, `block.timestamp` read before `vm.warp` can be re-read after it. Use
  `vm.getBlockTimestamp()`.
- Tempo prices new storage far above Ethereum. Simulated transactions use a 29M gas limit, so
  gas numbers from the simulator say nothing about product contracts.
- Permit2 pins solc 0.8.17, so `TempoEnv` deploys it from creation code committed in
  `test/harness/fixtures/Permit2.json`, built once in `lib/permit2` with its own toolchain.
- The local hardfork predates TIP-403 policy bindings, so `ZoneEnv` mocks
  `tokenTransferPolicyId`, as the zones test suite does.
- The messenger replaces every callback revert with `CallbackRejected()`. `ZoneEnv` re-runs each
  callback in a snapshot to record the real reason in `lastCallbackErrors`, so a `vm.expectEmit`
  placed before `_zoneSettle()` matches the re-run. Test events by calling the router as the
  messenger instead.
