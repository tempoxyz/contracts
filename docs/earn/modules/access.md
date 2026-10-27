# EarnShare access policy

This page owns the `access-policy` module: open and protected EarnShare, the TIP-403 policy
administrator, required protocol members, the `validate-access` step, `pnpm earn access`, failure
modes, and tests.

## Open and protected EarnShare

`EarnFactory` sets EarnShare's TIP-20 transfer policy while it is the token's temporary
administrator during creation, then gives up administration, so the policy ID is permanent. An open
deployment uses the always-allow policy `1`. A protected deployment attaches one existing simple
TIP-403 whitelist directly; Earn never creates a parallel or compound policy.

The same membership set controls sending, receiving, and minting, so only members can acquire, move,
or redeem EarnShare. A removed holder keeps its EarnShare and still shares in exchange-rate
increases, but cannot receive, transfer, deposit, or redeem until re-added. Zones mirror the same
policy per account; they are not a separate eligibility cohort. The mirror lags L1: a withdrawal the
Zone queued against its earlier copy of the policy still settles after the holder's L1 removal,
because L1 checks only the protocol members on the route, never the Zone user. TIP-403 membership is
not reward registration.

**Why reuse one existing whitelist:** the same externally administered membership set must govern
minting, holding, transfers, and exits. Reusing the integration's closed-loop policy avoids a second
eligibility source that could drift from it.

Earn does not create, attach, or administer the base asset's policy. A closed-loop base asset must
already enforce its own holder set through its issuer's policy, and an open EarnShare does not
override the base asset's or venue's restrictions.

## Required members

The policy administrator controls eligibility, not issuance or backing, and cannot change EarnShare
issuer membership; the deployment lifecycle never creates the policy or edits its membership. The
administrator must keep every protocol endpoint that moves EarnShare or the asset
authorized: the EarnVault, `EarnFees`, every recipient of the current fee configuration, and, when
configured, the Merkle distributor and its treasury, the Zone router with the Zone's Portal,
Messenger, every active sequencer, and Outbox, and the profile's `zoneRouter`
([`ZoneRouter`](../../router/zone-router.md#deployment)) with its own Zone's Portal, Messenger,
sequencers, and Outbox, whatever its ops. Authorities that never hold EarnShare (owner,
deployer, fee distributor) are not members. Zone account admission and token enablement are separate
Zone-administrator permissions ([Zones](zone-router.md#token-enablement-policy-and-admission)).

## Deployment and operations

A profile's `tip403PolicyId` selects the whitelist; omitting it means open access
([profile schema](../../../profiles/README.md#schema)). The policy ID is part of the `core` intent,
because `deploy-core` passes it to `EarnFactory`.

- **Preflight** requires the policy to be a whitelist with a nonzero administrator.
- **`validate-access`** (deployer, protected profiles only) runs
  `script/deploy/AttachEarnSharePolicy.s.sol` after `deploy-merkle-distributor`. It is satisfied
  when EarnShare's `transferPolicyId` is the configured policy and the policy is a whitelist with a
  live administrator; the script otherwise reverts `PolicyDoesNotExist`, `UnsupportedPolicyType`,
  `PolicyHasNoAdministrator`, or `TransferPolicyMismatch`.
- **Inspection** requires EarnShare's policy ID to equal the profile's, or `1` when open.

Membership is mutable operational state: it never blocks publishing the deployment record. Hosted
E2E acceptance checks that every required member is authorized, and the published stack records the
administrator read live from the registry.

```bash
pnpm earn access --earn-file <profile.json> <status|add|remove> <address>
```

The command acts on the profile's deployed EarnShare policy and reads `.env.<profile-id>` like the
rest of `pnpm earn`. A virtual address resolves to its registered master, which is what TIP-403
authorizes; the zero address is refused. `status` is read-only and works on open stacks. `add` and
`remove` sign with `EARN_ACCESS_ADMIN_PRIVATE_KEY`, falling back to `DEPLOYER_PRIVATE_KEY` with a
warning, and refuse unless that key is the policy's registered administrator. `remove` refuses a
required protocol address, reading fee recipients live from `EarnFees`, or a receiver with an open
async claim, which could otherwise never be paid. Each change is simulated, sent, and read back.

## Tests

E2E cases in [`e2e/modules/access`](../../../e2e/modules/access/module.ts) (group `access`) run only on
protected stacks: `access-admin-guards`, `access-receiver-policy`,
`access-ineligible-contributor-does-not-earn`, `access-transfer-policy`, and
`access-removed-holder`. With a Zone, `zone-ineligible-private-transfer-blocked` and
`zone-ineligible-private-deposit-bounces` cover policy mirroring. The removal-safety guard has unit tests in
[`membership.test.ts`](../../../deployments/modules/earn/access-policy/membership.test.ts), and the
`zoneRouter` members in [`steps.test.ts`](../../../deployments/modules/router/steps.test.ts).
