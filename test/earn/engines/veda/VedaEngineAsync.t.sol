// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Vm } from "forge-std/Vm.sol";
import { VedaEngine } from "../../../../src/earn/engines/veda/VedaEngine.sol";
import { VedaRedeemRequest } from "../../../../src/interfaces/external/veda/VedaTypes.sol";
import { IMockFinalizeHook } from "../../helpers/VedaEngineMocks.sol";
import { VedaEngineTestBase } from "../../helpers/VedaEngineTestBase.sol";

contract VedaEngineAsyncTest is VedaEngineTestBase, IMockFinalizeHook {
    /// @dev Storage slot of VedaEngine's active Queue, which also holds both claim counters.
    uint256 private constant QUEUE_SLOT = 3;
    /// @dev Storage slot of VedaEngine's active Teller, which also holds `peripheryVersion`.
    uint256 private constant TELLER_SLOT = 2;
    /// @dev Storage slot of VedaEngine's `_claims` mapping.
    uint256 private constant CLAIMS_SLOT = 8;
    /// @dev Storage slot of VedaEngine's persistent settled ledger.
    uint256 private constant SETTLED_SLOT = 10;

    event Settled(address indexed asset, uint256 amount, uint256 newTotal);
    event Unearmarked(address indexed asset, uint256 amount, uint256 newTotal);
    event Finalized(bytes32 indexed requestId, address indexed asset, uint256 amount);
    event FinalizeFailed(bytes32 indexed requestId, address indexed asset, uint256 amount);

    /// @dev What {onFinalize} saw inside each payout frame of a batch.
    uint256[] private _settledSeen;
    uint256 private _sweepAmount;
    address private _sweepTo;
    bytes private _sweepRevert;

    function testRequestRejectsQueuedPayoutBelowMinimumAtomically() public {
        vault.mint(address(engine), 40);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.QueuedAssetsBelowMinimum.selector, 41, 40));
        core.requestRedeemWithMinimum(40, address(asset), 0, 3600, 41);

        _assertNoRequestSideEffects(40);
    }

    function testRequestRevertsAtomicallyWhenQueueStopsTracking() public {
        queue.setTrackWithdrawsOnChain(false);
        vault.mint(address(engine), 40);

        vm.expectRevert(bytes("REQUEST"));
        core.requestRedeem(40, address(asset), 0, 3600);

        assertEq(vault.balanceOf(address(engine)), 40);
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(queue.nonce(), 1);
        assertEq(engine.unresolvedClaimCount(), 0);
    }

    function testRequestRevertsAtomicallyWhenQueueUnderpullsShares() public {
        queue.setSharePullBps(5_000);
        vault.mint(address(engine), 40);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.UnexpectedVenueSharesQueued.selector, 40, 20));
        core.requestRedeem(40, address(asset), 0, 3600);

        assertEq(vault.balanceOf(address(engine)), 40);
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(queue.nonce(), 1);
        assertEq(engine.unresolvedClaimCount(), 0);
    }

    function testRequestRevertsAtomicallyWhenQueueLeavesNoStandingUnit() public {
        // The Queue nets exactly the request's shares but spends the standing unit on the way.
        queue.setSharePullExtra(1);
        vault.mint(address(engine), 41);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.UnexpectedAllowance.selector, address(queue), 0));
        core.requestRedeem(40, address(asset), 0, 3600);

        _assertNoRequestSideEffects(41);
    }

    function testFirstRequestWritesOnlyItsClaimSlot() public {
        // The claim counters share the active Queue's slot, and the Queue allowance keeps its standing unit,
        // so the first request writes no other engine slot from zero.
        vault.mint(address(engine), 40);

        vm.startStateDiffRecording();
        bytes32 id = core.requestRedeem(40, address(asset), 0, 3600);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        (uint256 created, bytes32 createdSlot) = _countCreatedSlots(accesses, address(engine));
        assertEq(created, 1);
        assertEq(createdSlot, keccak256(abi.encode(id, CLAIMS_SLOT)));
        assertEq(vault.allowance(address(engine), address(queue)), 1);
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
        assertEq(engine.unresolvedClaimCount(), 1);
    }

    function testRequestWritesOneNewClaimSlot() public {
        _request(30); // an earlier claim stays open
        vault.mint(address(engine), 40);

        vm.startStateDiffRecording();
        bytes32 id = core.requestRedeem(40, address(asset), 0, 3600);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        bytes32 claimSlot = keccak256(abi.encode(id, CLAIMS_SLOT));
        (uint256 created, bytes32 createdSlot) = _countCreatedSlots(accesses, address(engine));
        assertEq(created, 1);
        assertEq(createdSlot, claimSlot);

        // Queue in the low 160 bits, then status, then the fixed payout in the top 88 bits.
        uint256 word = uint256(vm.load(address(engine), claimSlot));
        assertEq(address(uint160(word)), address(queue));
        assertEq(uint8(word >> 160), uint8(VedaEngine.ClaimStatus.Open));
        assertEq(word >> 168, 40);
        assertEq(vm.load(address(engine), bytes32(uint256(claimSlot) + 1)), bytes32(0));
    }

    function testRequestStoresPayoutAtUint88Bound() public {
        uint128 shares = type(uint88).max;
        bytes32 id = _request(shares);

        uint256 word = uint256(vm.load(address(engine), keccak256(abi.encode(id, CLAIMS_SLOT))));
        assertEq(word >> 168, type(uint88).max);
        assertEq(address(uint160(word)), address(queue));

        asset.mint(address(engine), shares);
        assertEq(engine.forwardSolved(_ids(id), address(asset), shares), 1);
        assertEq(core.finalizedAmount(id), shares);
    }

    function testRequestRejectsPayoutAboveUint88Atomically() public {
        uint128 shares = uint128(type(uint88).max) + 1;
        vault.mint(address(engine), shares);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.QueuedAssetsTooLarge.selector, shares));
        core.requestRedeem(shares, address(asset), 0, 3600);

        _assertNoRequestSideEffects(shares);
    }

    function testCancelReturnsMeasuredQueuedSharesAndKeepsClaimSlot() public {
        bytes32 id = _request(40);
        bytes32 claimSlot = keccak256(abi.encode(id, CLAIMS_SLOT));

        assertEq(core.cancelRedeem(id), 40);

        assertEq(vault.balanceOf(address(engine)), 40);
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
        // The cancelled claim keeps its Queue, so the ID stays rejected.
        uint256 word = uint256(vm.load(address(engine), claimSlot));
        assertEq(address(uint160(word)), address(queue));
        assertEq(uint8(word >> 160), uint8(VedaEngine.ClaimStatus.Cancelled));
        assertEq(engine.claimQueue(id), address(queue));
    }

    function testCancelRevertsWhenQueueReturnsFewerShares() public {
        bytes32 id = _request(40);
        queue.setShareReturnBps(5_000);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.UnexpectedVenueSharesReturned.selector, 40, 20));
        core.cancelRedeem(id);

        _assertClaimStillOpen(id, 40);
    }

    function testCancelRejectsRecordThatDoesNotMatchRequestId() public {
        bytes32 id = _request(40);
        vault.mint(address(queue), 10);
        queue.setCancelReportedShares(50); // returns and reports 50 shares for a 40-share request

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.InvalidTrackedRequest.selector, id));
        core.cancelRedeem(id);

        _assertClaimStillOpen(id, 50);
    }

    function testForwardSolvedCreditIsBoundedByRealBalance() public {
        bytes32 id = _request(40);
        // No asset delivered to the engine, so a 40 credit exceeds the real balance.
        bytes32[] memory ids = _ids(id);
        vm.expectRevert(abi.encodeWithSelector(VedaEngine.CreditExceedsBalance.selector, address(asset), 0, 40));
        engine.forwardSolved(ids, address(asset), 40);
    }

    function testForwardSolvedDegradesToSkipOnUnpayableReceiverThenClaimRecovers() public {
        bytes32 id = _request(40);
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
        asset.mint(address(engine), 40);
        core.setRevertFinalize(true); // the stored receiver's payout reverts

        bytes32[] memory ids = _ids(id);
        uint256 claimed = engine.forwardSolved(ids, address(asset), 40);

        // The whole batch is NOT reverted; only this id is skipped and stays open with funds earmarked.
        assertEq(claimed, 0);
        assertEq(engine.settled(address(asset)), 40);
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
        assertEq(engine.unresolvedClaimCount(), 1);
        assertEq(asset.balanceOf(address(engine)), 40); // payout rolled back, still held
        (VedaEngine.ClaimStatus status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Claimable));

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.ClaimNotOpen.selector, id));
        core.cancelRedeem(id);

        // Once the receiver is payable again, the decoupled recovery drains it out of the earmark.
        core.setRevertFinalize(false);
        assertEq(engine.claimRedeem(id), 40);
        assertEq(core.finalizedAmount(id), 40);
        assertEq(engine.settled(address(asset)), 0);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
        (status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Paid));
    }

    function testUnsolvedTrackedClaimCannotConsumeAnotherClaimsFailedPayout() public {
        bytes32 failedId = _request(40);
        bytes32 unsolvedId = _request(30);
        asset.mint(address(engine), 40);
        core.setRevertFinalize(true);
        engine.forwardSolved(_ids(failedId), address(asset), 40);
        core.setRevertFinalize(false);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.ClaimNotClaimable.selector, unsolvedId));
        engine.claimRedeem(unsolvedId);
        assertEq(engine.settled(address(asset)), 40);
        (VedaEngine.ClaimStatus failedStatus,) = engine.getClaim(failedId);
        (VedaEngine.ClaimStatus unsolvedStatus,) = engine.getClaim(unsolvedId);
        assertEq(uint256(failedStatus), uint256(VedaEngine.ClaimStatus.Claimable));
        assertEq(uint256(unsolvedStatus), uint256(VedaEngine.ClaimStatus.Open));

        // The unsolved claim's own measured delivery funds only that batch and leaves the failed
        // claim's earmark intact.
        asset.mint(address(engine), 30);
        assertEq(engine.forwardSolved(_ids(unsolvedId), address(asset), 30), 1);
        assertEq(core.finalizedAmount(unsolvedId), 30);
        assertEq(engine.settled(address(asset)), 40);

        assertEq(engine.claimRedeem(failedId), 40);
        assertEq(core.finalizedAmount(failedId), 40);
        assertEq(engine.settled(address(asset)), 0);
    }

    function testForwardSolvedRejectsCurrentBatchUnderfunding() public {
        bytes32 id = _request(40);
        asset.mint(address(engine), 39);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.SolveUnderfunded.selector, address(asset), 39, 40));
        engine.forwardSolved(_ids(id), address(asset), 39);

        assertEq(engine.settled(address(asset)), 0);
        (VedaEngine.ClaimStatus status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Open));
    }

    function testExternalSolverPayoutIsUnsweepableAndOwnerRecoverable() public {
        bytes32 id = _request(40);
        queue.solveExternally(id, asset, address(0x5017E2));

        assertEq(asset.balanceOf(address(engine)), 40);
        assertEq(engine.settled(address(asset)), 0);
        assertEq(engine.unresolvedClaimCount(), 1);
        (VedaEngine.ClaimStatus status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Open));

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.BaseAssetSweepBlocked.selector, 1));
        engine.sweepDust(address(asset), address(this), 40);

        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xDEAD)));
        engine.recoverExternalSettlement(_ids(id));

        assertEq(engine.recoverExternalSettlement(_ids(id)), 1);
        assertEq(core.finalizedAmount(id), 40);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(engine.settled(address(asset)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
        (status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Paid));
    }

    function testExternalSettlementRecoveryPreservesFailedPayoutEarmark() public {
        bytes32 id = _request(40);
        queue.solveExternally(id, asset, address(0x5017E2));
        core.setRevertFinalize(true);

        assertEq(engine.recoverExternalSettlement(_ids(id)), 0);
        assertEq(engine.settled(address(asset)), 40);
        assertEq(engine.unresolvedClaimCount(), 1);
        (VedaEngine.ClaimStatus status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Claimable));

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.BaseAssetSweepBlocked.selector, 1));
        engine.sweepDust(address(asset), address(this), 1);

        core.setRevertFinalize(false);
        assertEq(engine.claimRedeem(id), 40);
        assertEq(engine.settled(address(asset)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
    }

    function testQueueRequestCannotChangeCheckpointedRate() public {
        vault.mint(address(engine), 40);
        queue.setRateAfterRequest(2e6);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.RateChangedWithinTransaction.selector, 1e6, 2e6));
        core.requestRedeem(40, address(asset), 0, 3600);

        assertEq(vault.balanceOf(address(engine)), 40);
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(queue.nonce(), 1);
        assertEq(accountant.getRate(), 1e6);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
    }

    function testQueueCancellationCannotChangeCheckpointedRate() public {
        bytes32 id = _request(40);
        queue.setRateAfterCancel(2e6);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.RateChangedWithinTransaction.selector, 1e6, 2e6));
        core.cancelRedeem(id);

        assertEq(vault.balanceOf(address(engine)), 0);
        assertEq(vault.balanceOf(address(queue)), 40);
        assertEq(accountant.getRate(), 1e6);
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
        assertEq(engine.unresolvedClaimCount(), 1);
        (VedaEngine.ClaimStatus status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Open));
    }

    function testMutatingCallsAreEarnVaultOnlyAndForwardIsForwarderOnly() public {
        vm.expectRevert(abi.encodeWithSelector(VedaEngine.NotEarnVault.selector, address(this)));
        engine.requestRedeem(
            1,
            abi.encode(
                VedaRedeemRequest({
                    assetOut: address(asset), discountBps: 0, secondsToDeadline: 3600, minQueuedAssets: 1
                })
            )
        );

        bytes32[] memory ids = new bytes32[](0);
        vm.prank(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(VedaEngine.NotAuthorizedForwarder.selector, address(0xDEAD)));
        engine.forwardSolved(ids, address(asset), 0);
    }

    function testSweepDustCannotTouchBackingShares() public {
        vm.expectRevert(VedaEngine.CannotSweepEngineBacking.selector);
        engine.sweepDust(address(vault), address(this), 1);
    }

    function _assertClaimStillOpen(bytes32 id, uint256 queueShares) private view {
        assertEq(vault.balanceOf(address(engine)), 0);
        assertEq(vault.balanceOf(address(queue)), queueShares);
        assertEq(engine.openClaimsByQueue(address(queue)), 1);
        assertEq(engine.unresolvedClaimCount(), 1);
        (VedaEngine.ClaimStatus status,) = engine.getClaim(id);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Open));
    }

    function _countCreatedSlots(Vm.AccountAccess[] memory accesses, address account)
        private
        pure
        returns (uint256 created, bytes32 lastSlot)
    {
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = storageAccesses[j];
                if (s.account != account || !s.isWrite || s.reverted) continue;
                if (s.previousValue != bytes32(0) || s.newValue == bytes32(0)) continue;
                created++;
                lastSlot = s.slot;
            }
        }
    }

    function _assertNoRequestSideEffects(uint256 expectedEngineShares) private view {
        assertEq(vault.balanceOf(address(engine)), expectedEngineShares);
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(vault.allowance(address(engine), address(queue)), 1);
        assertEq(queue.nonce(), 1);
        assertEq(engine.openClaimsByQueue(address(queue)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
    }

    function testExternalSettlementRecoveryRequiresTrackedOpenClaimAndFunding() public {
        bytes32 id = _request(40);
        vm.expectRevert(abi.encodeWithSelector(VedaEngine.CreditExceedsBalance.selector, address(asset), 0, 40));
        engine.recoverExternalSettlement(_ids(id));

        vm.expectRevert(VedaEngine.NoRecoverableClaims.selector);
        engine.recoverExternalSettlement(_ids(bytes32(uint256(123))));
    }

    function testClaimCountersShareTheQueueSlot() public {
        bytes32 first = _request(40);
        _request(30);

        uint256 word = uint256(vm.load(address(engine), bytes32(QUEUE_SLOT)));
        assertEq(address(uint160(word)), address(queue));
        assertEq(uint48(word >> 160), 2); // claims open on the active Queue
        assertEq(word >> 208, 2); // unresolved claims
        uint256 tellerWord = uint256(vm.load(address(engine), bytes32(TELLER_SLOT)));
        assertEq(address(uint160(tellerWord)), address(engine.teller()));
        assertEq(tellerWord >> 160, engine.peripheryVersion());

        core.cancelRedeem(first);
        word = uint256(vm.load(address(engine), bytes32(QUEUE_SLOT)));
        assertEq(uint48(word >> 160), 1);
        assertEq(word >> 208, 1);
    }

    function testUnresolvedClaimCounterOverflowReverts() public {
        uint256 word = uint256(vm.load(address(engine), bytes32(QUEUE_SLOT)));
        vm.store(address(engine), bytes32(QUEUE_SLOT), bytes32(word | (uint256(type(uint48).max) << 208)));
        vault.mint(address(engine), 40);

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        core.requestRedeem(40, address(asset), 0, 3600);
        assertEq(vault.balanceOf(address(engine)), 40);
    }

    function testActiveQueueClaimCounterOverflowReverts() public {
        uint256 word = uint256(vm.load(address(engine), bytes32(QUEUE_SLOT)));
        vm.store(address(engine), bytes32(QUEUE_SLOT), bytes32(word | (uint256(type(uint48).max) << 160)));
        vault.mint(address(engine), 40);

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        core.requestRedeem(40, address(asset), 0, 3600);
        assertEq(vault.balanceOf(address(engine)), 40);
    }

    function testForwardSolvedPayingEveryClaimWritesNoSettledSlot() public {
        bytes32 a = _request(40);
        bytes32 b = _request(30);
        asset.mint(address(engine), 80); // 10 over the batch
        core.setFinalizeHook(this);

        vm.expectEmit(address(engine));
        emit Settled(address(asset), 80, 80);
        vm.expectEmit(address(engine));
        emit Finalized(a, address(asset), 40);
        vm.expectEmit(address(engine));
        emit Finalized(b, address(asset), 30);
        vm.expectEmit(address(engine));
        emit Unearmarked(address(asset), 10, 0);
        vm.startStateDiffRecording();
        assertEq(engine.forwardSolved(_ids2(a, b), address(asset), 80), 2);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        assertEq(_writesTo(accesses, address(engine), _settledSlot()), 0);
        assertEq(engine.settled(address(asset)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
        assertEq(asset.balanceOf(address(engine)), 10);
        // Each payout frame saw the batch earmark drawn down by the payouts so far.
        assertEq(_settledSeen.length, 2);
        assertEq(_settledSeen[0], 40);
        assertEq(_settledSeen[1], 10);
    }

    function testForwardSolvedRetainsOnlyFailedPayoutsBesidePriorEarmark() public {
        // An earlier failed payout already holds 40 in the ledger.
        bytes32 earlier = _request(40);
        asset.mint(address(engine), 40);
        core.setRevertFinalizeFor(earlier, true);
        engine.forwardSolved(_ids(earlier), address(asset), 40);
        assertEq(engine.settled(address(asset)), 40);

        bytes32 a = _request(20);
        bytes32 stuck = _request(30);
        bytes32 c = _request(10);
        core.setRevertFinalizeFor(stuck, true);
        core.setFinalizeHook(this);
        asset.mint(address(engine), 70); // 10 over the batch

        bytes32[] memory ids = new bytes32[](3);
        (ids[0], ids[1], ids[2]) = (a, stuck, c);
        vm.expectEmit(address(engine));
        emit Settled(address(asset), 70, 110);
        vm.expectEmit(address(engine));
        emit Finalized(a, address(asset), 20);
        vm.expectEmit(address(engine));
        emit FinalizeFailed(stuck, address(asset), 30);
        vm.expectEmit(address(engine));
        emit Finalized(c, address(asset), 10);
        vm.expectEmit(address(engine));
        emit Unearmarked(address(asset), 10, 70);
        assertEq(engine.forwardSolved(ids, address(asset), 70), 2);

        // The failed payout's draw rolled back with its frame, so the later claim still paid in full.
        assertEq(_settledSeen.length, 2);
        assertEq(_settledSeen[0], 90);
        assertEq(_settledSeen[1], 80);
        assertEq(engine.settled(address(asset)), 70);
        assertEq(uint256(vm.load(address(engine), _settledSlot())), 70);
        assertEq(asset.balanceOf(address(engine)), 80);
        assertEq(engine.unresolvedClaimCount(), 2);
        (VedaEngine.ClaimStatus status,) = engine.getClaim(stuck);
        assertEq(uint256(status), uint256(VedaEngine.ClaimStatus.Claimable));

        // Only the 10 surplus is sweepable once every claim closes; both failed payouts recover first.
        core.setFinalizeHook(IMockFinalizeHook(address(0)));
        core.setRevertFinalizeFor(earlier, false);
        core.setRevertFinalizeFor(stuck, false);
        assertEq(engine.claimRedeem(stuck), 30);
        assertEq(engine.claimRedeem(earlier), 40);
        assertEq(engine.settled(address(asset)), 0);
        assertEq(engine.unresolvedClaimCount(), 0);
        vm.expectRevert(
            abi.encodeWithSelector(VedaEngine.SweepExceedsAvailableBalance.selector, address(asset), 10, 11)
        );
        engine.sweepDust(address(asset), address(this), 11);
        engine.sweepDust(address(asset), address(this), 10);
    }

    function testSweepDuringBatchCannotTakeTheInFlightEarmark() public {
        bytes32 id = _request(40);
        asset.mint(address(engine), 55); // 10 over the batch, plus 5 inert
        core.setFinalizeHook(this);
        // The only claim closes before its payout, so the base asset is sweepable inside the frame, but
        // the batch's 10 unconsumed earmark is not.
        (_sweepTo, _sweepAmount) = (address(0xD057), 6);

        assertEq(engine.forwardSolved(_ids(id), address(asset), 50), 1);

        assertEq(_settledSeen.length, 1);
        assertEq(_settledSeen[0], 10);
        assertEq(
            _sweepRevert, abi.encodeWithSelector(VedaEngine.SweepExceedsAvailableBalance.selector, address(asset), 5, 6)
        );
        assertEq(asset.balanceOf(address(0xD057)), 0);

        // After the batch the surplus is unearmarked and the whole remainder is inert.
        assertEq(engine.settled(address(asset)), 0);
        assertEq(asset.balanceOf(address(engine)), 15);
        engine.sweepDust(address(asset), address(0xD057), 15);
        assertEq(asset.balanceOf(address(0xD057)), 15);
    }

    function testSweepDuringBatchTakesOnlyInertBalance() public {
        bytes32 id = _request(40);
        asset.mint(address(engine), 55);
        core.setFinalizeHook(this);
        (_sweepTo, _sweepAmount) = (address(0xD057), 5);

        assertEq(engine.forwardSolved(_ids(id), address(asset), 50), 1);

        assertEq(_sweepRevert.length, 0);
        assertEq(asset.balanceOf(address(0xD057)), 5);
        assertEq(engine.settled(address(asset)), 0);
        assertEq(asset.balanceOf(address(engine)), 10);
    }

    /// @dev Records the ledger inside each payout frame and, when set, tries a sweep as the engine owner.
    function onFinalize(bytes32) external {
        _settledSeen.push(engine.settled(address(asset)));
        if (_sweepTo == address(0)) return;
        try engine.sweepDust(address(asset), _sweepTo, _sweepAmount) { }
        catch (bytes memory reason) {
            _sweepRevert = reason;
        }
    }

    function _settledSlot() private view returns (bytes32) {
        return keccak256(abi.encode(address(asset), SETTLED_SLOT));
    }

    function _ids2(bytes32 a, bytes32 b) private pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        (ids[0], ids[1]) = (a, b);
    }

    function _writesTo(Vm.AccountAccess[] memory accesses, address account, bytes32 slot)
        private
        pure
        returns (uint256 writes)
    {
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = storageAccesses[j];
                if (s.account == account && s.slot == slot && s.isWrite) writes++;
            }
        }
    }
}
