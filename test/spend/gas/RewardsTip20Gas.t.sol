// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CoreEnv } from "../core/harness/CoreEnv.sol";

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";
import {
    EarnContributionController,
    IContributionTarget
} from "../../../src/earn/rewards/EarnContributionController.sol";
import { EarnMerkleRewardDistributor } from "../../../src/earn/rewards/EarnMerkleRewardDistributor.sol";

/// @notice Reward periphery paths measured on real TIP-20 precompiles, where every zero-to-nonzero storage
///         write is charged as a new slot (TIP-1000), over an EarnVault with an ERC-4626 engine. Each call
///         is measured with `gasleft`, like `EarnTip20Gas.t.sol`. The distributor and controller have
///         already funded once, so the measured calls are steady-state ones.
///         `FOUNDRY_PROFILE=spend forge test --match-path test/spend/gas/*` writes the results to snapshots/.
contract RewardsTip20GasTest is CoreEnv {
    EarnMerkleRewardDistributor internal distributor;
    EarnContributionController internal controller;

    address internal funder = makeAddr("gas.funder");
    address internal secondFunder = makeAddr("gas.second-funder");
    address internal treasury = makeAddr("gas.treasury");
    address internal carol = makeAddr("gas.carol");
    address internal dave = makeAddr("gas.dave");

    function setUp() public {
        _deployCore();
        distributor = new EarnMerkleRewardDistributor(
            IEarnVault(address(earnVault)),
            treasury,
            keccak256("gas.campaign"),
            uint40(block.timestamp + 30 days),
            address(this)
        );
        controller = new EarnContributionController(IContributionTarget(address(earnVault)), address(this));

        usd.mint(funder, 1_000_000e6);
        usd.mint(secondFunder, 1_000_000e6);
        vm.startPrank(funder);
        usd.approve(address(distributor), type(uint256).max);
        usd.approve(address(controller), type(uint256).max);
        vm.stopPrank();
        vm.prank(secondFunder);
        usd.approve(address(controller), type(uint256).max);

        // One funding, root and claim each, so the measured calls find the campaign already running.
        distributor.fundAndPublishRoot(
            keccak256("gas.settlement.1"), 0, funder, 1000e6, 1, distributor.leaf(carol, 100e6), 100e6, keccak256("s1")
        );
        distributor.claim(carol, 100e6, new bytes32[](0));
        controller.fund(funder, 100e6, type(uint256).max);
    }

    function test_gasDistributorFundAndPublishRoot() public {
        _measureFundAndPublishRoot("distributor.fund-and-publish");
    }

    /// @dev One base unit left with the distributor keeps its asset balance slot nonzero between fundings.
    function test_gasDistributorFundAndPublishRootWithResidue() public {
        usd.mint(address(distributor), 1);
        _measureFundAndPublishRoot("distributor.fund-and-publish.residue");
    }

    function test_gasDistributorClaimNewRecipient() public {
        distributor.publishRoot(1, distributor.leaf(dave, 50e6), 150e6, keccak256("s2"));
        bytes32[] memory proof = new bytes32[](0);
        uint256 before = gasleft();
        distributor.claim(dave, 50e6, proof);
        vm.snapshotValue("rewards-tip20", "distributor.claim.new-recipient", before - gasleft());
    }

    function test_gasDistributorClaimReturningRecipient() public {
        distributor.publishRoot(1, distributor.leaf(carol, 150e6), 150e6, keccak256("s2"));
        bytes32[] memory proof = new bytes32[](0);
        uint256 before = gasleft();
        distributor.claim(carol, 150e6, proof);
        vm.snapshotValue("rewards-tip20", "distributor.claim.returning", before - gasleft());
    }

    /// @dev One returning and one new recipient in a two-leaf multiproof.
    function test_gasDistributorPushBatchTwo() public {
        bytes32 carolLeaf = distributor.leaf(carol, 150e6);
        bytes32 daveLeaf = distributor.leaf(dave, 50e6);
        bytes32 root = carolLeaf < daveLeaf
            ? keccak256(bytes.concat(carolLeaf, daveLeaf))
            : keccak256(bytes.concat(daveLeaf, carolLeaf));
        distributor.publishRoot(1, root, 200e6, keccak256("s2"));

        address[] memory recipients = new address[](2);
        recipients[0] = carol;
        recipients[1] = dave;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 150e6;
        amounts[1] = 50e6;
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        bytes32[] memory proof = new bytes32[](0);
        uint256 before = gasleft();
        distributor.pushBatch(2, recipients, amounts, proof, flags);
        vm.snapshotValue("rewards-tip20", "distributor.push-batch.2", before - gasleft());
    }

    function test_gasControllerFund() public {
        _measureControllerFund("controller.fund");
    }

    /// @dev One base unit left with the controller keeps its asset balance slot nonzero between fundings.
    function test_gasControllerFundWithResidue() public {
        usd.mint(address(controller), 1);
        _measureControllerFund("controller.fund.residue");
    }

    function test_gasControllerFundBatchExactTwo() public {
        address[] memory funders = new address[](2);
        funders[0] = funder;
        funders[1] = secondFunder;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6;
        amounts[1] = 100e6;
        uint256 before = gasleft();
        controller.fundBatchExact(funders, amounts, type(uint256).max);
        vm.snapshotValue("rewards-tip20", "controller.fund-batch-exact.2", before - gasleft());
    }

    function _measureFundAndPublishRoot(string memory name) private {
        bytes32 root = distributor.leaf(dave, 200e6);
        bytes32 settlementId = keccak256("gas.settlement.2");
        bytes32 statement = keccak256("s2");
        uint256 before = gasleft();
        distributor.fundAndPublishRoot(settlementId, 1, funder, 1000e6, 1, root, 300e6, statement);
        vm.snapshotValue("rewards-tip20", name, before - gasleft());
    }

    function _measureControllerFund(string memory name) private {
        uint256 before = gasleft();
        controller.fund(funder, 100e6, type(uint256).max);
        vm.snapshotValue("rewards-tip20", name, before - gasleft());
    }
}
