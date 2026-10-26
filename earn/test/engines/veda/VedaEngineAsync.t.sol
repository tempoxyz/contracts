// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { VedaEngine } from "../../../src/engines/veda/VedaEngine.sol";
import { VedaRedeemRequest } from "../../../src/interfaces/external/veda/VedaTypes.sol";
import { VedaEngineTestBase } from "../../helpers/VedaEngineTestBase.sol";

contract VedaEngineAsyncTest is VedaEngineTestBase {
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

    function _assertNoRequestSideEffects(uint256 expectedEngineShares) private view {
        assertEq(vault.balanceOf(address(engine)), expectedEngineShares);
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(vault.allowance(address(engine), address(queue)), 0);
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
}
