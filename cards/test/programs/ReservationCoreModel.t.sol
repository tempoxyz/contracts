// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import {
    IReservationCore,
    KIND_HOLD,
    KIND_LIEN,
    KIND_PLEDGE,
    MAX_DEBT_TERM,
    MAX_HOLD_DURATION,
    MAX_PLEDGE_DURATION,
    RESERVATION_CORE_ADDRESS
} from "../../src/programs/interfaces/IReservationCore.sol";
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
        _hold(owner, "a", 400, false);
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
        core.holdFrom(owner, _request(u, "a", 100, payee, 60, false));
        assertEq(core.reserved(owner, u), 500);
    }

    function test_idReusableOnlyAfterSettlementDeletesIt() public {
        _hold(owner, "a", 100, false);
        vm.expectRevert(IReservationCore.HoldExists.selector);
        _hold(owner, "a", 100, false);
        vm.prank(owner);
        core.capture(owner, owner, "a", 50, false);
        vm.expectRevert(IReservationCore.HoldExists.selector);
        _hold(owner, "a", 100, false);
        vm.prank(owner);
        core.capture(owner, owner, "a", 0, true);
        assertEq(core.getHold(owner, owner, "a").token, address(0));
        _hold(owner, "a", 100, false);
    }

    function test_amountBounds() public {
        vm.expectRevert(IReservationCore.InvalidAmount.selector);
        _hold(owner, "a", 0, false);
        vm.prank(owner);
        vm.expectRevert(IReservationCore.InvalidAmount.selector);
        core.hold(_request(u, "a", uint128(type(uint64).max) + 1, payee, 60, true));
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        _hold(owner, "a", 1001, false);
    }

    function test_holdExpiryBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.hold(_request(u, "a", 1, payee, 0, false));
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.hold(_request(u, "a", 1, payee, MAX_HOLD_DURATION + 1, false));
        core.hold(_request(u, "a", 1, payee, MAX_HOLD_DURATION, false));
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.pledge(payee, u, "p", 1, _now() + MAX_PLEDGE_DURATION + 1);
        core.pledge(payee, u, "p", 1, _now() + MAX_PLEDGE_DURATION);
        vm.stopPrank();
    }

    function test_standInHoldsWhatIsAvailable() public {
        _hold(owner, "a", 1500, true);
        IReservationCore.HoldRecord memory r = core.getHold(owner, owner, "a");
        assertEq(r.held, 1000);
        assertEq(r.captureLimit, 1500);
        assertTrue(r.standIn);
    }

    // Capture, release, adjust.

    function test_captureByPlacerOrPayeeOnly() public {
        _hold(owner, "a", 400, false);
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
        _terms(0, 0, 1500, 0);
        _hold(owner, "a", 100, false);
        _terms(0, 0, 0, 0);
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
        _hold(owner, "a", 400, false);
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
        _terms(0, 0, 1000, 0);
        _hold(owner, "a", 100, false);
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
        core.hold(_request(u, "s", 2000, payee, 60, true));
        vm.expectRevert(IReservationCore.InvalidAmount.selector);
        core.adjust(owner, owner, "s", 2001);
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
        core.holdFrom(owner, _request(u, "a", 300, payee, 60, false));
        vm.expectRevert(IReservationCore.BudgetExceeded.selector);
        core.holdFrom(owner, _request(u, "b", 201, payee, 60, false));
        core.capture(owner, holder, "a", 100, true);
        vm.stopPrank();
        IReservationCore.Budget memory b = core.budget(owner, holder, u);
        assertEq(b.spent, 100);
        assertEq(b.outstanding, 0);
        // Spent stays spent for the period; released amounts return.
        vm.prank(holder);
        vm.expectRevert(IReservationCore.BudgetExceeded.selector);
        core.charge(owner, u, "c", 401, payee, false);
        vm.prank(holder);
        core.charge(owner, u, "c", 400, payee, false);
        assertEq(core.budget(owner, holder, u).spent, 500);
    }

    function test_budgetPeriodResetsSpent() public {
        _approve(100, 1 days);
        vm.prank(holder);
        core.charge(owner, u, "c", 100, payee, false);
        uint64 start = core.budget(owner, holder, u).periodStart;
        vm.warp(start + 1 days - 1);
        assertEq(core.budget(owner, holder, u).spent, 100);
        vm.warp(start + 3 days + 5);
        IReservationCore.Budget memory b = core.budget(owner, holder, u);
        assertEq(b.spent, 0);
        assertEq(b.periodStart, start + 3 days);
        vm.prank(holder);
        core.charge(owner, u, "c", 100, payee, false);
    }

    function test_zeroLimitRevokesNewUseWhileExistingSettle() public {
        _approve(type(uint128).max, 0);
        assertEq(core.budget(owner, holder, u).limit, type(uint64).max);
        vm.prank(holder);
        core.holdFrom(owner, _request(u, "a", 300, payee, 60, false));
        _approve(0, 0);
        vm.startPrank(holder);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.charge(owner, u, "c", 1, payee, false);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.holdFrom(owner, _request(u, "b", 1, payee, 60, false));
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
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        core.setPayeeTerms(owner, u, _t(0, 0, 0, 0));
        vm.expectRevert(IReservationCore.InvalidExpiry.selector);
        core.setPayeeTerms(payee, u, _t(0, 0, 0, uint32(MAX_DEBT_TERM + 1)));
        vm.stopPrank();
    }

    // Debt.

    function test_shortfallBecomesDebtWithinCap() public {
        vm.prank(owner);
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        core.charge(owner, u, "c", 1100, payee, false);
        _terms(50, 300, 0, 1 days);
        vm.prank(owner);
        vm.expectRevert(IReservationCore.DebtCapExceeded.selector);
        core.charge(owner, u, "c", 1100, payee, false);
        // A stand-in charge may use the higher offline cap.
        vm.prank(owner);
        core.charge(owner, u, "c", 1100, payee, true);
        IReservationCore.Debt[] memory debts = core.debtOf(owner, u);
        assertEq(debts.length, 1);
        assertEq(debts[0].creditor, payee);
        assertEq(debts[0].amount, 100);
        assertEq(debts[0].lapsesAt, _now() + 1 days);
        // Incoming credit repays the creditor first.
        _mint(usd, owner, 30);
        assertEq(usd.balanceOf(payee), 1030);
        assertEq(core.debtOf(owner, u)[0].amount, 70);
        _mint(usd, owner, 100);
        assertEq(core.debtOf(owner, u).length, 0);
        assertEq(core.available(owner, u), 30);
    }

    function test_atMostFourCreditorsAndLapse() public {
        vm.startPrank(owner);
        address[5] memory creditors;
        for (uint256 i; i < 5; ++i) {
            creditors[i] = makeAddr(string.concat("creditor", vm.toString(i)));
            core.setPayeeTerms(creditors[i], u, _t(100, 0, 0, uint32(1 days + i)));
        }
        core.charge(owner, u, "c", 1010, creditors[0], false);
        for (uint256 i = 1; i < 4; ++i) {
            core.charge(owner, u, "c", 10, creditors[i], false);
        }
        vm.expectRevert(IReservationCore.TooManyCreditors.selector);
        core.charge(owner, u, "c", 10, creditors[4], false);
        vm.stopPrank();
        assertEq(core.debtOf(owner, u).length, 4);
        vm.warp(_now() + 1 days);
        assertEq(core.debtOf(owner, u).length, 3);
        vm.expectEmit(true, true, true, true, RESERVATION_CORE_ADDRESS);
        emit IReservationCore.DebtLapsed(owner, creditors[0], u, 10);
        core.clearLapsedDebt(owner, u);
        vm.prank(owner);
        core.charge(owner, u, "c", 10, creditors[4], false);
        assertEq(core.debtOf(owner, u).length, 4);
    }

    function test_repaymentSkipsCreditorsPolicyBlocks() public {
        vm.startPrank(owner);
        core.setPayeeTerms(payee, u, _t(100, 0, 0, 0));
        core.setPayeeTerms(holder, u, _t(100, 0, 0, 0));
        core.charge(owner, u, "c", 1010, payee, false);
        core.charge(owner, u, "c", 10, holder, false);
        vm.stopPrank();
        uint64 policy = _blacklistPolicy(usd);
        registry.modifyPolicyBlacklist(policy, payee, true);
        _mint(usd, owner, 15);
        IReservationCore.Debt[] memory debts = core.debtOf(owner, u);
        assertEq(debts.length, 1);
        assertEq(debts[0].creditor, payee);
        assertEq(usd.balanceOf(holder), 10);
        assertEq(core.available(owner, u), 5);
    }

    // Refunds.

    function test_refundForgivesTheCallersDebtFirst() public {
        _terms(200, 0, 0, 0);
        vm.prank(owner);
        core.charge(owner, u, "c", 1100, payee, false);
        vm.prank(payee);
        vm.expectRevert(IReservationCore.InvalidAmount.selector);
        core.refund(owner, u, owner, "c", 0);
        vm.prank(payee);
        vm.expectEmit(true, true, true, true, RESERVATION_CORE_ADDRESS);
        emit IReservationCore.Refunded(owner, payee, u, owner, "c", 150, 100);
        core.refund(owner, u, owner, "c", 150);
        assertEq(core.debtOf(owner, u).length, 0);
        assertEq(usd.balanceOf(payee), 950);
        assertEq(core.available(owner, u), 50);
        // Refunds are unbounded by what was paid, but need the caller's available balance.
        vm.prank(payee);
        vm.expectRevert(IReservationCore.InsufficientAvailable.selector);
        core.refund(owner, u, owner, "c", 951);
    }

    // Policy.

    function test_pauseAndBlacklistBlockPayments() public {
        usd.pause();
        vm.expectRevert(IReservationCore.PolicyForbids.selector);
        _hold(owner, "a", 1, false);
        usd.unpause();
        _hold(owner, "a", 100, false);
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
        core.charge(owner, u, "c", 1, payee, false);
        // Paying oneself is refused.
        registry.modifyPolicyBlacklist(policy, owner, false);
        vm.prank(owner);
        vm.expectRevert(IReservationCore.PolicyForbids.selector);
        core.charge(owner, u, "c", 1, owner, false);
    }

    function test_holdPlacedEvent() public {
        _terms(0, 0, 100, 0);
        vm.expectEmit(true, true, true, true, RESERVATION_CORE_ADDRESS);
        emit IReservationCore.HoldPlaced(owner, owner, u, "a", KIND_HOLD, payee, 100, 100, 101, _now() + 60, false);
        _hold(owner, "a", 100, false);
    }

    function test_tokensAreSeparate() public {
        _mint(eur, owner, 5);
        _hold(owner, "a", 1000, false);
        assertEq(core.available(owner, address(eur)), 5);
        assertEq(core.reserved(owner, address(eur)), 0);
    }

    // Helpers.

    function _hold(address from, bytes32 id, uint128 amount, bool standIn) internal {
        vm.prank(from);
        core.hold(_request(u, id, amount, payee, 60, standIn));
    }

    function _approve(uint128 limit, uint32 period) internal {
        vm.prank(owner);
        core.approveHolder(holder, u, limit, period);
    }

    function _terms(uint128 debtCap, uint128 offlineCap, uint16 toleranceBps, uint32 debtTerm) internal {
        vm.prank(owner);
        core.setPayeeTerms(payee, u, _t(debtCap, offlineCap, toleranceBps, debtTerm));
    }

    function _t(uint128 debtCap, uint128 offlineCap, uint16 toleranceBps, uint32 debtTerm)
        internal
        pure
        returns (IReservationCore.PayeeTerms memory)
    {
        return IReservationCore.PayeeTerms({
            debtCap: debtCap, offlineCap: offlineCap, toleranceBps: toleranceBps, debtTerm: debtTerm
        });
    }
}

/// @dev The TIP-20 errors the model raises for invalid tokens and recipients.
interface MockReservationCoreErrors {
    error InvalidToken();
    error InvalidRecipient();
}
