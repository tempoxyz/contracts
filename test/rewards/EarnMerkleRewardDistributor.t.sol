// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../src/interfaces/core/IEarnVault.sol";
import { EarnMerkleRewardDistributor } from "../../src/rewards/EarnMerkleRewardDistributor.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Test } from "forge-std/Test.sol";
import { FaultyMockToken, RewardVaultMock } from "../helpers/EarnVaultMocks.sol";

contract EarnMerkleRewardDistributorTest is Test {
    FaultyMockToken private asset;
    FaultyMockToken private share;
    RewardVaultMock private vault;
    EarnMerkleRewardDistributor private distributor;

    address private owner = makeAddr("owner");
    address private treasury = makeAddr("treasury");
    address private funder = makeAddr("funder");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private relayer = makeAddr("relayer");
    bytes32 private campaignId = keccak256("campaign");
    uint40 private deadline;

    function setUp() public {
        vm.warp(1_000_000);
        deadline = uint40(block.timestamp + 30 days);
        asset = new FaultyMockToken("Reward", "RWD", 6);
        share = new FaultyMockToken("Reward", "RWD", 6);
        vault = new RewardVaultMock(asset, share);
        distributor = new EarnMerkleRewardDistributor(IEarnVault(address(vault)), treasury, campaignId, deadline, owner);
        asset.mint(funder, 10_000 ether);
        vm.prank(funder);
        asset.approve(address(distributor), type(uint256).max);
    }

    function testFundingRequiresOwnerAndActiveDeposits() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        distributor.fundAndPublishRoot(
            keccak256("unauthorized"), 0, funder, 1 ether, 1 ether, keccak256("root"), 1 ether, keccak256("statement")
        );

        vault.setDepositsPaused(true);
        vm.prank(owner);
        vm.expectRevert(EarnMerkleRewardDistributor.DepositsPaused.selector);
        distributor.fundAndPublishRoot(
            keccak256("paused-vault"), 0, funder, 1 ether, 1 ether, keccak256("root"), 1 ether, keccak256("statement")
        );

        vault.setDepositsPaused(false);
        vm.prank(owner);
        distributor.setPaused(true);
        vm.prank(owner);
        vm.expectRevert(EarnMerkleRewardDistributor.Paused.selector);
        distributor.fundAndPublishRoot(
            keccak256("paused-distributor"),
            0,
            funder,
            1 ether,
            1 ether,
            keccak256("root"),
            1 ether,
            keccak256("statement")
        );
    }

    function testFundAndPublishRootAtomicallyCommitsExactMint() public {
        vault.setSharesPerAsset(2);
        (bytes32 root,,) = _twoLeafRoot(100 ether, 50 ether);

        vm.prank(owner);
        (uint256 earnShares, uint64 version) = distributor.fundAndPublishRoot(
            keccak256("atomic-settlement"),
            0,
            funder,
            75 ether,
            150 ether,
            root,
            150 ether,
            keccak256("atomic-statement")
        );

        assertEq(earnShares, 150 ether);
        assertEq(version, 1);
        assertEq(distributor.merkleRoot(), root);
        assertEq(distributor.rootTotalEntitlement(), 150 ether);
        assertEq(share.balanceOf(address(distributor)), 150 ether);
        assertEq(asset.balanceOf(address(distributor)), 0);
        assertEq(asset.allowance(address(distributor), address(vault)), 0);
    }

    function testFundAndPublishRootRevertsAtomicallyBelowMinimum() public {
        (bytes32 root,,) = _twoLeafRoot(51 ether, 50 ether);
        uint256 funderBalance = asset.balanceOf(funder);

        vm.prank(owner);
        vm.expectRevert("MIN_SHARES");
        distributor.fundAndPublishRoot(
            keccak256("under-minimum-settlement"),
            0,
            funder,
            100 ether,
            101 ether,
            root,
            101 ether,
            keccak256("under-minimum-statement")
        );

        assertEq(asset.balanceOf(funder), funderBalance);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(share.balanceOf(address(distributor)), 0);
        assertEq(distributor.rootVersion(), 0);
    }

    function testFundAndPublishRootRejectsSettlementReplayBeforePullingAssets() public {
        bytes32 settlementId = keccak256("one-shot-settlement");
        (bytes32 root,,) = _twoLeafRoot(60 ether, 40 ether);
        vm.prank(owner);
        distributor.fundAndPublishRoot(
            settlementId, 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("one-shot-statement")
        );
        uint256 funderBalance = asset.balanceOf(funder);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(EarnMerkleRewardDistributor.SettlementAlreadyConsumed.selector, settlementId)
        );
        distributor.fundAndPublishRoot(
            settlementId, 1, funder, 100 ether, 100 ether, root, 100 ether, keccak256("one-shot-statement")
        );

        assertEq(asset.balanceOf(funder), funderBalance);
        assertTrue(distributor.consumedSettlements(settlementId));
        assertEq(distributor.rootVersion(), 1);
    }

    function testRootPublicationRejectsStaleExpectedVersion() public {
        _fund(150 ether);
        (bytes32 root,,) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement-1"));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.StaleRootVersion.selector, 0, 1));
        distributor.publishRoot(0, root, 150 ether, keccak256("statement-2"));
    }

    function testPublishesOnlyFullyFundedMonotonicRoot() public {
        _fund(150 ether);
        (bytes32 root,,) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement-1"));

        assertEq(distributor.merkleRoot(), root);
        assertEq(distributor.rootTotalEntitlement(), 150 ether);
        assertEq(distributor.rootVersion(), 1);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(EarnMerkleRewardDistributor.RootTotalDecreased.selector, 150 ether, 149 ether)
        );
        distributor.publishRoot(1, root, 149 ether, keccak256("statement-2"));
    }

    function testPausedAllowsSameTotalCorrectionOnly() public {
        _fund(151 ether);
        (bytes32 root,,) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement-1"));
        vm.prank(owner);
        distributor.setPaused(true);

        vm.prank(owner);
        distributor.publishRoot(1, root, 150 ether, keccak256("correction"));
        vm.prank(owner);
        vm.expectRevert(EarnMerkleRewardDistributor.PausedLiabilityIncrease.selector);
        distributor.publishRoot(2, root, 151 ether, keccak256("increase"));
    }

    function testPermissionlessMultiproofPushPaysCumulativeDeltas() public {
        _fund(170 ether);
        (bytes32 root,,) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement-1"));

        (address[] memory recipients, uint256[] memory amounts) = _twoEntries(100 ether, 50 ether);
        bytes32[] memory proof = new bytes32[](0);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        vm.prank(relayer);
        (uint256 count, uint256 paid, uint256 skipped) = distributor.pushBatch(1, recipients, amounts, proof, flags);
        assertEq(count, 2);
        assertEq(paid, 150 ether);
        assertEq(skipped, 0);

        (bytes32 nextRoot,,) = _twoLeafRoot(120 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(1, nextRoot, 170 ether, keccak256("statement-2"));
        (recipients, amounts) = _twoEntries(120 ether, 50 ether);
        distributor.pushBatch(2, recipients, amounts, proof, flags);
        assertEq(share.balanceOf(alice), 120 ether);
        assertEq(share.balanceOf(bob), 50 ether);
    }

    function testBatchRejectsBadProofAndStaleVersion() public {
        _fund(150 ether);
        (bytes32 root,,) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement"));
        (address[] memory recipients, uint256[] memory amounts) = _twoEntries(100 ether, 50 ether);
        bytes32[] memory proof = new bytes32[](0);
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.StaleRootVersion.selector, 2, 1));
        distributor.pushBatch(2, recipients, amounts, proof, flags);
        amounts[1] = 51 ether;
        vm.expectRevert(EarnMerkleRewardDistributor.InvalidMultiproof.selector);
        distributor.pushBatch(1, recipients, amounts, proof, flags);
    }

    function testMalformedLeafAboveRemainingLiabilitySkipsWithoutOverflow() public {
        _fund(2);
        bytes32 aliceRoot = distributor.leaf(alice, 1);
        vm.prank(owner);
        distributor.publishRoot(0, aliceRoot, 1, keccak256("first"));
        distributor.claim(alice, 1, new bytes32[](0));

        address[] memory recipients = new address[](1);
        recipients[0] = bob;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        bytes32 malformedRoot = distributor.leaf(bob, type(uint256).max);
        vm.prank(owner);
        distributor.publishRoot(1, malformedRoot, 2, keccak256("malformed"));

        (uint256 paidCount, uint256 paidEarnShares, uint256 skippedCount) =
            distributor.pushBatch(2, recipients, amounts, new bytes32[](0), new bool[](0));
        assertEq(paidCount, 0);
        assertEq(paidEarnShares, 0);
        assertEq(skippedCount, 1);
        assertEq(distributor.totalPaid(), 1);
    }

    function testBatchSkipsBlockedRecipientAndClaimRecovers() public {
        _fund(150 ether);
        (bytes32 root, bytes32 aliceLeaf, bytes32 bobLeaf) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement"));
        share.setBlockedRecipient(bob, true);

        (address[] memory recipients, uint256[] memory amounts) = _twoEntries(100 ether, 50 ether);
        bytes32[] memory multiproof = new bytes32[](0);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        (uint256 count, uint256 paid, uint256 skipped) =
            distributor.pushBatch(1, recipients, amounts, multiproof, flags);
        assertEq(count, 1);
        assertEq(paid, 100 ether);
        assertEq(skipped, 1);
        assertEq(distributor.cumulativePaid(bob), 0);

        share.setBlockedRecipient(bob, false);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = aliceLeaf;
        distributor.claim(bob, 50 ether, proof);
        assertEq(share.balanceOf(bob), 50 ether);
        assertEq(bobLeaf, distributor.leaf(bob, 50 ether));
    }

    function testReturnsOnlyEarnShareAfterDeadline() public {
        _fund(150 ether);
        vm.warp(uint256(deadline) + 1);
        vm.prank(relayer);
        uint256 returned = distributor.returnUnspent();
        assertEq(returned, 150 ether);
        assertEq(share.balanceOf(treasury), 150 ether);
        assertEq(asset.balanceOf(treasury), 0);
    }

    function testPauseAndDeadlineStopFundingPushAndClaim() public {
        _fund(150 ether);
        (bytes32 root, bytes32 aliceLeaf,) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement"));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = distributor.leaf(bob, 50 ether);
        vm.prank(owner);
        distributor.setPaused(true);
        vm.expectRevert(EarnMerkleRewardDistributor.Paused.selector);
        distributor.claim(alice, 100 ether, proof);
        vm.prank(owner);
        distributor.setPaused(false);
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(EarnMerkleRewardDistributor.ClaimsExpired.selector);
        distributor.claim(alice, 100 ether, proof);
        vm.prank(owner);
        vm.expectRevert(EarnMerkleRewardDistributor.ClaimsExpired.selector);
        distributor.publishRoot(1, root, 150 ether, keccak256("late"));
        assertEq(aliceLeaf, distributor.leaf(alice, 100 ether));
    }

    function testFuzz_ClaimThenBatchPaysOnlyCumulativeDeltas(uint96 aliceRaw, uint96 bobRaw) public {
        uint256 aliceAmount = bound(uint256(aliceRaw), 1, 1_000 ether);
        uint256 bobAmount = bound(uint256(bobRaw), 1, 1_000 ether);
        _fund(aliceAmount + bobAmount);
        (bytes32 root,, bytes32 bobLeaf) = _twoLeafRoot(aliceAmount, bobAmount);
        vm.prank(owner);
        distributor.publishRoot(0, root, aliceAmount + bobAmount, keccak256("fuzz"));
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        distributor.claim(alice, aliceAmount, aliceProof);
        (address[] memory recipients, uint256[] memory amounts) = _twoEntries(aliceAmount, bobAmount);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        distributor.pushBatch(1, recipients, amounts, new bytes32[](0), flags);
        assertEq(distributor.totalPaid(), aliceAmount + bobAmount);
        assertEq(share.balanceOf(alice), aliceAmount);
        assertEq(share.balanceOf(bob), bobAmount);
    }

    function testGas_PushBatch256StaysBelowTempoHeadroom() public {
        uint256 length = 256;
        _fund(length * 1 ether);
        address[] memory recipients = new address[](length);
        uint256[] memory amounts = new uint256[](length);
        bytes32[] memory leaves = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            address recipient = address(uint160(i + 1_000));
            bytes32 recipientLeaf = distributor.leaf(recipient, 1 ether);
            uint256 insertion = i;
            while (insertion != 0 && leaves[insertion - 1] > recipientLeaf) {
                leaves[insertion] = leaves[insertion - 1];
                recipients[insertion] = recipients[insertion - 1];
                amounts[insertion] = amounts[insertion - 1];
                insertion -= 1;
            }
            leaves[insertion] = recipientLeaf;
            recipients[insertion] = recipient;
            amounts[insertion] = 1 ether;
        }
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            bytes32[] memory next = new bytes32[](level.length / 2);
            for (uint256 i; i < next.length; ++i) {
                next[i] = _hashPair(level[i * 2], level[i * 2 + 1]);
            }
            level = next;
        }
        vm.prank(owner);
        distributor.publishRoot(0, level[0], length * 1 ether, keccak256("gas-256"));
        bool[] memory flags = new bool[](length - 1);
        for (uint256 i; i < flags.length; ++i) {
            flags[i] = true;
        }
        uint256 gasBefore = gasleft();
        distributor.pushBatch(1, recipients, amounts, new bytes32[](0), flags);
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 25_000_000);
        emit log_named_uint("pushBatch(256) gas", gasUsed);
    }

    function _fund(uint256 assets) private {
        share.mint(address(distributor), assets);
    }

    function _twoEntries(uint256 aliceAmount, uint256 bobAmount)
        private
        view
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        recipients = new address[](2);
        amounts = new uint256[](2);
        bytes32 aliceLeaf = distributor.leaf(alice, aliceAmount);
        bytes32 bobLeaf = distributor.leaf(bob, bobAmount);
        if (aliceLeaf < bobLeaf) {
            recipients[0] = alice;
            recipients[1] = bob;
            amounts[0] = aliceAmount;
            amounts[1] = bobAmount;
        } else {
            recipients[0] = bob;
            recipients[1] = alice;
            amounts[0] = bobAmount;
            amounts[1] = aliceAmount;
        }
    }

    function _twoLeafRoot(uint256 aliceAmount, uint256 bobAmount)
        private
        view
        returns (bytes32 root, bytes32 aliceLeaf, bytes32 bobLeaf)
    {
        aliceLeaf = distributor.leaf(alice, aliceAmount);
        bobLeaf = distributor.leaf(bob, bobAmount);
        root = _hashPair(aliceLeaf, bobLeaf);
    }

    function _hashPair(bytes32 left, bytes32 right) private pure returns (bytes32) {
        return left < right ? keccak256(bytes.concat(left, right)) : keccak256(bytes.concat(right, left));
    }
}
