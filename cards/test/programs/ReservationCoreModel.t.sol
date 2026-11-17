// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IReservationCore, MAX_PLEDGE_DURATION } from "../../src/programs/interfaces/IReservationCore.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice The reservation core's rules as the test model keeps them: the semantics card programs are built on.
contract ReservationCoreModelTest is ProgramsEnv {
    address internal holder = makeAddr("holder");
    address internal payee = makeAddr("payee");
    address internal authority = makeAddr("authority");
    bytes32 internal constant ID = bytes32("hold-1");

    function setUp() public {
        _deployPrograms();
        usd.mint(alice, 1000e6);
    }

    function _request(uint128 amount, bool standIn) internal view returns (IReservationCore.HoldRequest memory) {
        return IReservationCore.HoldRequest({
            token: address(usd),
            id: ID,
            amount: amount,
            expiresAt: uint64(block.timestamp + 1 days),
            payee: payee,
            standIn: standIn
        });
    }

    function _approve(uint128 allowance) internal {
        vm.prank(alice);
        core.approveHolder(holder, address(usd), allowance);
    }

    function test_hold_reservesOutOfBalance() public {
        vm.prank(alice);
        core.hold(_request(300e6, false));
        assertEq(usd.balanceOf(alice), 700e6);
        assertEq(core.reserved(alice, address(usd)), 300e6);
        assertEq(core.available(alice, address(usd)), 700e6);
        IReservationCore.HoldRecord memory h = core.getHold(alice, ID);
        assertEq(h.placer, alice);
        assertEq(h.held, 300e6);
        assertEq(h.approved, 300e6);
        _assertCoreBalanced();
    }

    function test_hold_rules() public {
        // The model moves tokens with single pranks, so tests prank each call rather than holding a prank open.
        vm.prank(alice);
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        core.hold(_request(2000e6, false));
        IReservationCore.HoldRequest memory r = _request(1e6, false);
        r.expiresAt = uint64(block.timestamp + 32 days);
        vm.prank(alice);
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.hold(r);
        r.expiresAt = uint64(block.timestamp);
        vm.prank(alice);
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.hold(r);
        vm.prank(alice);
        core.hold(_request(1e6, false));
        vm.prank(alice);
        vm.expectRevert(IReservationCore.HoldExists.selector);
        core.hold(_request(1e6, false));
    }

    function test_holdFrom_needsAllowanceAndBoundsOutstanding() public {
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.holdFrom(alice, _request(100e6, false));

        _approve(150e6);
        vm.prank(holder);
        core.holdFrom(alice, _request(100e6, false));
        (uint128 allowed, uint128 outstanding) = core.allowance(alice, holder, address(usd));
        assertEq(allowed, 150e6);
        assertEq(outstanding, 100e6);

        IReservationCore.HoldRequest memory r = _request(60e6, false);
        r.id = bytes32("hold-2");
        vm.prank(holder);
        vm.expectRevert(IReservationCore.AllowanceExceeded.selector);
        core.holdFrom(alice, r);

        // A capture frees outstanding allowance.
        vm.prank(holder);
        core.capture(alice, ID, 100e6, true);
        (, outstanding) = core.allowance(alice, holder, address(usd));
        assertEq(outstanding, 0);
        vm.prank(holder);
        core.holdFrom(alice, r);
        _assertCoreBalanced();
    }

    function test_revokedHolder_liveHoldsStillSettle() public {
        _approve(500e6);
        vm.prank(holder);
        core.holdFrom(alice, _request(200e6, false));
        _approve(0);

        IReservationCore.HoldRequest memory r = _request(1e6, false);
        r.id = bytes32("hold-2");
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.holdFrom(alice, r);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.adjust(alice, ID, 300e6);

        vm.prank(holder);
        core.capture(alice, ID, 150e6, true);
        assertEq(usd.balanceOf(payee), 150e6);
        vm.prank(payee);
        core.refund(alice, ID, 50e6);
        // 200 held, 150 captured, 50 released, then 50 refunded.
        assertEq(usd.balanceOf(alice), 900e6);
        _assertCoreBalanced();
    }

    function test_roles() public {
        _approve(500e6);
        vm.prank(holder);
        core.holdFrom(alice, _request(200e6, false));
        // Only the placer adjusts.
        vm.prank(payee);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.adjust(alice, ID, 100e6);
        // A stranger neither captures nor releases.
        vm.prank(bob);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.capture(alice, ID, 1e6, false);
        vm.prank(bob);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.release(alice, ID);
        // The payee captures; only the payee refunds.
        vm.prank(payee);
        core.capture(alice, ID, 50e6, false);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.refund(alice, ID, 1e6);
        vm.prank(payee);
        vm.expectRevert(IReservationCore.RefundExceedsCapture.selector);
        core.refund(alice, ID, 51e6);
    }

    function test_adjust_setsHeld() public {
        _approve(500e6);
        vm.prank(holder);
        core.holdFrom(alice, _request(200e6, false));
        vm.prank(holder);
        core.adjust(alice, ID, 350e6);
        assertEq(core.getHold(alice, ID).held, 350e6);
        assertEq(core.getHold(alice, ID).approved, 350e6);
        vm.prank(holder);
        core.adjust(alice, ID, 100e6);
        assertEq(core.reserved(alice, address(usd)), 100e6);
        (, uint128 outstanding) = core.allowance(alice, holder, address(usd));
        assertEq(outstanding, 100e6);
        _assertCoreBalanced();
    }

    function test_hardExpiry() public {
        _approve(500e6);
        vm.prank(holder);
        core.holdFrom(alice, _request(200e6, false));
        vm.expectRevert(IReservationCore.HoldNotExpired.selector);
        core.releaseExpired(alice, ID);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.HoldExpired.selector);
        core.capture(alice, ID, 1e6, false);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.HoldExpired.selector);
        core.adjust(alice, ID, 300e6);

        vm.prank(bob);
        core.releaseExpired(alice, ID);
        assertEq(usd.balanceOf(alice), 1000e6);
        assertTrue(core.getHold(alice, ID).settled);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.HoldSettled.selector);
        core.release(alice, ID);
        _assertCoreBalanced();
    }

    function test_overCapture_needsToleranceAndDebtCap() public {
        vm.prank(alice);
        core.hold(_request(100e6, false));
        vm.prank(payee);
        vm.expectRevert(IReservationCore.ToleranceExceeded.selector);
        core.capture(alice, ID, 101e6, false);

        vm.prank(alice);
        core.setCaptureTolerance(payee, address(usd), 2000);
        vm.prank(payee);
        core.capture(alice, ID, 120e6, true);
        assertEq(usd.balanceOf(payee), 120e6);
        assertEq(usd.balanceOf(alice), 880e6);
        _assertCoreBalanced();
    }

    function test_standIn_reservesAvailableAndCapsDebt() public {
        address poor = makeAddr("poor");
        usd.mint(poor, 50e6);
        IReservationCore.HoldRequest memory r = _request(80e6, true);
        vm.prank(poor);
        core.hold(r);
        IReservationCore.HoldRecord memory h = core.getHold(poor, ID);
        assertEq(h.held, 50e6);
        assertEq(h.approved, 80e6);

        // The shortfall becomes debt only within max(debt cap, offline cap).
        vm.prank(payee);
        vm.expectRevert(IReservationCore.DebtCapExceeded.selector);
        core.capture(poor, ID, 80e6, true);
        vm.prank(poor);
        core.setOfflineCap(payee, address(usd), 30e6);
        vm.prank(payee);
        core.capture(poor, ID, 80e6, true);
        (address creditor, uint128 debt) = core.debtOf(poor, address(usd));
        assertEq(creditor, payee);
        assertEq(debt, 30e6);

        // Incoming credits repay the debt first.
        usd.mint(poor, 40e6);
        core.repay(poor, address(usd));
        (, debt) = core.debtOf(poor, address(usd));
        assertEq(debt, 0);
        assertEq(usd.balanceOf(payee), 80e6);
        assertEq(usd.balanceOf(poor), 10e6);
    }

    function test_charge_paysAndRecordsASettledId() public {
        _approve(100e6);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.AllowanceExceeded.selector);
        core.charge(alice, address(usd), ID, 101e6, payee, false);
        vm.prank(holder);
        core.charge(alice, address(usd), ID, 100e6, payee, false);
        assertEq(usd.balanceOf(payee), 100e6);
        IReservationCore.HoldRecord memory h = core.getHold(alice, ID);
        assertTrue(h.settled);
        assertEq(h.captured, 100e6);
        // A charge keeps nothing outstanding.
        (, uint128 outstanding) = core.allowance(alice, holder, address(usd));
        assertEq(outstanding, 0);
        vm.prank(alice);
        vm.expectRevert(IReservationCore.HoldExists.selector);
        core.hold(_request(1e6, false));
    }

    function test_roleLien() public {
        vm.prank(authority);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.lien(alice, address(usd), ID, 100e6, 0);
        core.grantLienRole(authority, true);
        vm.prank(authority);
        core.lien(alice, address(usd), ID, 100e6, 0);
        assertEq(core.liened(alice, address(usd)), 100e6);
        assertEq(core.reserved(alice, address(usd)), 100e6);
        vm.expectRevert(IReservationCore.LienNotExpired.selector);
        core.releaseExpiredLien(authority, ID);

        // A role lien's seizure still needs the role.
        core.grantLienRole(authority, false);
        vm.prank(authority);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.seizeLien(ID, 10e6);
        core.grantLienRole(authority, true);
        vm.prank(authority);
        core.seizeLien(ID, 40e6);
        assertEq(usd.balanceOf(authority), 40e6);
        vm.prank(authority);
        core.reduceLien(ID, 10e6);
        (,, uint128 amount,,) = core.lienOf(authority, ID);
        assertEq(amount, 50e6);
        vm.prank(authority);
        core.releaseLien(ID);
        assertEq(usd.balanceOf(alice), 960e6);
        assertEq(core.reserved(alice, address(usd)), 0);
        _assertCoreBalanced();
    }

    function test_pledge_expiresAndOnlyAuthoritySeizes() public {
        vm.prank(alice);
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.pledge(authority, address(usd), ID, 100e6, 0);
        vm.prank(alice);
        core.pledge(authority, address(usd), ID, 100e6, uint64(block.timestamp + 10 days));
        (address owner,,,, bool pledged) = core.lienOf(authority, ID);
        assertEq(owner, alice);
        assertTrue(pledged);
        vm.prank(bob);
        vm.expectRevert(IReservationCore.LienNotFound.selector);
        core.seizeLien(ID, 1e6);

        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(authority);
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.seizeLien(ID, 1e6);
        vm.prank(bob);
        core.releaseExpiredLien(authority, ID);
        assertEq(usd.balanceOf(alice), 1000e6);
        _assertCoreBalanced();
    }

    function test_pledgeFrom_drawsAllowanceAndBoundsExpiry() public {
        uint64 expiry = uint64(block.timestamp + 90 days);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.pledgeFrom(alice, address(usd), ID, 100e6, expiry);

        _approve(150e6);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.pledgeFrom(alice, address(usd), ID, 100e6, uint64(block.timestamp));
        vm.prank(holder);
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.pledgeFrom(alice, address(usd), ID, 100e6, uint64(block.timestamp + MAX_PLEDGE_DURATION + 1));
        vm.prank(holder);
        core.pledgeFrom(alice, address(usd), ID, 100e6, uint64(block.timestamp + MAX_PLEDGE_DURATION));
        vm.prank(holder);
        vm.expectRevert(IReservationCore.AllowanceExceeded.selector);
        core.pledgeFrom(alice, address(usd), bytes32("lien-2"), 60e6, expiry);

        (address owner,, uint128 amount,, bool pledged) = core.lienOf(holder, ID);
        assertEq(owner, alice);
        assertEq(amount, 100e6);
        assertTrue(pledged);
        (, uint128 outstanding) = core.allowance(alice, holder, address(usd));
        assertEq(outstanding, 100e6);
        assertEq(usd.balanceOf(alice), 900e6);

        // Reducing and seizing give the freed amount back to the allowance; only the holder seizes, to itself.
        vm.prank(holder);
        core.reduceLien(ID, 30e6);
        vm.prank(holder);
        core.seizeLien(ID, 20e6);
        (, outstanding) = core.allowance(alice, holder, address(usd));
        assertEq(outstanding, 50e6);
        assertEq(usd.balanceOf(holder), 20e6);
        assertEq(usd.balanceOf(alice), 930e6);
        _assertCoreBalanced();
    }

    function test_pledgeFrom_revokedHolderStillReleasesAndExpiredNeedsRelease() public {
        _approve(500e6);
        vm.prank(holder);
        core.pledgeFrom(alice, address(usd), ID, 200e6, uint64(block.timestamp + 10 days));
        vm.prank(holder);
        core.pledgeFrom(alice, address(usd), bytes32("lien-2"), 100e6, uint64(block.timestamp + 20 days));
        _approve(0);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.pledgeFrom(alice, address(usd), bytes32("lien-3"), 1e6, uint64(block.timestamp + 10 days));

        vm.prank(holder);
        core.releaseLien(bytes32("lien-2"));
        vm.warp(vm.getBlockTimestamp() + 10 days);
        // An expired pledge stays reserved until someone releases it.
        assertEq(core.liened(alice, address(usd)), 200e6);
        vm.prank(bob);
        core.releaseExpiredLien(holder, ID);
        (, uint128 outstanding) = core.allowance(alice, holder, address(usd));
        assertEq(outstanding, 0);
        assertEq(usd.balanceOf(alice), 1000e6);
        _assertCoreBalanced();
    }

    /// @dev Any sequence of holds, captures, refunds and releases keeps balance plus reserved equal to what the
    ///      owner and payees hold, and a settled id never reopens.
    function testFuzz_accountingHolds(uint128 amount, uint128 captured, uint128 refunded, bool isFinal) public {
        amount = uint128(bound(amount, 1, 1000e6));
        captured = uint128(bound(captured, 1, amount));
        refunded = uint128(bound(refunded, 0, captured));
        _approve(type(uint128).max);
        vm.prank(holder);
        core.holdFrom(alice, _request(amount, false));
        vm.prank(holder);
        core.capture(alice, ID, captured, isFinal);
        if (refunded != 0) {
            vm.prank(payee);
            core.refund(alice, ID, refunded);
        }
        if (!isFinal) {
            vm.prank(holder);
            core.release(alice, ID);
        }
        IReservationCore.HoldRecord memory h = core.getHold(alice, ID);
        assertTrue(h.settled);
        assertEq(h.held, 0);
        assertLe(h.refunded, h.captured);
        assertEq(usd.balanceOf(alice) + core.reserved(alice, address(usd)) + usd.balanceOf(payee), 1000e6);
        assertEq(usd.balanceOf(payee), captured - refunded);
        (, uint128 outstanding) = core.allowance(alice, holder, address(usd));
        assertEq(outstanding, 0);
        _assertCoreBalanced();
        vm.prank(holder);
        vm.expectRevert(IReservationCore.HoldSettled.selector);
        core.capture(alice, ID, 1, false);
    }
}
