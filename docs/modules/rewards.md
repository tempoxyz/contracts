# Rewards

This page owns the `rewards` module: `EarnContributionController`, `EarnMerkleRewardDistributor`,
`EarnRewardsFactory`, their trust boundaries, deployment, and tests. Tempo API, Tempo's offchain
service outside this repository, owns campaign configuration, eligibility, rate observations,
calculations, Merkle statements, transaction coordination, proofs, monitoring, and operator
signing. This repository holds the contracts, their deployment steps, and the reward-configuration
schema Tempo API shares ([`schema.ts`](../../deployments/modules/rewards/schema.ts)); it has no
offchain scheduler, signer, or policy calculation.

There are two reward mechanisms, each with an optional contract:

- **Exchange-rate contributions.** `EarnVault.contribute` adds base assets to backing without
  minting EarnShare to the funder, so every outstanding EarnShare becomes more valuable.
  `EarnContributionController` optionally orchestrates owner-triggered, supply-bounded funding.
- **EarnShare Merkle settlement.** `EarnMerkleRewardDistributor` holds EarnShare and pays cumulative,
  recipient-specific entitlements through published roots, permissionless multiproof pushes, and
  permissionless claims.

Neither contract has EarnShare issuer, EarnVault or EarnFees configuration, engine, router, or
policy-administrator authority. The core `contribute` sequence is in
[flows](../architecture/flows.md#contribution) and fee treatment in [fees](../architecture/fees.md).
Audit coverage is in [audits](../audit/README.md#scope).

## Exchange-rate contributions

Contributed assets follow the engine deposit path of user capital. Existing active holders receive
the increase net of positive-accrual fees, and because the venue mints new shares to the engine,
unrelated direct venue holders do not benefit.

`contribute` is permissionless and bounded by the caller's allowance. EarnVault stores no provider
list, funding policy, or rewarder allowlist. A contribution requires nonzero active EarnShare supply
and may proceed while async exits are open; queued claims have already left active NAV, so only the
active pool benefits.

**Why exchange-rate rewards:** every existing EarnShare becomes more valuable without a second
balance, Merkle allocation, claim flow, Zone reward integration, or per-user data disclosure.
Funding policy stays offchain and best-effort.

**Reward-rate admission limit.** After fees, an explicit reward addition may not raise the normalized
managed engine-share/EarnShare rate above a fixed 100× multiple of the current baseline (about 68
years at 7% annual compounding). Over-limit contributions revert while deposits and exits continue,
and organic venue yield is never blocked. Venue shares sent directly to the engine stay quarantined
until `absorbEngineShareSurplus(engineShares)` passes the same check. The exact rule is under
[accounting anchors](../architecture/system.md#accounting-anchors).

**Eligibility.** Reward eligibility is the live EarnShare supply. On a protected deployment the
[access policy](access.md) keeps ineligible accounts from acquiring EarnShare; TIP-403 membership is
not Merkle reward registration.

### Optional controller

[`EarnContributionController`](../../src/rewards/EarnContributionController.sol) is immutable to one
EarnVault and its base asset and uses `Ownable2Step` ownership.

| Function                                                       | Authority             | Behavior                                                   |
| -------------------------------------------------------------- | --------------------- | ---------------------------------------------------------- |
| `fund(funder, requestedAssets, maxEarnShareSupply)`            | Owner                 | Best-effort pull and contribution; a failed leg funds zero |
| `fundBatchExact(funders, requestedAssets, maxEarnShareSupply)` | Owner                 | All-or-nothing contribution from two or more funders       |
| `executeFunding(...)`                                          | The controller itself | `fund`'s isolated leg                                      |
| `setActive(active)`                                            | Owner                 | Stops or resumes funding                                   |
| `transferOwnership` / `acceptOwnership`                        | Owner / pending owner | Two-step ownership                                         |

The funder keeps custody and approves the controller; there is no escrow or guaranteed-funding
layer, because rewards are additive and contractually operated. Each funding call first checkpoints
pending fees and requires the fee-inclusive EarnShare supply to be nonzero and at most
`maxEarnShareSupply`, then pulls the requested amount and calls `contribute`. A supply above the
bound means a just-in-time deposit or fee crystallization would dilute the contribution; a lower
supply remains eligible. In `fund`, any failure of the checkpoint, supply check, transfer, or
contribution rolls the leg back and records zero, so operators must confirm the mined `Funded`
event and set a reviewed gas limit, or estimation may choose the cheaper caught-failure path.

For two or more providers, Tempo API submits one ordered `fundBatchExact` call that checks the supply
bound once and settles every amount atomically; one failed or underfunded leg reverts the batch and
never charges another wallet for its shortfall. The controller cannot mint, change EarnVault
configuration, or withdraw backing, has no withdrawal or rescue path, retains no assets or approval
after a call, and can be paused, replaced, or omitted without affecting ordinary Earn behavior.
Providers can always call `EarnVault.contribute` directly.

## Merkle distributor

[`EarnMerkleRewardDistributor`](../../src/rewards/EarnMerkleRewardDistributor.sol) is immutable to
one EarnVault, its base asset and EarnShare, a treasury, a nonzero campaign ID, and a future claim
deadline. It pays only EarnShare. Leaves are cumulative and domain-separated by chain, distributor,
campaign, recipient, and cumulative amount:

```text
keccak256(keccak256(abi.encode(chainId, distributor, campaignId, recipient, cumulativeEarnShares)))
```

| Function                                                                                              | Authority             | Behavior                                                                                                              |
| ----------------------------------------------------------------------------------------------------- | --------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `fundAndPublishRoot(settlementId, expectedVersion, funder, assets, minEarnShares, root, total, hash)` | Owner                 | Consume a settlement ID, compare-and-set the root version, deposit with a mint floor, and publish a fully funded root |
| `publishRoot(expectedVersion, root, total, statementHash)`                                            | Owner                 | Compare-and-set a fully funded cumulative root and its reconciliation hash                                            |
| `claim(recipient, cumulativeAmount, proof)`                                                           | Anyone                | Pay the recipient's newly owed cumulative difference                                                                  |
| `pushBatch(version, recipients, amounts, multiproof, flags)`                                          | Anyone                | Verify the whole batch, then push each cumulative delta, skipping failed transfers                                    |
| `setPaused(paused)`                                                                                   | Owner                 | Stop or resume funding, pushes, and claims; while paused, a new root may only restate the same total                  |
| `returnUnspent()`                                                                                     | Anyone after deadline | Send the remaining EarnShare to the immutable treasury                                                                |
| `transferOwnership` / `acceptOwnership`                                                               | Owner / pending owner | Two-step ownership; renunciation is disabled                                                                          |

Each interval starts from a cumulative statement computed by Tempo API. When the distributor's
unreserved EarnShare covers the new liability, the owner calls `publishRoot`; otherwise
`fundAndPublishRoot` deposits the shortfall through the EarnVault (a measured mint of at least
`minEarnShares`) and publishes in the same call. Payouts follow as `pushBatch` calls.

Root totals cannot decrease, and each root must be covered by the distributor's EarnShare balance for
its total less everything already paid. The check is aggregate, so a corrective root that lowers an
already-paid recipient's cumulative amount can leave other recipients' unpaid entitlement uncovered;
the trusted publisher keeps corrections cumulative. The settlement ID (content-addressed by Tempo API) must be nonzero and
unused, and the expected root version is checked before any asset moves, so funding and publication
succeed or revert together and a retry cannot pull twice or replace an unexpected root.

Funding pulls from an explicit funder within its balance and allowance, approves the EarnVault for
exactly that amount, deposits, clears the approval, checks that the distributor's base-asset balance
did not grow, and measures the EarnShare minted. Do not send base assets directly to the
distributor: it has no base-asset rescue, and `returnUnspent` moves only EarnShare.

`pushBatch` verifies the complete multiproof before any transfer and pays only each recipient's
cumulative delta. A failed transfer is skipped (`PayoutSkipped`) without consuming the entitlement
or blocking others; `claim` always pays the committed recipient. `PausedSet` is emitted only on an
actual state change. Disabled renunciation keeps a live campaign from abandoning its funding and
corrective-root authority.

The deadline is terminal: root publication and every payout path stop, unpaid entitlements become
permanently unpayable, and remaining EarnShare can go only to the treasury. Resolve deferred
recipients before it passes.

The root publisher is trusted for allocation correctness within the funded budget. The statement
hash and public events support independent reconstruction but do not make attribution trustless;
Tempo API's registration, eligibility, attribution, data sources, transaction recovery, and incident
handling are trusted inputs outside this repository. Public logs cannot attribute encrypted Zone
users.

When target-yield and boost rewards settle together, the onchain shape is one `fundBatchExact`
transaction, one Merkle root transaction, and the payout batches. They stay separate because the
target-yield contribution changes the exchange rate that denominates the boost statement.

## Invariants

1. A controller supply bound includes pending pre-contribution fee EarnShare.
2. Merkle roots are cumulative, versioned, and domain-separated, and each is funded for its total
   less everything already paid; pushes and claims pay only recipient deltas and cannot redirect
   funds.

## Installation

Reward periphery is installed in one of two ways; in both, leaves stay domain-bound to the
distributor address.

**With a new profile stack.** A [profile](../../profiles/README.md#rewards) may include
`targetYield` (deploys the controller) and `boostRewards` (deploys the distributor). The lifecycle
runs `deploy-merkle-distributor` after `deploy-router` and `deploy-contribution-controller` after
`validate-access` ([step order](../operations/deployment.md#authority-boundaries)), both as the
deployer through `script/deploy/DeployEarnMerkleRewardDistributor.s.sol` and
`script/deploy/DeployEarnContributionController.s.sol`. Both contracts are owned directly by the
profile `owner`. The distributor's treasury is `boostRewards.treasury`, its campaign ID derives from
the chain ID, profile ID, and version, and its claim deadline is 30 days after
`boostRewards.endTimestamp`. A protected EarnShare must whitelist the distributor and its treasury
([required members](access.md#required-members)), and the treasury is a privileged role the public
fixture-key guard checks. Each component is its own intent component, so a constructor change
replaces only that contract. The lifecycle never deploys or configures the offchain service.

**For an existing EarnVault.** [`EarnRewardsFactory`](../../src/rewards/EarnRewardsFactory.sol) is
ownerless and permissionless. `install(earnVault, owner, treasury, claimDeadline, targetYield,
boostRewards)` deploys either or both components with `CREATE2`, assigns `owner` directly, and keeps
no authority. A boost installation requires a nonzero treasury and a future deadline; a
target-yield-only installation requires both to be zero. The controller address depends on the vault
and owner, and the distributor's on the vault, owner, treasury, and deadline, with the zero-padded
EarnVault address as its campaign ID. `predictContributionController` and `predictMerkleDistributor`
expose both, and repeating an exact installation returns the existing contracts after checking their
bindings and owner. Different inputs can produce several distributors for the same EarnVault, and
the factory grants none of them canonical status: Tempo API's verified vault configuration selects
the instances it operates, and clients must not discover authority by enumerating factory
deployments.

### Rewards factory releases

Tempo API installs reward periphery through the rewards factory and pins each hosted network's
release itself; profiles never use it.

To release one, deploy from a reviewed `main` checkout through the `earnRewardsFactory(uint256)`
entry point of `script/deploy/DeployFactoryRelease.s.sol` (plain `CREATE`, run like the other
[shared factory releases](../operations/deployment.md#shared-factory-releases)), source-verify it,
and require its onchain runtime-code hash to match the local `deployedBytecode` hash with the
verifier reporting `exact_match`. Then configure its address and onchain runtime-code hash in Tempo
API; compiler metadata differs between source revisions, so chains need not share one hash.

## Failure modes and limitations

- Controller `fund` reverts `Inactive` while paused, and otherwise records zero for a failed leg,
  including `EarnShareSupplyOutOfBounds`; `fundBatchExact` reverts on any failure.
- The distributor reverts `Paused`, `ClaimsExpired`, `StaleRootVersion`,
  `SettlementAlreadyConsumed`, `InsufficientFunding`, `RootTotalDecreased`, or
  `PausedLiabilityIncrease` rather than publishing an unsafe root.
- Contributions benefit whoever holds active EarnShare when they are recognized; there is no
  time-weighted or per-user attribution, and direct permissionless contributions have no supply
  bound.
- Contributions are feeable positive accrual and do not insure losses unless policy funds them.
- Venue fees, caps, liquidity, rounding, or accounting delays can change the resulting backing.

## Validation

Before production, verify each component's owner and immutable vault and asset bindings, and every
distributor's EarnShare, treasury, campaign ID, deadline, and funder allowance. Test Merkle solvency,
root-version and settlement replay protection, recipient deferral and recovery, pause behavior, and
post-deadline treasury return.

Foundry tests in [`test/rewards/`](../../test/rewards/) cover both contracts and the factory. In E2E,
[`rewards-controller`](../../e2e/modules/rewards/module.ts) (group `rewards`) runs on any stack
with a contribution controller, `fees-waterfall` shows contributed growth following the configured
fee waterfall, and `access-ineligible-contributor-does-not-earn` shows an ineligible contributor
receives no position.
