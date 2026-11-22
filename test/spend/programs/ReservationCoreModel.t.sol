// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import {
    IReservationCore,
    KIND_HOLD,
    KIND_LIEN,
    KIND_PLEDGE,
    MAX_HOLD_DURATION,
    MAX_PLEDGE_DURATION,
    RESERVATION_CORE_ADDRESS
} from "../../../src/interfaces/spend/programs/IReservationCore.sol";
import { ModelEnv } from "./differential/ModelEnv.sol";

/// @notice The reservation core rules the programs rely on, as MockReservationCore models them. The differential test
///         (differential/Differential.t.sol) checks the model against the node.
contract ReservationCoreModelTest is ModelEnv {
    ITIP20Token internal usd;
    ITIP20Token internal eur;
    address internal owner = makeAddr("owner");
    address internal holder = makeAddr("holder");
    address internal payee = makeAddr("payee");
    address internal stranger = makeAddr("stranger");
    address internal u;

    function setUp() public {
        vm.warp(1_800_000_000);
        _deployModel();
        usd = _token("USD1");
        eur = _token("EUR1");
        u = address(usd);
        _mint(usd, owner, 1000);
    }

    // Records.

    function test_holdReservesUnderOwnerPlacerAndId() public {
        _hold(owner, "a", 400);
        assertEq(core.reserved(owner, u), 400);
        assertEq(core.available(owner, u), 600);
        IReservationCore.HoldRecord memory r = core.getHold(owner, owner, "a");
        assertEq(r.token, u);
        assertEq(r.payee, payee);
        assertEq(r.held, 400);
        assertEq(r.captureLimit, 400);
        assertEq(r.kind, KIND_HOLD);
        // Another placer may use the same id.
        _approve(1000, 0);
        vm.prank(holder);
        core.holdFrom(owner, _request(u, "a", 100, payee, 60));
        assertEq(core.reserved(owner, u), 500);
    }

    function test_idReusableOnlyAfterSettlementDeletesIt() public {
        _hold(owner, "a", 100);
        vm.expectRevert(IReservationCore.HoldExists.selector);
        _hold(owner, "a", 100);
        vm.prank(owner);
        core.capture(owner, owner, "a", 50, false);
        vm.expectRevert(IReservationCore.HoldExists.selector);
        _hold(owner, "a", 100);
        vm.prank(owner);
        core.capture(owner, owner, "a", 0, true);
        assertEq(core.getHold(owner, owner, "a").token, address(0));
        _hold(owner, "a", 100);
    }

    function test_amountBounds() public {
        vm.expectRevert(IReservationCore.InvalidAmount.selector);
        _hold(owner, "a", 0);
        vm.prank(owner);
        vm.expectRevert(IReservationCore.InvalidAmount.selector);
        core.hold(_request(u, "a", uint128(type(uint64).max) + 1, payee, 60));
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        _hold(owner, "a", 1001);
    }

    function test_holdExpiryBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.hold(_request(u, "a", 1, payee, 0));
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.hold(_request(u, "a", 1, payee, MAX_HOLD_DURATION + 1));
        core.hold(_request(u, "a", 1, payee, MAX_HOLD_DURATION));
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.pledge(payee, u, "p", 1, _now() + MAX_PLEDGE_DURATION + 1);
        core.pledge(payee, u, "p", 1, _now() + MAX_PLEDGE_DURATION);
        vm.stopPrank();
    }

    // Capture, release, adjust.

    function test_captureByPlacerOrPayeeOnly() public {
        _hold(owner, "a", 400);
        vm.prank(stranger);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.capture(owner, owner, "a", 1, false);
        vm.prank(payee);
        core.capture(owner, owner, "a", 100, false);
        assertEq(usd.balanceOf(payee), 100);
        assertEq(core.getHold(owner, owner, "a").held, 300);
        assertEq(core.getHold(owner, owner, "a").captureLimit, 300);
        vm.prank(owner);
        core.capture(owner, owner, "a", 100, true);
        assertEq(core.reserved(owner, u), 0);
        assertEq(core.available(owner, u), 800);
        assertEq(core.getHold(owner, owner, "a").token, address(0));
    }

    function test_toleranceFixedAtPlacementAllowsCapturePastHeld() public {
        _tolerance(1500);
        _hold(owner, "a", 100);
        _tolerance(0);
        assertEq(core.getHold(owner, owner, "a").captureLimit, 115);
        vm.prank(owner);
        vm.expectRevert(IReservationCore.CaptureLimitExceeded.selector);
        core.capture(owner, owner, "a", 116, true);
        vm.prank(owner);
        core.capture(owner, owner, "a", 115, true);
        assertEq(usd.balanceOf(payee), 115);
        assertEq(core.available(owner, u), 885);
    }

    function test_releaseByPlacerOrPayeeAndExpiry() public {
        _hold(owner, "a", 400);
        vm.prank(stranger);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.release(owner, owner, "a");
        vm.prank(stranger);
        vm.expectRevert(IReservationCore.HoldNotExpired.selector);
        core.releaseExpired(owner, owner, "a");
        vm.warp(_now() + 60);
        vm.prank(owner);
        vm.expectRevert(IReservationCore.HoldExpired.selector);
        core.capture(owner, owner, "a", 1, true);
        vm.prank(stranger);
        core.releaseExpired(owner, owner, "a");
        assertEq(core.reserved(owner, u), 0);
        vm.expectRevert(IReservationCore.HoldNotFound.selector);
        core.release(owner, owner, "a");
    }

    function test_adjustHold() public {
        _tolerance(1000);
        _hold(owner, "a", 100);
        vm.prank(payee);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.adjust(owner, owner, "a", 200);
        vm.startPrank(owner);
        core.adjust(owner, owner, "a", 200);
        assertEq(core.getHold(owner, owner, "a").captureLimit, 220);
        core.adjust(owner, owner, "a", 50);
        // Lowering a hold keeps its capture limit.
        assertEq(core.getHold(owner, owner, "a").captureLimit, 220);
        assertEq(core.reserved(owner, u), 50);
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        core.adjust(owner, owner, "a", 1001);
        vm.stopPrank();
    }

    // Pledges and liens.

    function test_pledgeSettledOnlyByAuthority() public {
        vm.prank(owner);
        core.pledge(payee, u, "p", 300, _now() + 1 days);
        assertEq(core.getHold(owner, owner, "p").kind, KIND_PLEDGE);
        vm.startPrank(owner);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.release(owner, owner, "p");
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.capture(owner, owner, "p", 1, false);
        vm.stopPrank();
        vm.startPrank(payee);
        vm.expectRevert(IReservationCore.InvalidAmount.selector);
        core.adjust(owner, owner, "p", 301);
        core.adjust(owner, owner, "p", 200);
        assertEq(core.getHold(owner, owner, "p").captureLimit, 200);
        core.capture(owner, owner, "p", 150, false);
        assertEq(core.getHold(owner, owner, "p").held, 50);
        core.capture(owner, owner, "p", 50, false);
        // A pledge captured down to zero settles.
        assertEq(core.getHold(owner, owner, "p").token, address(0));
        vm.stopPrank();
        assertEq(usd.balanceOf(payee), 200);
    }

    function test_pledgeFromDrawsTheAuthorityBudget() public {
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.pledgeFrom(owner, u, "p", 100, _now() + 1 days);
        _approve(150, 0);
        vm.prank(holder);
        core.pledgeFrom(owner, u, "p", 100, _now() + 1 days);
        assertEq(core.budget(owner, holder, u).outstanding, 100);
        assertEq(core.getHold(owner, holder, "p").payee, holder);
    }

    function test_lienNeedsTheTokenRoleAndPaysPastSenderPolicy() public {
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.lien(owner, u, "l", 100, 0);
        usd.grantRole(core.LIEN_ROLE(), holder);
        vm.prank(holder);
        core.lien(owner, u, "l", 100, 0);
        IReservationCore.HoldRecord memory r = core.getHold(owner, holder, "l");
        assertEq(r.kind, KIND_LIEN);
        assertEq(r.expiresAt, 0);
        // A frozen owner's lien can still be seized.
        uint64 policy = _blacklistPolicy(usd);
        registry.modifyPolicyBlacklist(policy, owner, true);
        vm.prank(holder);
        core.capture(owner, holder, "l", 40, false);
        assertEq(usd.balanceOf(holder), 40);
        usd.revokeRole(core.LIEN_ROLE(), holder);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.capture(owner, holder, "l", 10, false);
        // Liens never draw a budget.
        assertEq(core.budget(owner, holder, u).outstanding, 0);
    }

    function test_lienExpiry() public {
        usd.grantRole(core.LIEN_ROLE(), holder);
        vm.startPrank(holder);
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.lien(owner, u, "l", 1, _now());
        core.lien(owner, u, "l", 1, _now() + 500 days);
        vm.stopPrank();
    }

    // Budgets.

    function test_budgetLimitsHolderHoldsAndCharges() public {
        _approve(500, 0);
        vm.startPrank(holder);
        core.holdFrom(owner, _request(u, "a", 300, payee, 60));
        vm.expectRevert(IReservationCore.BudgetExceeded.selector);
        core.holdFrom(owner, _request(u, "b", 201, payee, 60));
        core.capture(owner, holder, "a", 100, true);
        vm.stopPrank();
        IReservationCore.Budget memory b = core.budget(owner, holder, u);
        assertEq(b.spent, 100);
        assertEq(b.outstanding, 0);
        // Spent stays spent for the period; released amounts return.
        vm.prank(holder);
        vm.expectRevert(IReservationCore.BudgetExceeded.selector);
        core.charge(owner, u, "c", 401, payee);
        vm.prank(holder);
        core.charge(owner, u, "c", 400, payee);
        assertEq(core.budget(owner, holder, u).spent, 500);
    }

    function test_budgetPeriodResetsSpent() public {
        _approve(100, 1 days);
        vm.prank(holder);
        core.charge(owner, u, "c", 100, payee);
        uint64 start = core.budget(owner, holder, u).periodStart;
        vm.warp(start + 1 days - 1);
        assertEq(core.budget(owner, holder, u).spent, 100);
        vm.warp(start + 3 days + 5);
        IReservationCore.Budget memory b = core.budget(owner, holder, u);
        assertEq(b.spent, 0);
        assertEq(b.periodStart, start + 3 days);
        vm.prank(holder);
        core.charge(owner, u, "c", 100, payee);
    }

    function test_zeroLimitRevokesNewUseWhileExistingSettle() public {
        _approve(type(uint128).max, 0);
        assertEq(core.budget(owner, holder, u).limit, type(uint64).max);
        vm.prank(holder);
        core.holdFrom(owner, _request(u, "a", 300, payee, 60));
        _approve(0, 0);
        vm.startPrank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.charge(owner, u, "c", 1, payee);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.holdFrom(owner, _request(u, "b", 1, payee, 60));
        core.capture(owner, holder, "a", 300, true);
        vm.stopPrank();
        assertEq(usd.balanceOf(payee), 300);
    }

    function test_approveHolderChecks() public {
        vm.startPrank(owner);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.approveHolder(owner, u, 1, 0);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.approveHolder(address(0), u, 1, 0);
        vm.expectRevert(MockReservationCoreErrors.InvalidToken.selector);
        core.approveHolder(holder, stranger, 1, 0);
        vm.stopPrank();
    }

    function test_setCaptureToleranceChecks() public {
        vm.startPrank(owner);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.setCaptureTolerance(owner, u, 100);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.setCaptureTolerance(address(0), u, 100);
        vm.expectRevert(MockReservationCoreErrors.InvalidToken.selector);
        core.setCaptureTolerance(payee, stranger, 100);
        vm.expectEmit(true, true, true, true, RESERVATION_CORE_ADDRESS);
        emit IReservationCore.CaptureToleranceSet(owner, payee, u, 2500);
        core.setCaptureTolerance(payee, u, 2500);
        vm.stopPrank();
        assertEq(core.captureTolerance(owner, payee, u), 2500);
        assertEq(core.captureTolerance(payee, owner, u), 0);
        // A new hold takes it; a live hold keeps the one it was placed with.
        _hold(owner, "a", 100);
        assertEq(core.getHold(owner, owner, "a").captureLimit, 125);
    }

    // Payments beyond what a hold backs.

    function test_captureBeyondHeldPaysOnlyFromTheFreeBalance() public {
        _tolerance(5000);
        _hold(owner, "a", 100);
        vm.prank(owner);
        usd.transfer(stranger, 880);
        assertEq(core.available(owner, u), 20);
        // Past the hold by more than is free: nothing is paid and the hold stays as it was.
        vm.prank(owner);
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        core.capture(owner, owner, "a", 121, true);
        assertEq(core.getHold(owner, owner, "a").held, 100);
        assertEq(core.getHold(owner, owner, "a").captureLimit, 150);
        assertEq(usd.balanceOf(payee), 0);
        // Within what is free it pays the hold and the free part.
        vm.expectEmit(true, true, true, true, RESERVATION_CORE_ADDRESS);
        emit IReservationCore.HoldCaptured(owner, owner, u, "a", payee, 120, true);
        vm.prank(owner);
        core.capture(owner, owner, "a", 120, true);
        assertEq(usd.balanceOf(payee), 120);
        assertEq(core.available(owner, u), 0);
        assertEq(core.reserved(owner, u), 0);
    }

    function test_captureBeyondHeld_budgetCheckedBeforeTheBalance() public {
        _tolerance(5000);
        _approve(110, 0);
        vm.prank(holder);
        core.holdFrom(owner, _request(u, "a", 100, payee, 60));
        vm.prank(owner);
        usd.transfer(stranger, 900);
        // 20 past the hold: the budget refuses before the empty balance does.
        vm.prank(holder);
        vm.expectRevert(IReservationCore.BudgetExceeded.selector);
        core.capture(owner, holder, "a", 120, true);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        core.capture(owner, holder, "a", 110, true);
    }

    function test_chargePaysOnlyFromTheFreeBalance_inTheNodesOrder() public {
        _hold(owner, "h", 900);
        // Unapproved, past the budget, then blocked, then short of the free balance.
        vm.prank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.charge(owner, u, "c", 200, payee);
        _approve(150, 0);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.BudgetExceeded.selector);
        core.charge(owner, u, "c", 200, payee);
        uint64 policy = _blacklistPolicy(usd);
        registry.modifyPolicyBlacklist(policy, payee, true);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.PolicyForbids.selector);
        core.charge(owner, u, "c", 101, payee);
        registry.modifyPolicyBlacklist(policy, payee, false);
        vm.prank(holder);
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        core.charge(owner, u, "c", 101, payee);
        vm.expectEmit(true, true, true, true, RESERVATION_CORE_ADDRESS);
        emit IReservationCore.Charged(owner, holder, u, "c", payee, 100);
        vm.prank(holder);
        core.charge(owner, u, "c", 100, payee);
        assertEq(usd.balanceOf(payee), 100);
        assertEq(core.reserved(owner, u), 900, "the hold is untouched");
        // The owner charging itself is held to the same free balance.
        vm.prank(owner);
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        core.charge(owner, u, "d", 1, payee);
    }

    // Refunds.

    function test_refundIsPaidWhollyByTheCaller() public {
        vm.prank(owner);
        core.charge(owner, u, "c", 1000, payee);
        vm.prank(payee);
        vm.expectRevert(IReservationCore.InvalidAmount.selector);
        core.refund(owner, u, owner, "c", 0);
        vm.prank(payee);
        vm.expectEmit(true, true, true, true, RESERVATION_CORE_ADDRESS);
        emit IReservationCore.Refunded(owner, payee, u, owner, "c", 150);
        core.refund(owner, u, owner, "c", 150);
        assertEq(usd.balanceOf(payee), 850);
        assertEq(core.available(owner, u), 150);
        // Refunds are unbounded by what was paid, but need the caller's available balance.
        vm.prank(payee);
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        core.refund(owner, u, owner, "c", 851);
        // A blocked recipient refuses before the balance is read.
        uint64 policy = _blacklistPolicy(usd);
        registry.modifyPolicyBlacklist(policy, owner, true);
        vm.prank(payee);
        vm.expectRevert(IReservationCore.PolicyForbids.selector);
        core.refund(owner, u, owner, "c", 851);
    }

    function test_creditsMoveNothingOnward() public {
        _mint(usd, owner, 30);
        _send(usd, owner, holder, 10);
        assertEq(core.available(owner, u), 1020);
        assertEq(usd.balanceOf(holder), 10);
        assertEq(usd.balanceOf(payee), 0);
    }

    // Policy.

    function test_pauseAndBlacklistBlockPayments() public {
        usd.pause();
        vm.expectRevert(IReservationCore.PolicyForbids.selector);
        _hold(owner, "a", 1);
        usd.unpause();
        _hold(owner, "a", 100);
        uint64 policy = _blacklistPolicy(usd);
        registry.modifyPolicyBlacklist(policy, payee, true);
        vm.prank(owner);
        vm.expectRevert(IReservationCore.PolicyForbids.selector);
        core.capture(owner, owner, "a", 10, false);
        registry.modifyPolicyBlacklist(policy, payee, false);
        registry.modifyPolicyBlacklist(policy, owner, true);
        // A capture within the hold exempts the frozen owner as sender; a charge does not.
        vm.prank(owner);
        core.capture(owner, owner, "a", 10, false);
        vm.prank(owner);
        vm.expectRevert(IReservationCore.PolicyForbids.selector);
        core.charge(owner, u, "c", 1, payee);
        // Paying oneself is refused.
        registry.modifyPolicyBlacklist(policy, owner, false);
        vm.prank(owner);
        vm.expectRevert(IReservationCore.PolicyForbids.selector);
        core.charge(owner, u, "c", 1, owner);
    }

    function test_holdPlacedEvent() public {
        _tolerance(100);
        vm.expectEmit(true, true, true, true, RESERVATION_CORE_ADDRESS);
        emit IReservationCore.HoldPlaced(owner, owner, u, "a", KIND_HOLD, payee, 100, 101, _now() + 60);
        _hold(owner, "a", 100);
    }

    function test_tokensAreSeparate() public {
        _mint(eur, owner, 5);
        _hold(owner, "a", 1000);
        assertEq(core.available(owner, address(eur)), 5);
        assertEq(core.reserved(owner, address(eur)), 0);
    }

    // Helpers.

    function _hold(address from, bytes32 id, uint128 amount) internal {
        vm.prank(from);
        core.hold(_request(u, id, amount, payee, 60));
    }

    function _approve(uint128 limit, uint32 period) internal {
        vm.prank(owner);
        core.approveHolder(holder, u, limit, period);
    }

    function _tolerance(uint16 bps) internal {
        vm.prank(owner);
        core.setCaptureTolerance(payee, u, bps);
    }
}

/// @dev The TIP-20 errors the model raises for invalid tokens and recipients.
interface MockReservationCoreErrors {
    error InvalidToken();
    error InvalidRecipient();
}
