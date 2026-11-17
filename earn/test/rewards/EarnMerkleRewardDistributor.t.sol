// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../src/interfaces/core/IEarnVault.sol";
import { EarnMerkleRewardDistributor } from "../../src/rewards/EarnMerkleRewardDistributor.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Test, Vm } from "forge-std/Test.sol";
import { FaultyMockToken, ReentrantMockToken, RewardVaultMock } from "../helpers/EarnVaultMocks.sol";

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
        // A standing maximum to the immutable EarnVault; the distributor holds no base asset to pull.
        assertEq(asset.allowance(address(distributor), address(vault)), type(uint256).max);
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
        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.RepeatedSettlementId.selector, settlementId));
        distributor.fundAndPublishRoot(
            settlementId, 1, funder, 100 ether, 100 ether, root, 100 ether, keccak256("one-shot-statement")
        );

        assertEq(asset.balanceOf(funder), funderBalance);
        assertEq(distributor.lastSettlementId(), settlementId);
        assertEq(distributor.rootVersion(), 1);
    }

    function testFundAndPublishRootRejectsOlderSettlementReplayAsStaleVersion() public {
        bytes32 first = keccak256("settlement-1");
        bytes32 second = keccak256("settlement-2");
        (bytes32 root,,) = _twoLeafRoot(60 ether, 40 ether);
        (bytes32 nextRoot,,) = _twoLeafRoot(120 ether, 80 ether);
        vm.startPrank(owner);
        distributor.fundAndPublishRoot(
            first, 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("statement-1")
        );
        distributor.fundAndPublishRoot(
            second, 1, funder, 100 ether, 100 ether, nextRoot, 200 ether, keccak256("statement-2")
        );
        uint256 funderBalance = asset.balanceOf(funder);

        // The first settlement is no longer the last one, so the root version check refuses its replay.
        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.StaleRootVersion.selector, 0, 2));
        distributor.fundAndPublishRoot(
            first, 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("statement-1")
        );
        vm.stopPrank();

        assertEq(asset.balanceOf(funder), funderBalance);
        assertEq(distributor.lastSettlementId(), second);
        assertEq(distributor.rootVersion(), 2);
        assertEq(distributor.merkleRoot(), nextRoot);
    }

    function testLaterSettlementOverwritesOneSlotAndEmitsItsId() public {
        bytes32 first = keccak256("settlement-1");
        bytes32 second = keccak256("settlement-2");
        (bytes32 root,,) = _twoLeafRoot(60 ether, 40 ether);
        (bytes32 nextRoot,,) = _twoLeafRoot(120 ether, 80 ether);
        vm.prank(owner);
        distributor.fundAndPublishRoot(
            first, 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("statement-1")
        );

        vm.expectEmit(true, true, false, true, address(distributor));
        emit EarnMerkleRewardDistributor.AssetsFunded(second, funder, 100 ether, 100 ether);
        vm.startStateDiffRecording();
        vm.prank(owner);
        distributor.fundAndPublishRoot(
            second, 1, funder, 100 ether, 100 ether, nextRoot, 200 ether, keccak256("statement-2")
        );
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        // A later settlement creates no distributor slot: its ID overwrites the previous one in place.
        uint256 created;
        uint256 overwrites;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory access = accesses[i].storageAccesses[j];
                if (access.account != address(distributor) || !access.isWrite || access.reverted) continue;
                if (access.previousValue == bytes32(0) && access.newValue != bytes32(0)) ++created;
                if (access.previousValue == first && access.newValue == second) ++overwrites;
            }
        }
        assertEq(created, 0);
        assertEq(overwrites, 1);
        assertEq(distributor.lastSettlementId(), second);
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

    function testClaimWritesOnlyPayoutStorage() public {
        _fund(100 ether);
        (bytes32 root,, bytes32 bobLeaf) = _twoLeafRoot(60 ether, 40 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 100 ether, keccak256("statement"));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf;

        vm.startStateDiffRecording();
        distributor.claim(alice, 60 ether, proof);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        // The transient reentrancy lock writes no storage: only totalPaid and the recipient's cumulativePaid change.
        uint256 writes;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory access = accesses[i].storageAccesses[j];
                if (access.account == address(distributor) && access.isWrite && !access.reverted) ++writes;
            }
        }
        assertEq(writes, 2);
        assertEq(distributor.cumulativePaid(alice), 60 ether);
        assertEq(distributor.totalPaid(), 60 ether);
    }

    function testReentryDuringPayoutReverts() public {
        ReentrantMockToken hookShare = new ReentrantMockToken("Reward", "RWD", 6);
        RewardVaultMock hookVault = new RewardVaultMock(asset, hookShare);
        EarnMerkleRewardDistributor hooked =
            new EarnMerkleRewardDistributor(IEarnVault(address(hookVault)), treasury, campaignId, deadline, owner);
        hookShare.mint(address(hooked), 100 ether);
        bytes32 aliceLeaf = hooked.leaf(alice, 60 ether);
        bytes32 bobLeaf = hooked.leaf(bob, 40 ether);
        vm.prank(owner);
        hooked.publishRoot(0, _hashPair(aliceLeaf, bobLeaf), 100 ether, keccak256("statement"));
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = aliceLeaf;
        hookShare.armReentry(
            address(hooked), abi.encodeCall(EarnMerkleRewardDistributor.claim, (bob, 40 ether, bobProof))
        );

        hooked.claim(alice, 60 ether, aliceProof);

        assertFalse(hookShare.reentrySucceeded());
        assertEq(hookShare.reentryResult(), abi.encodeWithSelector(EarnMerkleRewardDistributor.ReentrantCall.selector));
        assertEq(hookShare.balanceOf(alice), 60 ether);
        assertEq(hookShare.balanceOf(bob), 0);
        assertEq(hooked.totalPaid(), 60 ether);
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
