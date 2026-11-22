// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";

import { CardAuth } from "../../../src/spend/programs/CardAuth.sol";
import { CardAuthBase } from "../../../src/spend/programs/CardAuthBase.sol";
import { CardLimits } from "../../../src/spend/programs/CardLimits.sol";
import { SavingsSource } from "../../../src/spend/programs/SavingsSource.sol";
import { IReservationCore } from "../../../src/interfaces/spend/programs/IReservationCore.sol";
import { CAPTURE_FINAL, CAPTURE_FREE } from "../../../src/interfaces/spend/programs/ISource.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice The savings source over a real EarnVault and the core model, driven directly as its program: holds on
///         Earn shares, captures that redeem and pay the settlement account, deferred redemptions paid from the
///         float, refunds that deposit back into the vault, and the funder's float.
contract SavingsSourceTest is AuthEnv {
    bytes32 internal constant ID = bytes32("leg-1");
    bytes32 internal constant ID2 = bytes32("leg-2");
    uint256 internal shares;

    function setUp() public {
        _deployPrograms();
        usd.mint(alice, 1000e6);
        shares = _depositEarn(alice, 1000e6);
        vm.prank(alice);
        core.approveHolder(address(savings), address(earnShare), type(uint128).max, 0);
    }

    function test_constructor_standingApprovals() public view {
        assertEq(earnShare.allowance(address(savings), address(earnVault)), type(uint256).max);
        assertEq(usd.allowance(address(savings), address(earnVault)), type(uint256).max);
    }

    function test_hold_placesSharesWorthTheUnits() public {
        assertEq(_place(ID, 300e6), 300e6);
        uint256 leg = _leg(ID).held;
        assertEq(leg, earnVault.previewWithdraw(300e6));
        assertEq(_leg(ID).payee, address(savings));
        assertEq(savings.held(alice, bytes32(0), ID), earnVault.previewRedeem(leg));
        // More than the owner has holds everything free, worth what it redeems for.
        uint256 placed = _place(ID2, 5000e6);
        assertEq(placed, earnVault.previewRedeem(shares - leg));
        assertEq(core.available(alice, address(earnShare)), 0);
    }

    function test_capture_redeemsAndPaysSettlement() public {
        _place(ID, 300e6);
        uint256 leg = _leg(ID).held;
        uint256 value = earnVault.previewRedeem(leg);
        vm.prank(address(cards));
        (uint256 paid,) = savings.capture(alice, bytes32(0), ID, 300e6, CAPTURE_FINAL);
        assertEq(paid, 300e6);
        // Rounding the shares up may redeem a little more than the capture; it goes with the capture.
        assertEq(usd.balanceOf(settlement), value);
        assertGe(value, 300e6);
        assertEq(earnShare.balanceOf(address(savings)), 0);
        assertEq(usd.balanceOf(address(savings)), FLOAT);
        assertEq(savings.heldShares(), 0);
        // The final capture ends the leg, so the core forgets it.
        assertEq(_leg(ID).token, address(0));
        _assertCoreBalanced();
    }

    function test_capture_writesOnlyTheLegsExistingSlot() public {
        _place(ID, 100e6);
        bytes32 slot = _legSlot(ID);
        assertTrue(vm.load(address(savings), slot) != 0, "the hold writes the leg's slot");
        vm.record();
        vm.prank(address(cards));
        savings.capture(alice, bytes32(0), ID, 100e6, CAPTURE_FINAL);
        (, bytes32[] memory writes) = vm.accesses(address(savings));
        for (uint256 i; i < writes.length; ++i) {
            assertEq(writes[i], slot);
        }
        vm.record();
        usd.mint(address(savings), 40e6);
        vm.prank(address(cards));
        savings.refund(alice, bytes32(0), ID, 40e6);
        (, writes) = vm.accesses(address(savings));
        for (uint256 i; i < writes.length; ++i) {
            assertEq(writes[i], slot);
        }
    }

    function test_refundable_capturedLessRefunded() public {
        assertEq(savings.refundable(alice, bytes32(0), ID), 0);
        _place(ID, 200e6);
        assertEq(savings.refundable(alice, bytes32(0), ID), 0);
        vm.prank(address(cards));
        savings.capture(alice, bytes32(0), ID, 150e6, CAPTURE_FINAL);
        assertEq(savings.refundable(alice, bytes32(0), ID), 150e6);
        usd.mint(address(savings), 40e6);
        vm.prank(address(cards));
        savings.refund(alice, bytes32(0), ID, 40e6);
        assertEq(savings.refundable(alice, bytes32(0), ID), 110e6);
        (bool placed, uint120 captured, uint120 refunded,) = savings.legs(ID);
        assertTrue(placed);
        assertEq(captured, 150e6);
        assertEq(refunded, 40e6);
    }

    function test_capture_partial() public {
        _place(ID, 200e6);
        uint256 leg = _leg(ID).held;
        uint256 first = earnVault.previewWithdraw(50e6);
        vm.prank(address(cards));
        (uint256 got,) = savings.capture(alice, bytes32(0), ID, 50e6, 0);
        assertEq(got, 50e6);
        assertEq(_leg(ID).held, leg - first);
        uint256 second = earnVault.previewWithdraw(50e6);
        vm.prank(address(cards));
        savings.capture(alice, bytes32(0), ID, 50e6, CAPTURE_FINAL);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertEq(earnShare.balanceOf(alice), shares - first - second);
        _assertCoreBalanced();
    }

    function test_onlyProgram() public {
        _place(ID, 100e6);
        vm.startPrank(bob);
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.capture(alice, bytes32(0), ID, 1e6, 0);
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.hold(alice, bytes32(0), ID2, 1e6, _expiry());
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.release(alice, bytes32(0), ID);
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.refund(alice, bytes32(0), ID, 1e6);
        vm.expectRevert(SavingsSource.NotProgram.selector);
        savings.charge(alice, bytes32(0), ID, 1e6);
        vm.stopPrank();
    }

    function test_capture_onlyItsOwnLegs() public {
        // Another holder's share hold under the same id is not the source's to capture.
        vm.prank(alice);
        core.approveHolder(address(this), address(earnShare), type(uint128).max, 0);
        core.holdFrom(
            alice,
            IReservationCore.HoldRequest({
                token: address(earnShare), id: ID, amount: 100e6, expiresAt: _expiry(), payee: bob
            })
        );
        vm.prank(address(cards));
        (uint256 got,) = savings.capture(alice, bytes32(0), ID, 1e6, CAPTURE_FINAL);
        assertEq(got, 0);
        assertEq(core.getHold(alice, address(this), ID).held, 100e6);
        assertEq(usd.balanceOf(settlement), 0);
    }

    function test_capture_notBeyondHeld() public {
        _place(ID, 100e6);
        uint256 leg = _leg(ID).held;
        uint256 value = earnVault.previewRedeem(leg);
        // Asked for more than it holds, the source takes only its hold.
        vm.prank(address(cards));
        (uint256 got,) = savings.capture(alice, bytes32(0), ID, 150e6, 0);
        assertEq(got, value);
        assertEq(earnShare.balanceOf(alice), shares - leg);
        // With CAPTURE_FREE it grows the hold into the owner's free shares; the program bounds the purchase's tolerance.
        _place(ID2, 100e6);
        vm.prank(address(cards));
        (got,) = savings.capture(alice, bytes32(0), ID2, 150e6, CAPTURE_FREE | CAPTURE_FINAL);
        assertApproxEqAbs(got, 150e6, 1);
        assertApproxEqAbs(shares - leg - earnShare.balanceOf(alice), earnVault.previewWithdraw(150e6), 1);
        _assertCoreBalanced();
    }

    function test_capture_beyondTheHold_takesFreeShares() public {
        _setTolerance(alice, address(savings), address(earnShare), 5000);
        uint256 before = earnShare.balanceOf(alice);
        _place(ID, 100e6);
        vm.prank(address(cards));
        (uint256 paid,) = savings.capture(alice, bytes32(0), ID, 140e6, CAPTURE_FREE | CAPTURE_FINAL);
        assertEq(paid, 140e6);
        assertEq(before - earnShare.balanceOf(alice), earnVault.previewWithdraw(140e6));
        _assertCoreBalanced();
    }

    function test_capture_deferredWhenVaultCannotRedeem() public {
        _place(ID, 100e6);
        uint256 leg = _leg(ID).held;
        uint256 value = earnVault.previewRedeem(leg);
        vm.mockCallRevert(
            address(earnVault),
            abi.encodeWithSignature("redeem(uint256,address,uint256)", leg, settlement, value),
            "illiquid"
        );
        vm.prank(address(cards));
        (uint256 paid,) = savings.capture(alice, bytes32(0), ID, 100e6, CAPTURE_FINAL);
        assertEq(paid, 100e6);
        assertEq(usd.balanceOf(settlement), value);
        assertEq(savings.heldShares(), leg);
        assertEq(usd.balanceOf(address(savings)), FLOAT - value);

        vm.clearMockedCalls();
        vm.prank(funder);
        savings.redeemHeld(leg, value);
        assertEq(savings.heldShares(), 0);
        assertGe(usd.balanceOf(address(savings)), FLOAT - 1);
    }

    function test_capture_deferred_refusedPastTheFloat() public {
        vm.prank(funder);
        savings.withdraw(address(usd), funder, FLOAT);
        _place(ID, 100e6);
        uint256 leg = _leg(ID).held;
        uint256 value = earnVault.previewRedeem(leg);
        vm.mockCallRevert(
            address(earnVault),
            abi.encodeWithSignature("redeem(uint256,address,uint256)", leg, settlement, value),
            "illiquid"
        );
        vm.prank(address(cards));
        vm.expectRevert(abi.encodeWithSelector(SavingsSource.InsufficientFloat.selector, value, uint256(0)));
        savings.capture(alice, bytes32(0), ID, 100e6, CAPTURE_FINAL);
    }

    function test_capture_revertsWithoutQuote() public {
        _place(ID, 100e6);
        uint256 leg = _leg(ID).held;
        vm.mockCall(address(earnVault), abi.encodeWithSignature("previewRedeem(uint256)", leg), abi.encode(0));
        vm.prank(address(cards));
        vm.expectRevert(SavingsSource.NoQuote.selector);
        savings.capture(alice, bytes32(0), ID, 100e6, CAPTURE_FINAL);
        vm.clearMockedCalls();
        assertEq(_leg(ID).held, leg);
    }

    function test_refund_depositsCashAndRefundsShares() public {
        _place(ID, 300e6);
        uint256 leg = _leg(ID).held;
        vm.prank(address(cards));
        (uint256 paid,) = savings.capture(alice, bytes32(0), ID, 300e6, CAPTURE_FINAL);
        // The program pays the source the refund before calling it.
        usd.mint(address(savings), paid);
        vm.prank(address(cards));
        savings.refund(alice, bytes32(0), ID, paid);
        uint256 minted = earnShare.balanceOf(alice) - (shares - leg);
        assertApproxEqAbs(earnVault.previewRedeem(minted), paid, 1, "the refund deposits its whole value");
        assertApproxEqAbs(earnShare.balanceOf(alice), shares, 1);
        assertEq(usd.balanceOf(address(savings)), FLOAT, "the float is untouched");
        assertEq(earnShare.balanceOf(address(savings)), 0);
    }

    function test_refund_boundedByTheProgramAtWhatItCovered() public {
        // Through the program: refunds stop at what the savings leg captured.
        _issueSavingsOnly();
        vm.prank(issuer);
        cards.authorize(CARD, bytes32("p1"), 100e6, merchant, _expiry(), 0);
        vm.prank(issuer);
        cards.capture(bytes32("p1"), 100e6, true);
        uint256 before = earnShare.balanceOf(alice);
        usd.mint(issuer, 1000e6);
        vm.startPrank(issuer);
        usd.approve(address(cards), type(uint256).max);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(bytes32("p1"), 100e6 + 1);
        cards.refund(bytes32("p1"), 100e6);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(bytes32("p1"), 1);
        vm.stopPrank();
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice) - before), 100e6, 1);
        assertEq(usd.balanceOf(issuer), 900e6);
        assertEq(usd.balanceOf(address(savings)), FLOAT);
    }

    function test_funderOnly() public {
        vm.expectRevert(SavingsSource.NotFunder.selector);
        savings.withdraw(address(usd), address(this), 1);
        vm.expectRevert(SavingsSource.NotFunder.selector);
        savings.redeemHeld(1, 0);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(SavingsSource.ExceedsHeldShares.selector, uint256(1), uint256(0)));
        savings.withdraw(address(earnShare), funder, 1);
        vm.prank(funder);
        savings.withdraw(address(usd), funder, 1e6);
        assertEq(usd.balanceOf(funder), 1e6);
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(SavingsSource.ZeroAddress.selector);
        new SavingsSource(cards, IEarnVault(address(earnVault)), address(0));
        vm.expectRevert(SavingsSource.ZeroAddress.selector);
        new SavingsSource(cards, IEarnVault(address(0)), funder);
        vm.expectRevert(SavingsSource.ZeroAddress.selector);
        new SavingsSource(CardAuth(address(0)), IEarnVault(address(earnVault)), funder);
    }

    /// @dev While captures defer, a new leg holds only what the float can still pay past earlier promises, a leg
    ///      placed before the deferral cannot grow, and every promised capture is paid from the float.
    function test_hold_duringDeferral_cappedAtTheFloat() public {
        _thinFloat(100e6);
        _place(ID, 300e6);
        _startDeferral(ID, 30e6);
        (bool active, uint8 epoch, uint128 promised) = savings.deferral();
        assertTrue(active);
        assertEq(epoch, 1);
        assertEq(promised, 0);
        uint256 floatLeft = usd.balanceOf(address(savings));
        assertApproxEqAbs(floatLeft, 70e6, 1);
        // The earlier leg keeps what it holds and grows no further.
        uint256 before = _leg(ID).held;
        assertEq(_place(ID, 400e6), earnVault.previewRedeem(before));
        assertEq(_leg(ID).held, before);
        // A new leg holds what the float pays for, its tolerance included.
        uint256 got = _place(ID2, 500e6);
        uint256 limit = _leg(ID2).captureLimit;
        assertLe(earnVault.previewRedeem(limit), floatLeft);
        assertGt(got, 50e6);
        (,, promised) = savings.deferral();
        assertEq(promised, _leg(ID2).captureLimit);
        (,,, uint8 promisedIn) = savings.legs(ID2);
        assertEq(promisedIn, 1);
        // A third leg finds nothing left.
        assertEq(_place(bytes32("leg-3"), 10e6), 0);
        // The promised leg captures in full from the float, up to its capture limit.
        vm.prank(address(cards));
        (uint256 paid,) = savings.capture(alice, bytes32(0), ID2, got * 2, CAPTURE_FREE | CAPTURE_FINAL);
        assertEq(paid, earnVault.previewRedeem(limit));
        (,, promised) = savings.deferral();
        assertEq(promised, 0);
        _assertCoreBalanced();
    }

    /// @dev With a capture tolerance, a new leg's hold leaves room for its capture limit within the float, and a
    ///      capture past the hold up to that limit is paid from the float.
    function test_hold_duringDeferral_floatCoversTheCaptureLimit() public {
        _setTolerance(alice, address(savings), address(earnShare), 2000);
        _thinFloat(100e6);
        _place(ID, 300e6);
        _startDeferral(ID, 30e6);
        uint256 floatLeft = usd.balanceOf(address(savings));
        uint256 got = _place(ID2, 500e6);
        uint256 limit = _leg(ID2).captureLimit;
        assertEq(limit, _leg(ID2).held * 12 / 10);
        assertLe(earnVault.previewRedeem(limit), floatLeft);
        assertGt(earnVault.previewRedeem(limit), floatLeft - 3);
        vm.prank(address(cards));
        (uint256 paid,) = savings.capture(alice, bytes32(0), ID2, got * 12 / 10, CAPTURE_FREE | CAPTURE_FINAL);
        assertApproxEqAbs(paid, got * 12 / 10, 2);
        _assertCoreBalanced();
    }

    /// @dev While captures defer, a leg without a promise captures only the float the promises leave and leaves
    ///      the rest to the order's later entries, rather than reverting.
    function test_capture_duringDeferral_unpromisedLegTakesWhatTheFloatLeaves() public {
        _thinFloat(100e6);
        _place(ID, 300e6);
        _startDeferral(ID, 30e6);
        uint256 got = _place(ID2, 40e6);
        assertEq(got, 40e6);
        (,, uint128 promised) = savings.deferral();
        uint256 owed = earnVault.previewRedeem(promised);
        uint256 floatLeft = usd.balanceOf(address(savings));
        vm.prank(address(cards));
        (uint256 paid,) = savings.capture(alice, bytes32(0), ID, 270e6, CAPTURE_FINAL);
        assertLe(paid, floatLeft - owed);
        assertGt(paid, floatLeft - owed - 2);
        assertEq(_leg(ID).token, address(0));
        // The promise survives: the promised leg still captures in full.
        vm.prank(address(cards));
        (paid,) = savings.capture(alice, bytes32(0), ID2, 40e6, CAPTURE_FINAL);
        assertEq(paid, 40e6);
        _assertCoreBalanced();
    }

    /// @dev A release or a partial capture gives the promise back; holds return to normal once a redemption works.
    function test_deferral_promisesFollowTheLegAndEndOnARedemption() public {
        _thinFloat(100e6);
        _place(ID, 300e6);
        _startDeferral(ID, 30e6);
        _place(ID2, 40e6);
        uint256 limit = _leg(ID2).captureLimit;
        (,, uint128 promised) = savings.deferral();
        assertEq(promised, limit);
        vm.prank(address(cards));
        savings.capture(alice, bytes32(0), ID2, 10e6, 0);
        (,, promised) = savings.deferral();
        assertEq(promised, _leg(ID2).captureLimit);
        assertLt(promised, limit);
        vm.prank(address(cards));
        savings.release(alice, bytes32(0), ID2);
        (,, promised) = savings.deferral();
        assertEq(promised, 0);
        // The venue redeems again: the funder's redemption ends the deferral.
        vm.clearMockedCalls();
        uint256 held = savings.heldShares();
        vm.prank(funder);
        savings.redeemHeld(held, 1);
        (bool active, uint8 epoch,) = savings.deferral();
        assertFalse(active);
        assertEq(epoch, 1);
        assertEq(_place(bytes32("leg-3"), 500e6), 500e6);
        // A leg promised in the ended deferral is not promised in the next one.
        _startDeferral(bytes32("leg-3"), 10e6);
        (active, epoch, promised) = savings.deferral();
        assertTrue(active);
        assertEq(epoch, 2);
        assertEq(promised, 0);
        _assertCoreBalanced();
    }

    /// @dev A capture that the venue redeems ends a deferral on its own.
    function test_deferral_endsWhenACaptureRedeems() public {
        _thinFloat(100e6);
        _place(ID, 300e6);
        _startDeferral(ID, 30e6);
        vm.clearMockedCalls();
        vm.prank(address(cards));
        (uint256 paid,) = savings.capture(alice, bytes32(0), ID, 50e6, 0);
        assertEq(paid, 50e6);
        (bool active,,) = savings.deferral();
        assertFalse(active);
        assertEq(_place(ID2, 500e6), 500e6);
    }

    /// @dev Leaves `amount` of float in the source.
    function _thinFloat(uint256 amount) internal {
        vm.prank(funder);
        savings.withdraw(address(usd), funder, FLOAT - amount);
    }

    /// @dev Makes the vault refuse every redemption to the settlement account, then defers a capture of `units` on
    ///      leg `id`.
    function _startDeferral(bytes32 id, uint256 units) internal {
        vm.mockCallRevert(
            address(earnVault), abi.encodePacked(bytes4(keccak256("redeem(uint256,address,uint256)"))), "illiquid"
        );
        vm.prank(address(cards));
        (uint256 paid,) = savings.capture(alice, bytes32(0), id, units, 0);
        assertEq(paid, units);
    }

    function _place(bytes32 id, uint256 units) internal returns (uint256) {
        vm.prank(address(cards));
        return savings.hold(alice, bytes32(0), id, units, _expiry());
    }

    function _leg(bytes32 id) internal view returns (IReservationCore.HoldRecord memory) {
        return core.getHold(alice, address(savings), id);
    }

    /// @dev The slot of leg `id` in the source's `legs` mapping (storage slot 1).
    function _legSlot(bytes32 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, uint256(1)));
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 1 days);
    }

    function _issueSavingsOnly() internal {
        vm.prank(issuer);
        cards.issueCard(CARD, alice, uint40(block.timestamp + 365 days), _limits(5000e6, 10_000e6, 50_000e6), 2);
        vm.startPrank(alice);
        _setFunding(false, true, false);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        vm.stopPrank();
    }
}
