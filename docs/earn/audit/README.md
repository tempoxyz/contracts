# Audits

Status: Audits complete; every Earn finding is resolved

Sigma Prime's finalized security reports on Earn are confidential; Tempo shares them under NDA
(request them through security@tempo.xyz). Reviewed scope, commits, and finding details are
authoritative in each report. Commits cited here are from Earn's history before it was published.

Both engagements also covered another codebase. The
four closed findings (TMPOZE-15, -18, -20, and -21) are informational, Zones-only, and accepted
without the recommended change.

| Report                | Auditor     | Version | Date        | Earn commits (initial → final) | Earn findings                   |
| --------------------- | ----------- | ------- | ----------- | ------------------------------ | ------------------------------- |
| Zones & Earn Review   | Sigma Prime | 1.1     | August 2026 | `ea3307b` → `d0160d2`          | 1 High, 3 Medium, 4 Low, 1 Info |
| PropAMM & Earn Review | Sigma Prime | 2.0     | August 2026 | `d0d5385` → `e8e393a`          | 1 Low, 2 Info                   |

## Zones & Earn Review

Earn findings: TMPOZE-01, -02, -03, -06, -09, -10, -11, -13, and -14. The Earn scope was:

- `EarnVault` and `EarnFees` vault and fee accounting
- `ERC4626Engine`
- `SingleZoneEarnRouter`
- `EarnContributionController`
- `DeployERC4626EarnStack`, `DeployEarnRouter`, `AttachEarnSharePolicy`, and
  `DeployEarnContributionController` scripts

Version 1.1 supersedes 1.0 only by rolling the final Zones integration commit forward.

## PropAMM & Earn Review

Earn findings: TMPOPE-02, -03, and -04. The Earn scope was:

- `EarnMerkleRewardDistributor`
- `VedaEngine`, `VedaForwardingSolver`, and `VedaPeripheryRegistry`
- `EarnVault` asynchronous redemption integration

Version 2.0 supersedes 1.0, which listed SIGP-327 as open.

## Coverage after the audits

Each report covers its listed components at its final commit. The Zones & Earn components were last
assessed at `d0160d2`; the PropAMM & Earn review re-covered `EarnVault` only for its asynchronous
redemption integration, through `e8e393a`. The contract and script changes below merged after those
commits and are not covered by either report.

| Component                                                                       | Post-audit changes                                                                                                                     |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `SingleZoneEarnRouter`                                                          | Converts private assets through the DirectPropAMM par pool, and deposits the vault asset directly when it is the private asset         |
| `EarnVault`                                                                     | Stale-valuation fee deferral, initial configuration events, transferable operator, self-recipient overloads, and zero-fee distributors |
| `EarnFees`                                                                      | Stale-valuation fee deferral                                                                                                           |
| `ERC4626Engine`                                                                 | `initializeEarnVault(earnVault, finalOwner)`, which binds the vault and transfers ownership in one call                                |
| `EarnContributionController`                                                    | Atomic rewards settlement hardening                                                                                                    |
| `DeployEarnRouter`, `AttachEarnSharePolicy`, `DeployEarnContributionController` | Deployment input changes, the par-pool and same-asset router changes above, and typed `run(Input)` calldata for every lifecycle script |
| `EarnMerkleRewardDistributor`                                                   | Production settlement hardening                                                                                                        |
| `EarnRewardsFactory`                                                            | New after the audits                                                                                                                   |
| `PropAMMEngine`                                                                 | New after the audits; experimental. See the [PropAMM review](../modules/propamm.md#review-scope).                                      |

`EarnFactory` and `ERC4626EngineFactory` are not listed in either report's scope; both also changed
after the audits, including factory releases with an empty EarnShare currency and zero-fee
distributors.
The audited `DeployERC4626EarnStack` script is not in the repository; stacks deploy through
`DeployERC4626Engine` and `DeployEarnCore`, which, like `DeployEarnMerkleRewardDistributor` and
`DeployFactoryRelease`, are outside both reports' scope. The Veda contracts are unchanged since
`e8e393a`.

The DirectPropAMM pool source (`src/DirectPropAMM.sol` in the private PropAMM repository) at the
[fixture's pinned commit](../modules/propamm.md#pinned-directpropamm-fixture) is unchanged from the
audited propAMM commit `4a4f9d3`. The `PushPriceOracle` and `DirectPropAMMRebalanceController` used by the
production pool were not in either report's scope.

Neither report covers contracts under `src/demo/`, the browser app, Worker, or offchain services,
or the external venue, Zone, token, and pool dependencies. Before a release that includes any
post-audit change, record its review alongside the deployment's operational evidence.

## Provenance

Sigma Prime delivered both reports to Tempo on the dates below.

| Report                     | Delivered  | SHA-256                                                            |
| -------------------------- | ---------- | ------------------------------------------------------------------ |
| Zones & Earn Review v1.1   | 2026-08-19 | `52391bed39649fc0e495c6d0e458e0196fadc226d0acdf1701f1fc5362ef1bbb` |
| PropAMM & Earn Review v2.0 | 2026-08-27 | `5cbd98c0711ac955850cf7dd4765f017f7bd9cd23e36e3cfb42b47b90f85c147` |

Veda's own BoringVault audits are published at
[docs.veda.tech](https://docs.veda.tech/security-and-risk-controls/audits).
