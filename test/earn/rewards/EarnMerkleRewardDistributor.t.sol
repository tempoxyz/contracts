// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";
import { EarnMerkleRewardDistributor } from "../../../src/earn/rewards/EarnMerkleRewardDistributor.sol";
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
    address private carol = makeAddr("carol");
    address private relayer = makeAddr("relayer");
    bytes32 private campaignId = keccak256("campaign");
    uint40 private deadline;

    // Alice and Bob hold leaf indexes 0 and 1, so their payout records share one storage slot.
    uint256 private constant aliceIndex = 0;
    uint256 private constant bobIndex = 1;
    uint256 private constant carolIndex = 2;
    // Storage slots from the distributor's layout (forge inspect ... storageLayout).
    uint256 private constant totalsSlot = 4;
    uint256 private constant paidSlot = 5;

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

    function testLeafVersionIsTwo() public view {
        assertEq(distributor.leafVersion(), 2);
    }

    function testLeafBindsChainDistributorCampaignIndexRecipientAndAmount() public view {
        bytes32 expected = keccak256(
            bytes.concat(
                keccak256(abi.encode(block.chainid, address(distributor), campaignId, uint256(7), alice, uint256(5)))
            )
        );
        assertEq(distributor.leaf(7, alice, 5), expected);
        assertTrue(distributor.leaf(7, alice, 5) != distributor.leaf(8, alice, 5));
        assertTrue(distributor.leaf(7, alice, 5) != distributor.leaf(7, bob, 5));
    }

    function testFundingRequiresOwnerAndActiveDeposits() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        distributor.fundAndPublishRoot(
            keccak256("unauthorized"), 0, funder, 1 ether, 1 ether, keccak256("root"), 1 ether, keccak256("statement")
        );

        // The EarnVault's own deposit refuses while its deposits are paused, rolling the pull back with it.
        vault.setDepositsPaused(true);
        uint256 funderBalance = asset.balanceOf(funder);
        vm.prank(owner);
        vm.expectRevert(RewardVaultMock.DepositsPaused.selector);
        distributor.fundAndPublishRoot(
            keccak256("paused-vault"), 0, funder, 1 ether, 1 ether, keccak256("root"), 1 ether, keccak256("statement")
        );
        assertEq(asset.balanceOf(funder), funderBalance);
        assertEq(distributor.rootVersion(), 0);

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

    function testFundAndPublishRootRejectsZeroSettlementId() public {
        vm.prank(owner);
        vm.expectRevert(EarnMerkleRewardDistributor.ZeroSettlementId.selector);
        distributor.fundAndPublishRoot(
            bytes32(0), 0, funder, 1 ether, 1 ether, keccak256("root"), 1 ether, keccak256("statement")
        );
    }

    function testFundAndPublishRootAtomicallyCommitsExactMint() public {
        vault.setSharesPerAsset(2);
        (bytes32 root,,) = _twoLeafRoot(100 ether, 50 ether);
        bytes32 settlementId = keccak256("atomic-settlement");

        vm.expectEmit(true, true, true, true, address(distributor));
        emit EarnMerkleRewardDistributor.SettlementPublished(settlementId, 1);
        vm.prank(owner);
        (uint256 earnShares, uint64 version) = distributor.fundAndPublishRoot(
            settlementId, 0, funder, 75 ether, 150 ether, root, 150 ether, keccak256("atomic-statement")
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

    function testFundAndPublishRootReplayWithStaleVersionRevertsBeforePullingAssets() public {
        bytes32 settlementId = keccak256("one-shot-settlement");
        (bytes32 root,,) = _twoLeafRoot(60 ether, 40 ether);
        vm.prank(owner);
        distributor.fundAndPublishRoot(
            settlementId, 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("one-shot-statement")
        );
        uint256 funderBalance = asset.balanceOf(funder);

        // A retry of the same call is refused by its settlement ID, and any other settlement still carrying
        // the version it expected before the first landed is refused by the version.
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(EarnMerkleRewardDistributor.SettlementAlreadyConsumed.selector, settlementId)
        );
        distributor.fundAndPublishRoot(
            settlementId, 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("one-shot-statement")
        );
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.StaleRootVersion.selector, 0, 1));
        distributor.fundAndPublishRoot(
            keccak256("other-settlement"), 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("other")
        );

        assertEq(asset.balanceOf(funder), funderBalance);
        assertEq(distributor.rootVersion(), 1);
    }

    function testFuzz_FundAndPublishRootRefusesEveryStaleVersion(uint64 staleVersion) public {
        (bytes32 root,,) = _twoLeafRoot(60 ether, 40 ether);
        (bytes32 nextRoot,,) = _twoLeafRoot(120 ether, 80 ether);
        vm.startPrank(owner);
        distributor.fundAndPublishRoot(
            keccak256("settlement-1"), 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("statement-1")
        );
        distributor.fundAndPublishRoot(
            keccak256("settlement-2"), 1, funder, 100 ether, 100 ether, nextRoot, 200 ether, keccak256("statement-2")
        );
        vm.assume(staleVersion != 2);
        uint256 funderBalance = asset.balanceOf(funder);

        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.StaleRootVersion.selector, staleVersion, 2));
        distributor.fundAndPublishRoot(
            keccak256("settlement-1"),
            staleVersion,
            funder,
            100 ether,
            100 ether,
            nextRoot,
            300 ether,
            keccak256("statement-3")
        );
        vm.stopPrank();

        assertEq(asset.balanceOf(funder), funderBalance);
        assertEq(distributor.rootVersion(), 2);
    }

    /// @dev An owner that re-reads the version after a landed call and resubmits the same settlement is
    ///      refused before any asset moves; the next settlement at that version goes through.
    function testFundAndPublishRootRefusesPreviousSettlementAtRefreshedVersion() public {
        bytes32 first = keccak256("settlement-a");
        bytes32 second = keccak256("settlement-b");
        (bytes32 root,,) = _twoLeafRoot(60 ether, 40 ether);
        (bytes32 nextRoot,,) = _twoLeafRoot(120 ether, 80 ether);
        assertEq(distributor.lastSettlementId(), bytes32(0));
        vm.prank(owner);
        distributor.fundAndPublishRoot(first, 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("s1"));
        assertEq(distributor.lastSettlementId(), first);
        uint256 funderBalance = asset.balanceOf(funder);
        uint256 shareBalance = share.balanceOf(address(distributor));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.SettlementAlreadyConsumed.selector, first));
        distributor.fundAndPublishRoot(first, 1, funder, 100 ether, 100 ether, nextRoot, 200 ether, keccak256("s2"));
        assertEq(asset.balanceOf(funder), funderBalance);
        assertEq(share.balanceOf(address(distributor)), shareBalance);
        assertEq(distributor.rootVersion(), 1);
        assertEq(distributor.merkleRoot(), root);

        vm.expectEmit(true, true, true, true, address(distributor));
        emit EarnMerkleRewardDistributor.SettlementPublished(second, 2);
        vm.prank(owner);
        distributor.fundAndPublishRoot(second, 1, funder, 100 ether, 100 ether, nextRoot, 200 ether, keccak256("s2"));
        assertEq(distributor.lastSettlementId(), second);
        assertEq(distributor.rootVersion(), 2);
        assertEq(asset.balanceOf(funder), funderBalance - 100 ether);
    }

    function testFuzz_FundAndPublishRootRefusesOnlyThePreviousSettlement(bytes32 first, bytes32 second) public {
        vm.assume(first != bytes32(0) && second != bytes32(0));
        (bytes32 root,,) = _twoLeafRoot(60 ether, 40 ether);
        (bytes32 nextRoot,,) = _twoLeafRoot(120 ether, 80 ether);
        vm.prank(owner);
        distributor.fundAndPublishRoot(first, 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("s1"));
        uint256 funderBalance = asset.balanceOf(funder);

        vm.prank(owner);
        if (second == first) {
            vm.expectRevert(
                abi.encodeWithSelector(EarnMerkleRewardDistributor.SettlementAlreadyConsumed.selector, first)
            );
            distributor.fundAndPublishRoot(
                second, 1, funder, 100 ether, 100 ether, nextRoot, 200 ether, keccak256("s2")
            );
            assertEq(asset.balanceOf(funder), funderBalance);
            assertEq(distributor.rootVersion(), 1);
            assertEq(distributor.lastSettlementId(), first);
        } else {
            (, uint64 version) = distributor.fundAndPublishRoot(
                second, 1, funder, 100 ether, 100 ether, nextRoot, 200 ether, keccak256("s2")
            );
            assertEq(version, 2);
            assertEq(asset.balanceOf(funder), funderBalance - 100 ether);
            assertEq(distributor.lastSettlementId(), second);
        }
    }

    /// @dev The fuzz above draws equal IDs rarely, so the equal case also runs on its own for any ID.
    function testFuzz_FundAndPublishRootRefusesRepeatedSettlement(bytes32 settlementId) public {
        vm.assume(settlementId != bytes32(0));
        (bytes32 root,,) = _twoLeafRoot(60 ether, 40 ether);
        vm.startPrank(owner);
        distributor.fundAndPublishRoot(settlementId, 0, funder, 100 ether, 100 ether, root, 100 ether, keccak256("s1"));
        uint256 funderBalance = asset.balanceOf(funder);
        vm.expectRevert(
            abi.encodeWithSelector(EarnMerkleRewardDistributor.SettlementAlreadyConsumed.selector, settlementId)
        );
        distributor.fundAndPublishRoot(settlementId, 1, funder, 100 ether, 100 ether, root, 100 ether, keccak256("s2"));
        vm.stopPrank();
        assertEq(asset.balanceOf(funder), funderBalance);
    }

    function testEntitlementAboveUint88Reverts() public {
        uint256 tooLarge = uint256(type(uint88).max) + 1;
        _fund(tooLarge);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.EntitlementTooLarge.selector, tooLarge));
        distributor.publishRoot(0, keccak256("root"), tooLarge, keccak256("statement"));
        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.EntitlementTooLarge.selector, tooLarge));
        distributor.fundAndPublishRoot(
            keccak256("settlement"), 0, funder, 1 ether, 1 ether, keccak256("root"), tooLarge, keccak256("statement")
        );

        // The largest uint88 total is accepted.
        distributor.publishRoot(0, keccak256("root"), type(uint88).max, keccak256("statement"));
        vm.stopPrank();
        assertEq(distributor.rootTotalEntitlement(), type(uint88).max);
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

        (uint256[] memory indexes, address[] memory recipients, uint256[] memory amounts) =
            _twoEntries(100 ether, 50 ether);
        bytes32[] memory proof = new bytes32[](0);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        vm.expectEmit(true, true, true, true, address(distributor));
        emit EarnMerkleRewardDistributor.BatchPushed(
            1, keccak256(abi.encode(uint64(1), indexes, recipients, amounts)), 2, 2, 150 ether, 0
        );
        vm.prank(relayer);
        (uint256 count, uint256 paid, uint256 skipped) =
            distributor.pushBatch(1, indexes, recipients, amounts, proof, flags);
        assertEq(count, 2);
        assertEq(paid, 150 ether);
        assertEq(skipped, 0);
        assertEq(distributor.cumulativePaid(aliceIndex), 100 ether);
        assertEq(distributor.cumulativePaid(bobIndex), 50 ether);

        (bytes32 nextRoot,,) = _twoLeafRoot(120 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(1, nextRoot, 170 ether, keccak256("statement-2"));
        (indexes, recipients, amounts) = _twoEntries(120 ether, 50 ether);
        distributor.pushBatch(2, indexes, recipients, amounts, proof, flags);
        assertEq(share.balanceOf(alice), 120 ether);
        assertEq(share.balanceOf(bob), 50 ether);
    }

    function testBatchRejectsMismatchedArrays() public {
        _fund(150 ether);
        (bytes32 root,,) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement"));
        (uint256[] memory indexes, address[] memory recipients, uint256[] memory amounts) =
            _twoEntries(100 ether, 50 ether);
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.expectRevert(EarnMerkleRewardDistributor.InvalidArrayLengths.selector);
        distributor.pushBatch(1, new uint256[](1), recipients, amounts, new bytes32[](0), flags);
        vm.expectRevert(EarnMerkleRewardDistributor.InvalidArrayLengths.selector);
        distributor.pushBatch(1, indexes, new address[](1), amounts, new bytes32[](0), flags);
        vm.expectRevert(EarnMerkleRewardDistributor.InvalidArrayLengths.selector);
        distributor.pushBatch(1, indexes, recipients, new uint256[](3), new bytes32[](0), flags);
        vm.expectRevert(EarnMerkleRewardDistributor.InvalidArrayLengths.selector);
        distributor.pushBatch(1, new uint256[](0), new address[](0), new uint256[](0), new bytes32[](0), new bool[](0));
    }

    function testBatchRejectsBadProofWrongIndexAndStaleVersion() public {
        _fund(150 ether);
        (bytes32 root,,) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement"));
        (uint256[] memory indexes, address[] memory recipients, uint256[] memory amounts) =
            _twoEntries(100 ether, 50 ether);
        bytes32[] memory proof = new bytes32[](0);
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.expectRevert(abi.encodeWithSelector(EarnMerkleRewardDistributor.StaleRootVersion.selector, 2, 1));
        distributor.pushBatch(2, indexes, recipients, amounts, proof, flags);
        indexes[1] += 2;
        vm.expectRevert(EarnMerkleRewardDistributor.InvalidMultiproof.selector);
        distributor.pushBatch(1, indexes, recipients, amounts, proof, flags);
        indexes[1] -= 2;
        amounts[1] += 1;
        vm.expectRevert(EarnMerkleRewardDistributor.InvalidMultiproof.selector);
        distributor.pushBatch(1, indexes, recipients, amounts, proof, flags);
    }

    function testClaimRejectsLeafUnderAnotherIndex() public {
        _fund(150 ether);
        (bytes32 root,, bytes32 bobLeaf) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement"));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf;

        vm.expectRevert(EarnMerkleRewardDistributor.InvalidMultiproof.selector);
        distributor.claim(carolIndex, alice, 100 ether, proof);
        vm.expectRevert(EarnMerkleRewardDistributor.InvalidMultiproof.selector);
        distributor.claim(aliceIndex, carol, 100 ether, proof);
        distributor.claim(aliceIndex, alice, 100 ether, proof);
        assertEq(share.balanceOf(alice), 100 ether);
    }

    function testMalformedLeafAboveRemainingLiabilitySkipsWithoutOverflow() public {
        _fund(2);
        bytes32 aliceRoot = distributor.leaf(aliceIndex, alice, 1);
        vm.prank(owner);
        distributor.publishRoot(0, aliceRoot, 1, keccak256("first"));
        distributor.claim(aliceIndex, alice, 1, new bytes32[](0));

        uint256[] memory indexes = new uint256[](1);
        indexes[0] = bobIndex;
        address[] memory recipients = new address[](1);
        recipients[0] = bob;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;
        bytes32 malformedRoot = distributor.leaf(bobIndex, bob, type(uint256).max);
        vm.prank(owner);
        distributor.publishRoot(1, malformedRoot, 2, keccak256("malformed"));

        vm.expectEmit(true, true, true, true, address(distributor));
        emit EarnMerkleRewardDistributor.PayoutSkipped(
            bob, type(uint256).max, EarnMerkleRewardDistributor.SkipReason.RootTotalExceeded
        );
        (uint256 paidCount, uint256 paidEarnShares, uint256 skippedCount) =
            distributor.pushBatch(2, indexes, recipients, amounts, new bytes32[](0), new bool[](0));
        assertEq(paidCount, 0);
        assertEq(paidEarnShares, 0);
        assertEq(skippedCount, 1);
        assertEq(distributor.totalPaid(), 1);
        assertEq(distributor.cumulativePaid(bobIndex), 0);

        vm.expectRevert(
            abi.encodeWithSelector(EarnMerkleRewardDistributor.RootTotalExceeded.selector, type(uint256).max, 1)
        );
        distributor.claim(bobIndex, bob, type(uint256).max, new bytes32[](0));
    }

    function testBatchSkipsBlockedRecipientAndClaimRecovers() public {
        _fund(150 ether);
        (bytes32 root, bytes32 aliceLeaf, bytes32 bobLeaf) = _twoLeafRoot(100 ether, 50 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 150 ether, keccak256("statement"));
        share.setBlockedRecipient(bob, true);

        (uint256[] memory indexes, address[] memory recipients, uint256[] memory amounts) =
            _twoEntries(100 ether, 50 ether);
        bytes32[] memory multiproof = new bytes32[](0);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        (uint256 count, uint256 paid, uint256 skipped) =
            distributor.pushBatch(1, indexes, recipients, amounts, multiproof, flags);
        assertEq(count, 1);
        assertEq(paid, 100 ether);
        assertEq(skipped, 1);
        assertEq(distributor.cumulativePaid(bobIndex), 0);
        assertEq(distributor.cumulativePaid(aliceIndex), 100 ether);

        share.setBlockedRecipient(bob, false);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = aliceLeaf;
        vm.expectEmit(true, true, true, true, address(distributor));
        emit EarnMerkleRewardDistributor.RewardClaimed(bob, 50 ether, 50 ether);
        distributor.claim(bobIndex, bob, 50 ether, proof);
        assertEq(share.balanceOf(bob), 50 ether);
        assertEq(bobLeaf, distributor.leaf(bobIndex, bob, 50 ether));
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
        proof[0] = distributor.leaf(bobIndex, bob, 50 ether);
        vm.prank(owner);
        distributor.setPaused(true);
        vm.expectRevert(EarnMerkleRewardDistributor.Paused.selector);
        distributor.claim(aliceIndex, alice, 100 ether, proof);
        vm.prank(owner);
        distributor.setPaused(false);
        vm.warp(uint256(deadline) + 1);
        vm.expectRevert(EarnMerkleRewardDistributor.ClaimsExpired.selector);
        distributor.claim(aliceIndex, alice, 100 ether, proof);
        vm.prank(owner);
        vm.expectRevert(EarnMerkleRewardDistributor.ClaimsExpired.selector);
        distributor.publishRoot(1, root, 150 ether, keccak256("late"));
        assertEq(aliceLeaf, distributor.leaf(aliceIndex, alice, 100 ether));
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
        distributor.claim(aliceIndex, alice, aliceAmount, aliceProof);
        (uint256[] memory indexes, address[] memory recipients, uint256[] memory amounts) =
            _twoEntries(aliceAmount, bobAmount);
        bool[] memory flags = new bool[](1);
        flags[0] = true;
        distributor.pushBatch(1, indexes, recipients, amounts, new bytes32[](0), flags);
        assertEq(distributor.totalPaid(), aliceAmount + bobAmount);
        assertEq(share.balanceOf(alice), aliceAmount);
        assertEq(share.balanceOf(bob), bobAmount);
    }

    /// @dev Indexes 2k and 2k + 1 share a slot. Each claim writes only its own lane, whatever the order and
    ///      however large the amounts, and the raw slot holds lane 0 low and lane 1 high.
    function testFuzz_SlotPartnersArePaidIndependently(uint128 pair, uint128 evenRaw, uint128 oddRaw, bool oddFirst)
        public
    {
        uint256 evenIndex = uint256(pair) * 2;
        uint256 oddIndex = evenIndex + 1;
        uint256 evenAmount = bound(uint256(evenRaw), 1, type(uint88).max - 1);
        uint256 oddAmount = bound(uint256(oddRaw), 1, type(uint88).max - evenAmount);
        uint256 total = evenAmount + oddAmount;
        _fund(total);
        bytes32 evenLeaf = distributor.leaf(evenIndex, alice, evenAmount);
        bytes32 oddLeaf = distributor.leaf(oddIndex, bob, oddAmount);
        vm.prank(owner);
        distributor.publishRoot(0, _hashPair(evenLeaf, oddLeaf), total, keccak256("pair"));
        bytes32[] memory evenProof = new bytes32[](1);
        evenProof[0] = oddLeaf;
        bytes32[] memory oddProof = new bytes32[](1);
        oddProof[0] = evenLeaf;

        if (oddFirst) {
            distributor.claim(oddIndex, bob, oddAmount, oddProof);
            assertEq(distributor.cumulativePaid(evenIndex), 0);
            assertEq(distributor.cumulativePaid(oddIndex), oddAmount);
            distributor.claim(evenIndex, alice, evenAmount, evenProof);
        } else {
            distributor.claim(evenIndex, alice, evenAmount, evenProof);
            assertEq(distributor.cumulativePaid(evenIndex), evenAmount);
            assertEq(distributor.cumulativePaid(oddIndex), 0);
            distributor.claim(oddIndex, bob, oddAmount, oddProof);
        }

        assertEq(distributor.cumulativePaid(evenIndex), evenAmount);
        assertEq(distributor.cumulativePaid(oddIndex), oddAmount);
        assertEq(share.balanceOf(alice), evenAmount);
        assertEq(share.balanceOf(bob), oddAmount);
        assertEq(distributor.totalPaid(), total);
        assertEq(uint256(_paidWord(pair)), evenAmount | (oddAmount << 128));
        // The totals slot holds the root total, totalPaid at bit 88 and the root version at bit 184.
        assertEq(
            uint256(vm.load(address(distributor), bytes32(totalsSlot))), total | (total << 88) | (uint256(1) << 184)
        );
        // Neighbouring pairs stay untouched.
        assertEq(distributor.cumulativePaid(evenIndex == 0 ? 2 : evenIndex - 1), 0);
        assertEq(distributor.cumulativePaid(oddIndex + 1), 0);
    }

    /// @dev A later root raises one lane of a shared slot to the largest amount a root total allows while the
    ///      other keeps its value.
    function testLaneIsolationAtUint88Extremes() public {
        uint256 small = 1;
        uint256 large = type(uint88).max - 1;
        _fund(type(uint88).max);
        bytes32 evenLeaf = distributor.leaf(aliceIndex, alice, small);
        bytes32 oddLeaf = distributor.leaf(bobIndex, bob, small);
        vm.prank(owner);
        distributor.publishRoot(0, _hashPair(evenLeaf, oddLeaf), 2, keccak256("first"));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = oddLeaf;
        distributor.claim(aliceIndex, alice, small, proof);
        proof[0] = evenLeaf;
        distributor.claim(bobIndex, bob, small, proof);

        bytes32 nextOdd = distributor.leaf(bobIndex, bob, large);
        vm.prank(owner);
        distributor.publishRoot(1, _hashPair(evenLeaf, nextOdd), type(uint88).max, keccak256("second"));
        proof[0] = evenLeaf;
        distributor.claim(bobIndex, bob, large, proof);

        assertEq(distributor.cumulativePaid(aliceIndex), small);
        assertEq(distributor.cumulativePaid(bobIndex), large);
        assertEq(distributor.totalPaid(), type(uint88).max);
        assertEq(uint256(_paidWord(0)), small | (large << 128));
        proof[0] = nextOdd;
        vm.expectRevert(EarnMerkleRewardDistributor.NothingOwed.selector);
        distributor.claim(aliceIndex, alice, small, proof);
    }

    /// @dev Two entries for the same index in one batch: the second sees the first's record.
    function testBatchRepeatedIndexPaysOnce() public {
        _fund(100 ether);
        bytes32 aliceLeaf = distributor.leaf(aliceIndex, alice, 100 ether);
        vm.prank(owner);
        distributor.publishRoot(0, _hashPair(aliceLeaf, aliceLeaf), 100 ether, keccak256("statement"));
        uint256[] memory indexes = new uint256[](2);
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = alice;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 100 ether;

        (uint256 count, uint256 paid, uint256 skipped) =
            distributor.pushBatch(1, indexes, recipients, amounts, new bytes32[](0), _flags(1, true));
        assertEq(count, 1);
        assertEq(paid, 100 ether);
        assertEq(skipped, 1);
        assertEq(share.balanceOf(alice), 100 ether);
    }

    function testGas_PushBatch256StaysBelowTempoHeadroom() public {
        uint256 length = 256;
        _fund(length * 1 ether);
        uint256[] memory indexes = new uint256[](length);
        address[] memory recipients = new address[](length);
        uint256[] memory amounts = new uint256[](length);
        bytes32[] memory leaves = new bytes32[](length);
        for (uint256 i; i < length; ++i) {
            address recipient = address(uint160(i + 1_000));
            bytes32 recipientLeaf = distributor.leaf(i, recipient, 1 ether);
            uint256 insertion = i;
            while (insertion != 0 && leaves[insertion - 1] > recipientLeaf) {
                leaves[insertion] = leaves[insertion - 1];
                indexes[insertion] = indexes[insertion - 1];
                recipients[insertion] = recipients[insertion - 1];
                amounts[insertion] = amounts[insertion - 1];
                insertion -= 1;
            }
            leaves[insertion] = recipientLeaf;
            indexes[insertion] = i;
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
        uint256 gasBefore = gasleft();
        distributor.pushBatch(1, indexes, recipients, amounts, new bytes32[](0), _flags(length - 1, true));
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 25_000_000);
        assertEq(distributor.totalPaid(), length * 1 ether);
        emit log_named_uint("pushBatch(256) gas", gasUsed);
    }

    /// @dev The pause flag shares the totals slot (above both 120-bit totals), so a claim's pause check reads
    ///      the slot its payout updates; pausing leaves the totals intact.
    function testPauseFlagSharesTheTotalsSlot() public {
        _fund(100 ether);
        (bytes32 root,, bytes32 bobLeaf) = _twoLeafRoot(60 ether, 40 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 100 ether, keccak256("statement"));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf;
        distributor.claim(aliceIndex, alice, 60 ether, proof);

        vm.prank(owner);
        distributor.setPaused(true);
        uint256 word = uint256(vm.load(address(distributor), bytes32(totalsSlot)));
        assertEq(word, uint256(100 ether) | (uint256(60 ether) << 88) | (uint256(1) << 176) | (uint256(1) << 184));
        assertEq(distributor.rootTotalEntitlement(), 100 ether);
        assertEq(distributor.totalPaid(), 60 ether);

        vm.prank(owner);
        distributor.setPaused(false);
        assertEq(uint256(vm.load(address(distributor), bytes32(totalsSlot))), word & ~(uint256(1) << 176));
    }

    function testClaimWritesOnlyPayoutStorage() public {
        _fund(100 ether);
        (bytes32 root,, bytes32 bobLeaf) = _twoLeafRoot(60 ether, 40 ether);
        vm.prank(owner);
        distributor.publishRoot(0, root, 100 ether, keccak256("statement"));
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bobLeaf;

        vm.startStateDiffRecording();
        distributor.claim(aliceIndex, alice, 60 ether, proof);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        // The transient reentrancy lock writes no storage: only the packed totals slot and the index's payout
        // slot change.
        uint256 writes;
        for (uint256 i; i < accesses.length; ++i) {
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory access = accesses[i].storageAccesses[j];
                if (access.account == address(distributor) && access.isWrite && !access.reverted) {
                    ++writes;
                    assertTrue(
                        access.slot == bytes32(totalsSlot) || access.slot == keccak256(abi.encode(uint256(0), paidSlot))
                    );
                }
            }
        }
        assertEq(writes, 2);
        assertEq(distributor.cumulativePaid(aliceIndex), 60 ether);
        assertEq(distributor.totalPaid(), 60 ether);
    }

    function testReentryDuringPayoutReverts() public {
        ReentrantMockToken hookShare = new ReentrantMockToken("Reward", "RWD", 6);
        RewardVaultMock hookVault = new RewardVaultMock(asset, hookShare);
        EarnMerkleRewardDistributor hooked =
            new EarnMerkleRewardDistributor(IEarnVault(address(hookVault)), treasury, campaignId, deadline, owner);
        hookShare.mint(address(hooked), 100 ether);
        bytes32 aliceLeaf = hooked.leaf(aliceIndex, alice, 60 ether);
        bytes32 bobLeaf = hooked.leaf(bobIndex, bob, 40 ether);
        vm.prank(owner);
        hooked.publishRoot(0, _hashPair(aliceLeaf, bobLeaf), 100 ether, keccak256("statement"));
        bytes32[] memory aliceProof = new bytes32[](1);
        aliceProof[0] = bobLeaf;
        bytes32[] memory bobProof = new bytes32[](1);
        bobProof[0] = aliceLeaf;
        hookShare.armReentry(
            address(hooked), abi.encodeCall(EarnMerkleRewardDistributor.claim, (bobIndex, bob, 40 ether, bobProof))
        );

        hooked.claim(aliceIndex, alice, 60 ether, aliceProof);

        assertFalse(hookShare.reentrySucceeded());
        assertEq(hookShare.reentryResult(), abi.encodeWithSelector(EarnMerkleRewardDistributor.ReentrantCall.selector));
        assertEq(hookShare.balanceOf(alice), 60 ether);
        assertEq(hookShare.balanceOf(bob), 0);
        assertEq(hooked.totalPaid(), 60 ether);
    }

    function _fund(uint256 assets) private {
        share.mint(address(distributor), assets);
    }

    function _paidWord(uint256 pair) private view returns (bytes32) {
        return vm.load(address(distributor), keccak256(abi.encode(pair, paidSlot)));
    }

    function _flags(uint256 length, bool value) private pure returns (bool[] memory flags) {
        flags = new bool[](length);
        for (uint256 i; i < length; ++i) {
            flags[i] = value;
        }
    }

    function _twoEntries(uint256 aliceAmount, uint256 bobAmount)
        private
        view
        returns (uint256[] memory indexes, address[] memory recipients, uint256[] memory amounts)
    {
        indexes = new uint256[](2);
        recipients = new address[](2);
        amounts = new uint256[](2);
        bytes32 aliceLeaf = distributor.leaf(aliceIndex, alice, aliceAmount);
        bytes32 bobLeaf = distributor.leaf(bobIndex, bob, bobAmount);
        uint256 aliceAt = aliceLeaf < bobLeaf ? 0 : 1;
        indexes[aliceAt] = aliceIndex;
        recipients[aliceAt] = alice;
        amounts[aliceAt] = aliceAmount;
        indexes[1 - aliceAt] = bobIndex;
        recipients[1 - aliceAt] = bob;
        amounts[1 - aliceAt] = bobAmount;
    }

    function _twoLeafRoot(uint256 aliceAmount, uint256 bobAmount)
        private
        view
        returns (bytes32 root, bytes32 aliceLeaf, bytes32 bobLeaf)
    {
        aliceLeaf = distributor.leaf(aliceIndex, alice, aliceAmount);
        bobLeaf = distributor.leaf(bobIndex, bob, bobAmount);
        root = _hashPair(aliceLeaf, bobLeaf);
    }

    function _hashPair(bytes32 left, bytes32 right) private pure returns (bytes32) {
        return left < right ? keccak256(bytes.concat(left, right)) : keccak256(bytes.concat(right, left));
    }
}
