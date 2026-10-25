# Contract reference

This page lists the core contracts' public surface: constructor and deployment inputs, reads,
entrypoints with their authority, events, and the errors that enforce core rules. Semantics are
owned by [system architecture](../architecture/system.md) and [Earn fees](../architecture/fees.md),
ordering by [flows](../architecture/flows.md), and trust assumptions by
[security and privacy](../architecture/security-and-privacy.md). TypeScript consumers import the
ABIs from `@tempoxyz/earn/abis` ([deployments README](../../deployments/README.md#exports)). Audit
scope and later changes are in [audits](../audit/README.md#coverage-after-the-audits).

## Deployment inventory

| Contract      | Scope     | Stateful                  | Owner or authority                                          | Responsibility                                                           |
| ------------- | --------- | ------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------ |
| `EarnFactory` | Network   | No mutable business state | Ownerless                                                   | Atomic deterministic core creation, transfer policy, and event           |
| EarnShare     | Per stack | Yes                       | No administrator; EarnVault is the sole issuer              | Non-rebasing user ownership                                              |
| `EarnVault`   | Per stack | Yes                       | Two-step operator; guardian, janitor, and distributor seats | Issuance, anchors, engine coordination, async claims, migration          |
| `EarnFees`    | Per stack | Yes                       | Ownerless; mutable only by its EarnVault                    | Fee state, calculations, snapshots, claim ledgers, fee EarnShare custody |

| Capability contracts                                          | Scope              | Reference                                                  |
| ------------------------------------------------------------- | ------------------ | ---------------------------------------------------------- |
| Current engine and the `IEarnEngine` capability interfaces    | Per stack          | [Yield engines](../integrations/engines.md)                |
| `ERC4626Engine`, `ERC4626EngineFactory`                       | Per stack, network | [ERC-4626](../modules/erc4626-engine.md)                   |
| `VedaEngine`, `VedaPeripheryRegistry`, `VedaForwardingSolver` | Per Veda stack     | [Veda](../modules/veda.md#contracts)                       |
| `PropAMMEngine` (experimental)                                | Per stack          | [PropAMM](../modules/propamm.md)                           |
| `SingleZoneEarnRouter`                                        | Per Zone route     | [Zones](../modules/zone-router.md#router-contract)         |
| `EarnContributionController`, `EarnMerkleRewardDistributor`   | Optional per stack | [Rewards](../modules/rewards.md)                           |
| `EarnRewardsFactory`                                          | Network            | [Rewards installation](../modules/rewards.md#installation) |

## EarnFactory

[`EarnFactory`](../../src/core/EarnFactory.sol) is constructed with the canonical `ITIP20Factory`,
one locked `EarnVault` implementation, and one locked `EarnFees` implementation, all immutable.

`deploy(DeployParams)` accepts:

| Field               | Meaning                                                                        |
| ------------------- | ------------------------------------------------------------------------------ |
| `deploymentId`      | Nonzero logical stack namespace                                                |
| `engine`            | Already-deployed, unbound initial engine                                       |
| `owner`             | EarnVault operator; cannot be the factory                                      |
| `controls`          | Guardian, async janitor, managed-assets limit, and fixed migration mode        |
| `distributorConfig` | Optional distributor and its fixed fee-update delay                            |
| `fees`              | Initial complete fee configuration                                             |
| `transferPolicyId`  | Optional existing simple TIP-403 whitelist; zero means always-allow policy `1` |

A zero distributor requires a zero delay and a nonzero distributor a nonzero delay. With a
distributor, `fees.fixedFees[0]` becomes its protected item, or the item starts at zero when `fees`
has no fixed fees.

The EarnShare salt hashes `deploymentId`, engine, owner, controls, distributor and fee
configuration, and effective policy ID, so only an identical configuration can take a predicted
address. `deploy` returns `(earnShare, earnVault, earnFees)` after:

1. validating the parameters and rejecting an engine without code or already bound to an EarnVault;
2. requiring a nonzero engine asset and nonempty engine name and symbol;
3. validating that a nonzero policy is an existing simple whitelist;
4. creating EarnShare through the TIP-20 factory at the predicted address, named
   `"<engine name> (Earn)"`, symbol `"<engine symbol>E"`, with an empty currency;
5. creating the EarnVault ERC-1967 proxy and the deterministic `EarnFees` clone;
6. initializing `EarnFees`, then the EarnVault, which requires the engine's base interface and an
   exit capability and an EarnShare with zero supply;
7. granting the EarnVault the issuer role;
8. attaching the transfer policy;
9. revoking the factory's administrator role without a replacement; and
10. emitting `EarnStackDeployed`.

`computeEarnShareSalt`, `predictEarnShare`, and `predictEarnFees` support deployment planning. The
factory does not deploy the engine, router, Veda solver, or reward periphery. The engine's setup
owner then binds it with `initializeEarnVault`
([engine contract](../integrations/engines.md#engine-contract)); deployment inspection rejects a
different or missing binding or an unexpected engine owner.

## EarnVault

[`EarnVault`](../../src/core/EarnVault.sol) is the persistent public integration point. Its
`initialize` runs once, from the factory, and emits `EarnVaultInitialized` with the engine,
EarnShare, fee module, operator, emergency seats, asset limit, migration mode, distributor, update
delay, and distributor fee. The factory's later `EarnStackDeployed` is the signal that issuer and
transfer-policy setup completed.

### Core state

| Read                                          | Meaning                                                                 |
| --------------------------------------------- | ----------------------------------------------------------------------- |
| `asset()`                                     | Immutable base asset, read from the initial engine                      |
| `earnShare()` / `earnFees()`                  | Paired EarnShare and fee module                                         |
| `engine()`                                    | Current engine; changes only through `migrateEngine`                    |
| `operator()` / `pendingOperator()`            | Operator and nominated successor                                        |
| `emergencyGuardian()` / `asyncJanitor()`      | Emergency seats; zero when empty                                        |
| `engineMigrationMode()`                       | Fixed `UserOnly` or `OperatorEnabled`                                   |
| `anchorEngineShares()` / `anchorEarnShares()` | Stored conversion anchor                                                |
| `engineShares()`                              | Managed engine shares backing active EarnShare, capped at raw custody   |
| `rawEngineShares()`                           | Raw current-engine custody, including surplus                           |
| `surplusEngineShares()`                       | Raw shares not recognized as managed backing                            |
| `totalAssets()`                               | Value of managed backing; surplus excluded                              |
| `totalEarnShares()`                           | EarnShare total supply                                                  |
| `isAccountingAligned()`                       | Whether supply converts exactly to managed engine shares                |
| `isFeeValuationFresh()`                       | Engine's fee-valuation freshness; `true` without the capability         |
| `normalizedRewardRate()`                      | Managed engine shares per whole EarnShare, after pending fee dilution   |
| `rewardRateBaseline()`                        | Rate at the last empty reset or migration                               |
| `MAX_REWARD_RATE_MULTIPLIER()`                | Fixed reward-admission ceiling: `100`                                   |
| `openRedeemRequestCount()`                    | Number of open async claims                                             |
| `pendingRedeem(requestId)`                    | Stored receiver, requester, burned EarnShare, engine shares, and `open` |
| `depositsPaused()`                            | New-exposure pause state                                                |
| `maxManagedAssets()`                          | Managed-assets ceiling; zero means unlimited                            |
| `remainingDepositCapacity()`                  | Room under the ceiling; `type(uint256).max` when unlimited              |

### User and accounting API

| Function                                                   | Behavior                                                          |
| ---------------------------------------------------------- | ----------------------------------------------------------------- |
| `deposit(assets, receiver, minEarnShares)`                 | Deposit base assets and mint bounded EarnShare                    |
| `depositVenueShares(venueShares, receiver, minEarnShares)` | Enter with current venue shares through the in-kind capability    |
| `redeem(earnShares, receiver, minAssets)`                  | Burn EarnShare and immediately redeem bounded assets              |
| `withdrawExact(assets, receiver, maxEarnShares)`           | Pay exact assets and burn no more than the cap                    |
| `contribute(assets)`                                       | Permissionlessly add backing without funder EarnShare             |
| `absorbEngineShareSurplus(engineShares)`                   | Permissionlessly recognize surplus as a reward                    |
| `requestRedeem(earnShares, receiver, engineData)`          | Bound floor loss, burn, and open a separate claim                 |
| `requestRedeem(earnShares, engineData, receiver)`          | The same operation with `engineData` before `receiver`            |
| `cancelRedeem(requestId, minReceiverEarnShares)`           | Requester or janitor returns bounded queued value to the receiver |
| `finalizeRedeem(requestId, asset, amount)`                 | Current engine only; forward a solved payout and close the claim  |
| `previewRedeem(earnShares)`                                | Quote assets after pending fee dilution                           |
| `previewWithdraw(assets)`                                  | Quote required EarnShare, rounded up, after pending fee dilution  |
| `convertToEngineShares(earnShares)`                        | Convert at the stored anchor, rounding down                       |
| `convertEngineSharesToEarnShares(engineShares)`            | Convert at the stored anchor, rounding down                       |

The five receiver-selecting entry and exit functions also have self-recipient overloads under
distinct selectors, for [scoped access keys](../integrations/client.md#delegated-self-recipient-calls):

| Function                                         | Receiver                                                        |
| ------------------------------------------------ | --------------------------------------------------------------- |
| `deposit(assets, minEarnShares)`                 | Caller receives EarnShare                                       |
| `depositVenueShares(venueShares, minEarnShares)` | Caller receives EarnShare                                       |
| `redeem(earnShares, minAssets)`                  | Caller receives assets                                          |
| `withdrawExact(assets, maxEarnShares)`           | Caller receives assets                                          |
| `requestRedeem(earnShares, engineData)`          | Caller is the stored receiver for finalization and cancellation |

They behave exactly like the explicit-receiver variants with `receiver = msg.sender`. A contract
receiver of an async claim may implement
[`IAsyncRedeemReceiver`](../../src/interfaces/core/IAsyncRedeemReceiver.sol); the EarnVault calls
`onRedeemFinalized` or `onRedeemCancelled` after paying it and ignores a revert.

### Fee and role entrypoints

| Function                                           | Authority                | Behavior                                                             |
| -------------------------------------------------- | ------------------------ | -------------------------------------------------------------------- |
| `accrueFees()`                                     | Anyone                   | Checkpoint the module and mint its calculated fee EarnShare          |
| `setFeeConfig(config)`                             | Operator                 | Keep the protected item, require fresh valuation, settle, install    |
| `disableFees()`                                    | Operator, no distributor | Disable all fees without valuation                                   |
| `transferOperator(newOperator)`                    | Operator                 | Nominate a nonzero successor                                         |
| `cancelOperatorTransfer()`                         | Operator                 | Cancel the pending handoff                                           |
| `acceptOperator()`                                 | Pending operator         | Accept the role                                                      |
| `scheduleDistributorFeeUpdate(recipient, rateBps)` | Distributor              | Schedule its protected item after the fixed delay                    |
| `cancelDistributorFeeUpdate()`                     | Distributor              | Cancel its pending update                                            |
| `executeDistributorFeeUpdate()`                    | Anyone, once ready       | Require fresh valuation, settle old terms, activate the pending item |
| `transferDistributor(newDistributor)`              | Distributor              | Nominate a nonzero successor other than itself                       |
| `cancelDistributorTransfer()`                      | Distributor              | Cancel the pending handoff                                           |
| `acceptDistributor()`                              | Pending distributor      | Accept the role and cancel the previous distributor's pending update |

`distributor()`, `pendingDistributor()`, `distributorFee()`, `distributorUpdateDelay()`, and
`pendingDistributorFeeUpdate()` read the distributor state. Recipient claim reads are on `EarnFees`.

### Controls

| Function                                                          | Authority                              |
| ----------------------------------------------------------------- | -------------------------------------- |
| `setDepositsPaused(paused)`                                       | Operator; guardian may only set `true` |
| `setMaxManagedAssets(newMaxManagedAssets)`                        | Operator                               |
| `setEmergencyRoles(newGuardian, newJanitor)`                      | Operator; zero empties a seat          |
| `migrateEngine(newEngine, minNewEngineShares, minAssetsRetained)` | Operator, only in `OperatorEnabled`    |

`setDepositsPaused` checks authorization first, then does nothing and emits no event when the value
already matches. The managed-assets limit and reward-admission limit are specified under
[accounting anchors](../architecture/system.md#accounting-anchors); migration preconditions and
bounds under [whole-pool engine migration](../modules/migration.md#whole-pool-engine-migration).

### Events

| Event                                                                                     | Emitted when                                                   |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `Deposited`, `VenueSharesDeposited`                                                       | A base-asset or in-kind entry mints EarnShare                  |
| `Redeemed`, `WithdrewExact`                                                               | An immediate exit pays its receiver                            |
| `Contributed`, `EngineShareSurplusAbsorbed`                                               | A reward is recognized, with the new anchor                    |
| `EngineShareShortfallReconciled`                                                          | Raw custody fell below the managed count and the count was cut |
| `RedeemRequested`, `RedeemFinalized`, `RedeemCancelled`                                   | An async claim opens or closes                                 |
| `EngineMigrated`                                                                          | Migration completes, with moved assets and the new anchor      |
| `DepositPauseChanged`, `MaxManagedAssetsChanged`, `EmergencyRolesChanged`                 | A control changes                                              |
| `OperatorTransferStarted`, `OperatorTransferCancelled`, `OperatorTransferred`             | The operator handoff progresses                                |
| `DistributorFeeUpdateScheduled`, `DistributorFeeUpdateCancelled`, `DistributorFeeUpdated` | A distributor fee update progresses                            |
| `DistributorTransferStarted`, `DistributorTransferCancelled`, `DistributorTransferred`    | The distributor handoff progresses                             |

### Errors that enforce core rules

| Error                                                                                                 | Rule                                                                                         |
| ----------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `DepositsPaused`                                                                                      | Pause blocks deposits, in-kind entry, contributions, and absorption                          |
| `ActiveSupplyWithoutBacking`                                                                          | No principal entry into a pool whose supply has zero-value backing                           |
| `ExcessiveConversionLoss`                                                                             | Entry, request, or nonempty-pool re-entry loses more than 1 bp to rounding                   |
| `MaxManagedAssetsExceeded`                                                                            | A voluntary inflow would exceed the managed-assets limit                                     |
| `RewardRateLimitExceeded`                                                                             | A reward would exceed 100× the reward-rate baseline                                          |
| `NoEarnShares`, `InsufficientEngineShareSurplus`                                                      | A reward needs holders and enough surplus                                                    |
| `InsufficientOutput`                                                                                  | A conversion or measured delta is zero, or a measured delta differs from the reported amount |
| `ResidualBacking`                                                                                     | An exact withdrawal or migration would strand backing                                        |
| `MinimumEarnSharesNotMet`, `MinimumAssetsNotMet`, `MinimumEngineSharesNotMet`, `ExceedsMaxEarnShares` | A caller bound is missed                                                                     |
| `EngineCapabilityUnsupported`, `EngineExitUnsupported`                                                | The engine lacks the called capability, or any exit capability                               |
| `PendingRedeemsOpen`, `OperatorMigrationDisabled`, `ExcessiveMigrationClassificationError`            | Migration preconditions and the 1-bp managed/surplus split                                   |
| `FeeValuationStale`                                                                                   | A fee configuration change needs a fresh valuation                                           |
| `GlobalFeeDisableUnavailable`, `InvalidDistributorFeeConfiguration`                                   | The distributor item is protected                                                            |

The complete list is in the source; client handling is in
[decode reverts](../integrations/client.md#decode-reverts).

## EarnFees

[`EarnFees`](../../src/core/EarnFees.sol) is an ownerless deterministic clone initialized once with
one EarnVault, one EarnShare, and the initial configuration (ID `1`). `earnVault()` is the only
caller allowed to mutate fee state, `earnShare()` is the only token it holds for claims, and there is
no owner, issuer authority, rescue method, or configuration bypass.

### Public reads

| Read                                 | Meaning                                                       |
| ------------------------------------ | ------------------------------------------------------------- |
| `currentFeeConfigId()`               | Active configuration ID                                       |
| `feeConfig(configId)`                | Fixed and excess terms of any installed configuration         |
| `validateFeeConfig(config)`          | Revert unless a complete configuration is structurally valid  |
| `feesActive()` / `feesDisabled()`    | Whether fees are charging, and whether they are disabled      |
| `feeBaselinesPending()`              | A stale empty-pool cancellation awaits fresh baselines        |
| `highWaterMark()`                    | Post-fee value per EarnShare                                  |
| `targetBase()` / `targetStartedAt()` | Excess-return target base and its start time                  |
| `feeRemainder(configId, slot)`       | Carried sub-unit remainder; slots 0–3 fixed, 4 excess         |
| `previewAccruedFees()`               | Current `FeePreview`, including per-recipient allocations     |
| `pendingFeeSnapshot(requestId)`      | An async request's fee snapshot                               |
| `shouldChargeRedeem(requestId)`      | Whether cancelling that request now would charge its snapshot |
| `claimableEarnShares(recipient)`     | Recipient ledger                                              |
| `totalClaimableEarnShares()`         | Aggregate fee EarnShare liability                             |

### Claims

`claim(to, earnShares)` transfers only from the caller's own ledger. `to` cannot be zero, the
module, or the EarnVault.

### EarnVault-only API

`accrueFees`, `setFeeConfig`, `disableFees`, `initializeBaselines`, `recordRedeemRequest`,
`closeRedeemRequest`, and `settleCancelledRedeem` mutate the fee state machine. The EarnVault
supplies the accounting context and separately mints any fee EarnShare they return.
`initializeBaselines` runs after a principal deposit and only raises baselines.

### Events

`FeesAccrued`, `FeeEarnSharesAllocated`, `FeeEarnSharesClaimed`, `FeeConfigurationSet` (with the
configuration hash and whether it re-enabled fees), `FeeDustWaived`, `FeesDisabled`, and
`FeeBaselinesInitialized`.

Fee types are in [`EarnFeeTypes.sol`](../../src/interfaces/core/EarnFeeTypes.sol) and the pure
waterfall in [`EarnFeeMath.sol`](../../src/core/EarnFeeMath.sol).
