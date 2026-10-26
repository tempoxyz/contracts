# Audits

[Sigma Prime](https://sigmaprime.io) completed two security reviews of Earn in August 2026, and
every Earn finding is resolved. The finalized reports are confidential; Tempo shares them under NDA
(request them through security@tempo.xyz). Each report is authoritative for its own scope.

| Report                | Auditor     | Version | Date        |
| --------------------- | ----------- | ------- | ----------- |
| Zones & Earn Review   | Sigma Prime | 1.1     | August 2026 |
| PropAMM & Earn Review | Sigma Prime | 2.0     | August 2026 |

## Zones & Earn Review

The Earn scope was:

- `EarnVault` and `EarnFees` vault and fee accounting
- `ERC4626Engine`
- `SingleZoneEarnRouter`
- `EarnContributionController`
- the ERC-4626 stack, router, EarnShare-policy, and contribution-controller deployment scripts

## PropAMM & Earn Review

The Earn scope was:

- `EarnMerkleRewardDistributor`
- `VedaEngine`, `VedaForwardingSolver`, and `VedaPeripheryRegistry`
- `EarnVault` asynchronous redemption integration

The review also covered the DirectPropAMM pool contract.

## Scope

Each report covers its listed components at the version it reviewed. Components not listed above,
and changes made after a report's review, are not covered by it. Neither report covers contracts
under `src/demo/`, the browser app, Worker, or offchain services, or the external venue, Zone,
token, oracle, and pool dependencies. Before a release, review anything outside that coverage and
record the review alongside the deployment's operational evidence.

Veda's own BoringVault audits are published at
[docs.veda.tech](https://docs.veda.tech/security-and-risk-controls/audits).
