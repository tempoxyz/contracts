# Audits

This page owns audit coverage for every contract the repository deploys: the completed reports, the
commit each covered, and whether each contract has changed since.

[Sigma Prime](https://sigmaprime.io) completed two security reviews of Earn in August 2026, and
every Earn finding is resolved. The finalized reports are confidential; Tempo shares them under NDA
(request them through security@tempo.xyz). Each report is authoritative for its own scope. Their
final commits are from Earn's history before it was published, so they are not in this repository,
which starts at `62babdf`.

| Report                | Auditor     | Version | Date        | Final commit |
| --------------------- | ----------- | ------- | ----------- | ------------ |
| Zones & Earn Review   | Sigma Prime | 1.1     | August 2026 | `d0160d2`    |
| PropAMM & Earn Review | Sigma Prime | 2.0     | August 2026 | `e8e393a`    |

The Zones & Earn Review covered `EarnVault` and `EarnFees` vault and fee accounting,
`ERC4626Engine`, `SingleZoneEarnRouter` and `EarnContributionController`. The PropAMM & Earn
Review covered `EarnMerkleRewardDistributor`, `VedaEngine`, `VedaForwardingSolver`,
`VedaPeripheryRegistry`, the `EarnVault` asynchronous redemption integration, and the DirectPropAMM
pool contract outside this repository.

## Coverage

Every contract in [`src/`](../src/) that is deployed. A report covers a contract only at its final
commit, so a contract that changed since is not covered as it is now. "Changed since" comes from
`git log --follow` on the contract's source; libraries count with the contracts they compile into
(`EarnFeeMath` into `EarnVault` and `EarnFees`, `SpenderAuth` into each spender).

| Contract                                                                                  | Last audited                                                                                                | Changed since                                                                                                                          |
| ----------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| [`EarnVault`](../src/earn/core/EarnVault.sol)                                             | Zones & Earn v1.1 (async redemption: PropAMM & Earn v2.0)                                                   | Yes: before publication, then standing allowances (`4ed7c4b`), held deposits (`9d92f98`) and storage packing (through `3981c7b`)       |
| [`EarnFees`](../src/earn/core/EarnFees.sol)                                               | Zones & Earn v1.1                                                                                           | Yes: before publication, then storage packing and fee scale (through `3981c7b`)                                                        |
| [`EarnFactory`](../src/earn/core/EarnFactory.sol)                                         | Not audited                                                                                                 | n/a                                                                                                                                    |
| [`ERC4626Engine`](../src/earn/engines/erc4626/ERC4626Engine.sol)                          | Zones & Earn v1.1                                                                                           | Yes: before publication, then standing allowances (`4ed7c4b`) and held deposits (`9d92f98`)                                            |
| [`ERC4626EngineFactory`](../src/earn/engines/erc4626/ERC4626EngineFactory.sol)            | Not audited                                                                                                 | n/a                                                                                                                                    |
| [`HoldEngine`](../src/earn/engines/hold/HoldEngine.sol)                                   | Not audited                                                                                                 | n/a (added in `5f8ee98`)                                                                                                               |
| [`PropAMMEngine`](../src/earn/engines/propamm/PropAMMEngine.sol)                          | Not audited (experimental)                                                                                  | n/a                                                                                                                                    |
| [`VedaEngine`](../src/earn/engines/veda/VedaEngine.sol)                                   | PropAMM & Earn v2.0                                                                                         | Yes: held deposits and standing approvals (`ff61b68`), transient batch earmarks (`c27bc11`), one-unit approvals (`c34a5d5`), `71f4093` |
| [`VedaForwardingSolver`](../src/earn/engines/veda/VedaForwardingSolver.sol)               | PropAMM & Earn v2.0                                                                                         | Yes: request checks (`71f4093`)                                                                                                        |
| [`VedaPeripheryRegistry`](../src/earn/engines/veda/VedaPeripheryRegistry.sol)             | PropAMM & Earn v2.0                                                                                         | Import paths only                                                                                                                      |
| [`EarnContributionController`](../src/earn/rewards/EarnContributionController.sol)        | Zones & Earn v1.1                                                                                           | Yes: before publication, then batch contributions (`16c1a85`)                                                                          |
| [`EarnMerkleRewardDistributor`](../src/earn/rewards/EarnMerkleRewardDistributor.sol)      | PropAMM & Earn v2.0                                                                                         | Yes: before publication, then payouts by leaf index (`42fe8b0`) and storage packing (`91eb7d5`)                                        |
| [`EarnRewardsFactory`](../src/earn/rewards/EarnRewardsFactory.sol)                        | Not audited                                                                                                 | n/a                                                                                                                                    |
| [`SingleZoneEarnRouter`](../src/earn/router/SingleZoneEarnRouter.sol)                     | Zones & Earn v1.1                                                                                           | Yes: before publication, then standing approvals (`ff61b68`) and par-price caching (`5c4dded`)                                         |
| [`ZoneRouter`](../src/zone/ZoneRouter.sol): op 0 Deposit, op 1 Redeem, op 2 Spend         | Not audited (ops 0 and 1 copy `SingleZoneEarnRouter`'s logic, but no report covers this contract)           | n/a                                                                                                                                    |
| [`ZoneRouterFactory`](../src/zone/ZoneRouterFactory.sol)                                  | Not audited                                                                                                 | n/a                                                                                                                                    |
| [`SendSpender`](../src/zone/spenders/SendSpender.sol)                                     | Not audited                                                                                                 | n/a                                                                                                                                    |
| [`CardFactory`](../src/spend/CardFactory.sol)                                             | Not audited                                                                                                 | n/a                                                                                                                                    |
| [`CardSpender`](../src/spend/CardSpender.sol)                                             | Not audited                                                                                                 | n/a                                                                                                                                    |
| [`BridgeProvider`](../src/spend/providers/bridge/BridgeProvider.sol)                      | Not audited                                                                                                 | n/a                                                                                                                                    |
| [`SpenderTempoSpend`](../src/spend/providers/bridge/SpenderTempoSpend.sol) ("TS" handler) | Not audited; Bridge's vendored base code it compiles in is listed in [`VENDORED.md`](../vendor/VENDORED.md) | n/a                                                                                                                                    |
| [`RainProvider`](../src/spend/providers/rain/RainProvider.sol)                            | Not audited                                                                                                 | n/a                                                                                                                                    |

No report covers:

- the Foundry deployment scripts in `script/` and the profile lifecycle tooling in `deployments/`;
- the oracle and rebalance controller used with a DirectPropAMM pool;
- contracts under `src/demo/`, which are never deployed, and offchain services; or
- the external venue, Zone, token, oracle, and pool dependencies.

Before a release, review every contract it deploys that is not audited or has changed since, and
record that review alongside the deployment's operational evidence.

Veda's own BoringVault audits are published at
[docs.veda.tech](https://docs.veda.tech/security-and-risk-controls/audits).
