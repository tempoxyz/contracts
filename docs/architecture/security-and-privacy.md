# Security and privacy

This page states what each privileged party can and cannot do, which accounting protections the
contracts enforce, which external dependencies remain trusted, and what Zone privacy does and does
not hide. Audit coverage is on the [audits page](../audit/README.md).

## Security model at a glance

Tempo Earn limits authority by responsibility ([roles](system.md#roles-and-authority) and
[invariants](system.md#core-invariants)). The ownerless Zone router authenticates one canonical Zone
and moves only the value each callback delivers, converting through at most one immutable par pool;
the EarnVault holds no customer-specific conversion policy. This separation limits the effect of a
defect in one module but does not make the system trustless. The base asset, yield venue, engine
valuation, EarnVault operator, fee distributor, external TIP-403 policy administrator, Zone protocol,
DirectPropAMM pool operator and oracle, and stablecoins remain explicit trust boundaries.

## Authority boundaries

### EarnShare issuance

Issuer membership and the attached policy ID are immutable after the atomic factory creation
([EarnShare](system.md#earnshare)). Deployment inspection rejects a stack unless the EarnVault holds
issuer membership and the factory, operator, and EarnVault hold no EarnShare administrator role; E2E
validation also fails if any other recorded stack contract holds issuer membership.

### Delegated user calls

Self-recipient overloads of deposits and exits fix the receiver to the caller, allowing a Tempo
access key to be scoped to a selector that cannot redirect the result. Explicit-receiver variants
remain separately callable and must not be included in a self-recipient key's scope. The key still
controls operation timing, amounts, and slippage bounds; this is a recipient guarantee, not a
complete investment policy. See [client permission setup](../integrations/client.md#delegated-self-recipient-calls).

### EarnVault operator

The operator may:

- pause or unpause deposits, in-kind entry, contributions, and surplus absorption;
- update the managed-assets limit, including setting zero for unlimited capacity;
- rotate or clear the emergency guardian and async janitor;
- configure ordinary positive-accrual fees, and disable all fees on a stack without a distributor; and
- hand the operator role to a successor.

It cannot change EarnShare, `EarnFees`, the base asset, or the distributor's item, delay, or role.

The handoff is two-step: the operator nominates a nonzero successor, which must accept; until then
the operator may cancel or replace the nomination.

### Emergency guardian and async janitor

The guardian can only reduce exposure by pausing deposits, in-kind entry, contributions, and
surplus absorption. It cannot unpause or block exits.

The janitor can only cancel an already open async request to its stored receiver. It cannot select a
receiver or request a new exit.

### Stack operator, fee distributor, and EarnFees

The operator's ordinary fee items, the optional `distributor`'s protected, publicly delayed item,
their shared 10,000-bps fixed-fee bound, and global disablement (operator only, and only without a
distributor) are specified in [configuration and authority](fees.md#configuration-and-authority).
Neither authority can call `EarnFees` directly, apply new terms retroactively, or charge deposited
principal; users and integrators must monitor operator configurations, pending distributor updates,
and role transfers.

`EarnFees` has no owner, issuer role, engine authority, route authority, or rescue function. It
transfers only the caller's recorded `claimableEarnShares`, and only the EarnVault mints the
calculated fee EarnShare to it. A fee-module compromise therefore cannot independently create
claims or change policy. A defect in fee calculation could still cause the EarnVault to mint an
incorrect amount, so fee math and engine NAV remain security-critical.

### Engine owners

An engine setup owner binds the EarnVault once and may transfer ownership to the final owner in the
same call. After binding, only the EarnVault can deposit, redeem, withdraw, queue, or cancel against
the engine's venue position. Final-owner powers are engine-specific; Veda's owner, registry, and
forwarding-solver authorities are in [Veda](../modules/veda.md#contracts).

### Earn router

The ownerless `SingleZoneEarnRouter` has no authority over EarnVault, its pool, or EarnShare
issuance and retains no balances or allowances after success. Its authentication, par-conversion
dependency, and failure behavior are specified in [Tempo Zones](../modules/zone-router.md).

### Reward periphery

`EarnContributionController` and `EarnMerkleRewardDistributor` hold no EarnShare issuer, EarnVault,
EarnFees, engine, router, or policy authority. Their owner powers and the trust placed in the
Merkle root publisher are specified in [rewards](../modules/rewards.md).

### EarnShare access administrator

The external TIP-403 policy administrator controls eligibility, not issuance or backing. Its
authority, the protocol members it must preserve, and the base-asset policy boundary are specified
in [access policy](../modules/access.md).

## Accounting protections

### Measured inputs and outputs

The contracts do not rely on external return values where a balance delta is available:

- every engine deposit and in-kind entry must report exactly the measured
  raw-share increase, or the EarnVault reverts. The ERC-4626 engine does not measure how much base
  asset the venue pulls, so a venue that pulls less than requested strands the rest in the engine;
  venue soundness is a trust boundary;
- immediate engine exits verify venue-share consumption and receiver delivery from measured
  balance deltas rather than trusting venue return values, and Veda queued requests verify the
  exact venue-share decrease;
- async cancellation credits the measured raw-share increase;
- swap output uses the router's measured output-token delta; and
- Veda forwarding credits only measured solve deltas.

This limits dishonest or nonstandard return values, but cannot make an insolvent token, venue, or
oracle sound.

Surplus quarantine, shortfall reconciliation, zero-backing entry rejection, and the fixed 100×
reward-admission limit are specified under [accounting anchors](system.md#accounting-anchors).

### Managed-assets capacity

The optional `maxManagedAssets` limit ([accounting anchors](system.md#accounting-anchors)) blocks only
voluntary inflows; exits and cancellation remain available. It is only as sound as the
engine's valuation: it is a vault exposure control, not a per-user allocation, reward budget, or
protection against a dishonest venue or oracle. Integrators must treat the operator as the
capacity-policy trust boundary and monitor `MaxManagedAssetsChanged`.

### Slippage and exactness

Every value-changing path has explicit units and independent bounds:

- deposits and in-kind entry require nonzero `minEarnShares`;
- redemption requires nonzero `minAssets`;
- exact withdrawal checks `maxEarnShares` against both the preview and the measured charge;
- private swap paths separately bound base assets and final output;
- async cancellation requires a nonzero `minReceiverEarnShares`; and
- async request conversion rejects more than one basis point of unrepresented EarnShare before burn;
  Veda requests also require the tracking Queue's fixed payout to meet a nonzero absolute asset floor.

Independently of caller bounds, the EarnVault rejects a base-asset or in-kind entry, or a
nonempty-pool cancellation re-entry, that leaves more than one basis point of the engine shares
unrepresented after floor rounding.

### Reentrancy and transient approvals

EarnVault economic calls, `EarnFees.claim`, engine asset paths, and the router callback use local
reentrancy locks. The router
sets exact approvals, performs one downstream call, clears or fully consumes the approval, and
verifies touched token balances against the operation baseline, so no leftover allowance survives a
successful call. External token callbacks remain a trust boundary; a revert rolls back approval and
balance changes atomically.

### Async claim isolation

EarnShare burns when a request is created; the pending entitlement is not active supply or NAV.
Finalization and cancellation use one stored receiver. The request's fee snapshot pins its
configuration ID, so active fee changes cannot rewrite prior cancellation terms, and a crossed
disable transition permanently waives it ([queued withdrawals](fees.md#queued-withdrawals)).
Cancellation cannot expand the contribution limit
([reward-admission limit](system.md#reward-admission-limit)).

Engine-specific claim protections, such as Veda's Queue pinning, earmarks, and external-solver
recovery, are in [Veda queued exits](../modules/veda.md#queued-exits).

## External dependency risk

### Yield venues and valuation

An engine is only as safe as its venue ([yield engines](../integrations/engines.md#engine-contract)).
Fee EarnShare is an irreversible claim on backing, so an inflated valuation can over-mint fees; the
requirements before enabling fees are in [Earn fees](fees.md#security-and-deployment-requirements).
A stale expiring valuation suppresses fee crystallization without blocking exits.

### Source ERC-4626 vaults

Earn has no source-vault entrypoint; holders compose their own exit, and each supported source
requires integration-specific review ([source-vault
composition](../modules/migration.md#source-vault-composition)).

### Permissionless contributions

Anyone can increase active backing with `contribute`. This can change quotes and accrue configured
fees, so clients must bind user actions to current `minEarnShares`, `minAssets`, or `maxEarnShares`
rather than assume a stable exchange rate between quote and execution. Direct engine-share transfers
cannot bypass the 100× admission limit ([rewards](../modules/rewards.md#exchange-rate-contributions)).

## Privacy model

Zones hide balances and history from outside observers, not from the Zone sequencer. The sequencer
sees and orders Zone activity.

Public observers can see:

- public input token, amount, sender, and timing;
- target EarnVault and router;
- source or target Portal;
- swap and EarnVault calls;
- aggregate engine, supply, fee, and claim state;
- callback flow, bounds, action ID, and public refund recipient; and
- router, EarnVault, fee, and engine events.

Encrypted recipient and memo data are not public. The callback's `senderTag` is deliberately ignored
and never emitted or persisted by Earn.

This does not make amount- and timing-correlated actions unlinkable. A unique private withdrawal
followed by an immediate public action or encrypted return can be correlated. The protocol does not
reveal the private recipient from that correlation alone, but it does not hide the public legs.

## Operational failure modes

| Failure                                     | Onchain result                                                                                                                                                       | Recovery                                                                                 |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Deposit pause                               | New exposure reverts; exits stay open                                                                                                                                | Operator reviews and unpauses                                                            |
| Broken valuation with fees active           | Fee-checkpointed action may revert                                                                                                                                   | Operator disables fees on a stack without a distributor; otherwise restore the valuation |
| Immediate venue liquidity exhausted         | Immediate exit reverts                                                                                                                                               | Use public async request where supported                                                 |
| Async request stalls                        | Entitlement stays open                                                                                                                                               | Veda: solve through the forwarding solver; or requester/janitor cancels                  |
| Swap misses bound                           | Complete route reverts                                                                                                                                               | Refresh quote or deploy/select a compatible router                                       |
| Zone callback fails                         | Original private withdrawal bounces under protocol rules                                                                                                             | Fix cause and submit a new withdrawal                                                    |
| Engine valuation becomes stale              | Veda and PropAMM deposits revert; fee crystallization is deferred                                                                                                    | Publish a fresh report; exits remain available                                           |
| Veda receiver hook spends a batch's gas     | Later claims in a solve stay claimable, or the solve reverts                                                                                                         | Omit that request from the batch; anyone pays out with `claimRedeem`                     |
| Receiver's TIP-1028 policy blocks EarnShare | A deposit or cancellation mint, or an `EarnFees` claim, lands in the receive-policy guard, which only the sending contract could reclaim and which has no claim path | None; name only receivers that accept EarnShare                                          |
| Cancellation after active backing is lost   | `cancelRedeem` re-anchors all supply over only the returned engine shares, moving part of the claimant's backing to other holders                                    | Finalize the queued claim instead of cancelling                                          |

## Production readiness checklist

- Release covered by the completed [Solidity audits](../audit/README.md), with any
  post-audit change separately reviewed, plus an independent economic review.
- Sole-issuer verification and issuer-role monitoring.
- Reviewed base asset, venue, engine, and valuation behavior against the real venue:
  - a dedicated or gated venue, so unrelated shareholders do not receive Earn contributions;
  - share and asset decimals, including first-deposit rounding;
  - deposit, redeem, exact withdrawal, and illiquidity;
  - contributions under the venue's fees, rate caps, and accounting rules;
  - `totalAssets` and `previewRedeem` under stale, inflated, illiquid, and fee-bearing states; and
  - venue pause, loss, and insolvency as explicit runbook cases.
- Engine owner and EarnVault operator assigned to the intended production accounts.
- Verified immutable EarnVault–EarnFees and EarnVault–engine bindings.
- Verified that the installed engine advertises at least one redeem, exact-withdraw, or async-redeem
  capability.
- `EarnVault` within the EIP-170 runtime and EIP-3860 initcode limits under
  `FOUNDRY_PROFILE=deploy`; its runtime margin is only a few hundred bytes, and CI enforces no
  margin ([contract size](../development.md#contract-size)).
- Tested async cancellation, loss recovery, and fee disablement.
- For a Zone-connected stack, the [Zone go-live checklist](../modules/zone-router.md#go-live-checklist).
- Verified EarnShare directly uses the intended simple TIP-403 whitelist and every required
  protocol member remains authorized.
- For reward periphery, the [rewards validation](../modules/rewards.md#validation) checks.
- Tested the exact production scripts, manifests, app, local E2E, and hosted flows.
- Published v1 addresses and ABIs; deployments are replaced rather than upgraded in place.

Passing repository tests reduces implementation risk but does not replace the audits or a venue review.
