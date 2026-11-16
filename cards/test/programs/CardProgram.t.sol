// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardProgram } from "../../src/programs/CardProgram.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice A card program over the core model: cards, limits, mandates, and purchases across cash, savings and
///         credit legs, placed, captured, released and refunded in one call each.
contract CardProgramTest is ProgramsEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    uint8 internal constant CASH = 1;
    uint8 internal constant SAVINGS = 2;
    uint8 internal constant CREDIT = 4;

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
    }

    // Cash leg.

    function test_authorize_cash_placesOneHold() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);

        IReservationCore.HoldRecord memory h = _hold(alice, P1, CASH);
        assertEq(h.token, address(usd));
        assertEq(h.placer, address(cards));
        assertEq(h.payee, address(cards));
        assertEq(h.held, 100e6);
        assertEq(core.reserved(alice, address(usd)), 100e6);
        (, uint128 outstanding) = core.allowance(alice, address(cards), address(usd));
        assertEq(outstanding, 100e6);
        CardProgram.Purchase memory p = cards.purchaseOf(P1);
        assertEq(p.legs, CASH);
        assertTrue(p.open);
        _assertCoreBalanced();
    }

    function test_capture_cash_paysSettlementAccount() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.expectEmit(address(cards));
        emit CardProgram.PurchaseCaptured(P1, CARD, 100e6, 100e6, 0, 0, true, 2, 100e6);
        _capture(P1, 100e6, true);

        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(usd.balanceOf(address(cards)), 0);
        assertEq(usd.balanceOf(alice), 900e6);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertFalse(cards.purchaseOf(P1).open);
        _assertCoreBalanced();
    }

    function test_capture_partialThenFinal() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 40e6, false);
        assertEq(_hold(alice, P1, CASH).held, 60e6);
        _capture(P1, 30e6, true);
        assertEq(usd.balanceOf(settlement), 70e6);
        assertEq(usd.balanceOf(alice), 930e6);
        assertTrue(_hold(alice, P1, CASH).settled);
    }

    function test_capture_tipWithinTolerance() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.ToleranceExceeded.selector);
        cards.capture(P1, 110e6, true);

        vm.prank(alice);
        core.setCaptureTolerance(address(cards), address(usd), 2000);
        _capture(P1, 110e6, true);
        assertEq(usd.balanceOf(settlement), 110e6);
        assertEq(usd.balanceOf(alice), 890e6);
    }

    function test_doubleCapture_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.PurchaseNotOpen.selector);
        cards.capture(P1, 100e6, true);
        // The core refuses a second capture of the settled leg too.
        bytes32 id = cards.legId(P1, CASH);
        vm.prank(address(cards));
        vm.expectRevert(IReservationCore.HoldSettled.selector);
        core.capture(alice, id, 1, false);
    }

    function test_captureAfterExpiry_refused_andAnyoneExpires() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 400e6);
        vm.warp(block.timestamp + 7 days);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.PurchaseExpired.selector);
        cards.capture(P1, 400e6, true);
        // The core enforces hard expiry whoever captures.
        bytes32 id = cards.legId(P1, CASH);
        vm.prank(address(cards));
        vm.expectRevert(IReservationCore.HoldExpired.selector);
        core.capture(alice, id, 1, false);

        vm.prank(bob);
        cards.expire(P1);
        assertEq(usd.balanceOf(alice), 1000e6);
        assertFalse(cards.purchaseOf(P1).open);
        // Nothing was captured, so the day's window has its amount back.
        assertEq(cards.cardOf(CARD).daySpent, 0);
        _assertCoreBalanced();
    }

    function test_expire_beforeExpiry_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.expectRevert(CardProgram.PurchaseNotExpired.selector);
        cards.expire(P1);
    }

    function test_release_returnsFundsAndWindow() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        assertEq(cards.cardOf(CARD).daySpent, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        assertEq(usd.balanceOf(alice), 1000e6);
        assertEq(cards.cardOf(CARD).daySpent, 0);
        assertEq(cards.cardOf(CARD).monthSpent, 0);
    }

    function test_onlyIssuer() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), false);
        _authorize(P1, 1e6);
        vm.prank(alice);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.capture(P1, 1e6, true);
    }

    function test_purchaseRef_isUnique() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 1e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.PurchaseExists.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), false);
    }

    // Card controls.

    function test_frozenCard_refused() public {
        usd.mint(alice, 1000e6);
        vm.prank(bob);
        vm.expectRevert(CardProgram.NotCardOwner.selector);
        cards.freeze(CARD);
        vm.prank(alice);
        cards.freeze(CARD);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardNotActive.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), false);
        vm.prank(alice);
        cards.unfreeze(CARD);
        _authorize(P1, 1e6);
    }

    function test_closedCard_refused() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.close(CARD);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardNotActive.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), true);
    }

    function test_expiredCard_refused() public {
        usd.mint(alice, 1000e6);
        vm.warp(block.timestamp + 366 days);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardExpired.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), false);
    }

    function test_replaceCard_movesOwnerAndLimits() public {
        usd.mint(alice, 1000e6);
        bytes32 next = bytes32("card-2");
        vm.prank(issuer);
        cards.replaceCard(CARD, next, uint40(block.timestamp + 700 days));
        CardProgram.Card memory c = cards.cardOf(next);
        assertEq(c.owner, alice);
        assertEq(c.limits.perPurchase, 500e6);
        assertEq(uint8(cards.cardOf(CARD).status), uint8(CardProgram.Status.Closed));
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardNotActive.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), false);
        vm.prank(issuer);
        cards.authorize(next, P1, 1e6, merchant, uint64(block.timestamp + 1 days), false);
    }

    function test_limits_ownerLowersAndIssuerRaisesOnlyWithinCeiling() public {
        vm.prank(issuer);
        vm.expectRevert(CardProgram.LimitAboveCeiling.selector);
        cards.raiseLimits(CARD, _limits(600e6, 1000e6, 5000e6));

        vm.prank(alice);
        cards.lowerLimits(CARD, _limits(100e6, 200e6, 1000e6));
        // The issuer cannot raise them back past what the owner lowered.
        vm.prank(issuer);
        vm.expectRevert(CardProgram.LimitAboveCeiling.selector);
        cards.raiseLimits(CARD, _limits(500e6, 1000e6, 5000e6));
        vm.prank(alice);
        vm.expectRevert(CardProgram.LimitAboveCeiling.selector);
        cards.lowerLimits(CARD, _limits(200e6, 200e6, 1000e6));

        vm.prank(alice);
        cards.allowLimits(CARD, _limits(800e6, 2000e6, 8000e6));
        vm.prank(issuer);
        cards.raiseLimits(CARD, _limits(800e6, 2000e6, 8000e6));
        assertEq(cards.cardOf(CARD).limits.perPurchase, 800e6);
    }

    function test_overLimit_onPurchaseTotalAcrossLegs() public {
        // 60 cash and about 60 in savings: each leg is under 100, the purchase is not.
        usd.mint(alice, 60e6);
        _savings(alice, 60e6);
        vm.prank(alice);
        cards.lowerLimits(CARD, _limits(100e6, 1000e6, 5000e6));
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(0)));
        cards.authorize(CARD, P1, 110e6, merchant, uint64(block.timestamp + 1 days), false);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
    }

    function test_dailyAndMonthlyWindows() public {
        usd.mint(alice, 5000e6);
        vm.prank(alice);
        cards.lowerLimits(CARD, _limits(500e6, 600e6, 900e6));
        _authorize(P1, 400e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(1)));
        cards.authorize(CARD, P2, 300e6, merchant, uint64(block.timestamp + 1 days), false);

        // A new day resets the daily window but not the month.
        vm.warp(block.timestamp + 1 days);
        _authorize(P2, 400e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.LimitExceeded.selector, uint8(2)));
        cards.authorize(CARD, bytes32("purchase-3"), 200e6, merchant, uint64(block.timestamp + 1 days), false);
    }

    function test_revokedMerchant_refused() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.MerchantRevoked.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), false);
    }

    function test_merchantMonthlyLimit() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        cards.setMandate(merchant, false, 150e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.MerchantLimitExceeded.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), false);
        vm.warp(block.timestamp + 30 days);
        _authorize(P2, 100e6);
    }

    // Holder allowance.

    function test_revokedHolder_liveHoldsStillSettle() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(alice);
        core.approveHolder(address(cards), address(usd), 0);
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.Unauthorized.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), false);

        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
    }

    function test_holderAllowance_capsOutstanding() public {
        usd.mint(alice, 1000e6);
        vm.prank(alice);
        core.approveHolder(address(cards), address(usd), 150e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.AllowanceExceeded.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), false);
    }

    // Savings and credit legs.

    function test_authorize_spansCashAndSavings() public {
        usd.mint(alice, 30e6);
        uint256 shares = _savings(alice, 500e6);
        _authorize(P1, 100e6);

        CardProgram.Purchase memory p = cards.purchaseOf(P1);
        assertEq(p.legs, CASH | SAVINGS);
        assertEq(_hold(alice, P1, CASH).held, 30e6);
        IReservationCore.HoldRecord memory s = _hold(alice, P1, SAVINGS);
        assertEq(s.token, address(earnShare));
        assertEq(s.payee, address(facility));
        assertEq(s.held, earnVault.previewWithdraw(70e6));
        assertEq(earnShare.balanceOf(alice), shares - s.held);

        _capture(P1, 100e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 100e6, 2);
        assertEq(earnShare.balanceOf(address(facility)), 0);
        assertEq(facility.float(), FLOAT);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        _assertCoreBalanced();
    }

    function test_capture_waterfall_cashFirst() public {
        usd.mint(alice, 30e6);
        uint256 shares = _savings(alice, 500e6);
        _authorize(P1, 100e6);
        // A partial capture takes cash before shares.
        _capture(P1, 50e6, false);
        assertTrue(_hold(alice, P1, CASH).held == 0);
        assertEq(usd.balanceOf(settlement) >= 50e6 && usd.balanceOf(settlement) <= 50e6 + 2, true);
        _capture(P1, 0, true);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertGt(earnShare.balanceOf(alice), shares - earnVault.previewWithdraw(70e6));
    }

    function test_insufficientFunds_placesNothing() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        vm.prank(issuer);
        vm.expectPartialRevert(CardProgram.InsufficientFunds.selector);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), false);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
    }

    function test_unapprovedFacility_refused() public {
        _savings(alice, 100e6);
        vm.prank(issuer);
        cards.setSource(address(facility), false);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SourceNotApproved.selector, address(facility)));
        cards.authorize(CARD, P1, 50e6, merchant, uint64(block.timestamp + 1 days), false);
    }

    function test_threeLegs_captureAndRepay() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        uint64 lineId = _withLine(1000e6);
        uint256 lenderBefore = usd.balanceOf(lender);
        _authorize(P1, 100e6);

        CardProgram.Purchase memory p = cards.purchaseOf(P1);
        assertEq(p.legs, CASH | SAVINGS | CREDIT);
        bytes32 creditId = credit.holdIdOf(address(cards), P1);
        IReservationCore.HoldRecord memory c = core.getHold(lender, creditId);
        assertEq(c.placer, address(credit));
        assertEq(c.payee, address(cards));
        uint256 drawn = c.held;
        assertApproxEqAbs(drawn, 50e6, 2);
        assertEq(core.reserved(lender, address(usd)), drawn);

        _capture(P1, 100e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 100e6, 2);
        assertEq(usd.balanceOf(lender), lenderBefore - drawn);
        assertEq(credit.lineOf(lineId).owed, drawn);
        assertEq(credit.lineOf(lineId).pending, 0);

        // The borrower repays the lender through the line.
        usd.mint(alice, drawn);
        vm.prank(alice);
        usd.approve(address(credit), drawn);
        vm.prank(alice);
        // forge-lint: disable-next-line(unsafe-typecast)
        credit.repay(lineId, uint128(drawn));
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(usd.balanceOf(lender), lenderBefore);
        _assertCoreBalanced();
    }

    function test_threeLegs_releaseFreesEveryLeg() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        uint64 lineId = _withLine(1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertEq(core.reserved(lender, address(usd)), 0);
        assertEq(credit.lineOf(lineId).pending, 0);
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    function test_refund_reverseOrder() public {
        usd.mint(alice, 30e6);
        _savings(alice, 20e6);
        uint64 lineId = _withLine(1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        uint256 owed = credit.lineOf(lineId).owed;

        // The issuer funds the refund; credit unwinds first, then savings.
        usd.mint(issuer, 100e6);
        vm.prank(issuer);
        usd.approve(address(cards), 100e6);
        vm.prank(issuer);
        cards.refund(P1, uint128(owed + 10e6));
        assertEq(credit.lineOf(lineId).owed, 0);
        assertGt(earnShare.balanceOf(alice), sharesBefore);
        assertEq(core.getHold(alice, cards.legId(P1, CASH)).refunded, 0);

        vm.prank(issuer);
        vm.expectPartialRevert(CardProgram.RefundExceedsCapture.selector);
        cards.refund(P1, 50e6);
    }

    function test_refund_aboveCapture_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 50e6, true);
        usd.mint(issuer, 100e6);
        vm.prank(issuer);
        usd.approve(address(cards), 100e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.RefundExceedsCapture.selector, uint256(1e6)));
        cards.refund(P1, 51e6);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        assertEq(usd.balanceOf(alice), 1000e6);
        (,, uint128 net) = cards.ledger();
        assertEq(net, 0);
    }

    // Stand-ins, rates and the settlement cursor.

    function test_standIn_reservesWhatIsThereAndForwardsRepaidDebt() public {
        usd.mint(alice, 50e6);
        vm.prank(alice);
        cards.freeze(CARD);
        // The network approved it offline: the program records it past the freeze.
        vm.prank(issuer);
        cards.authorize(CARD, P1, 80e6, merchant, uint64(block.timestamp + 1 days), true);
        IReservationCore.HoldRecord memory h = _hold(alice, P1, CASH);
        assertTrue(h.standIn);
        assertEq(h.held, 50e6);
        assertEq(h.approved, 80e6);

        vm.prank(issuer);
        vm.expectRevert(IReservationCore.DebtCapExceeded.selector);
        cards.capture(P1, 80e6, true);
        vm.prank(alice);
        core.setOfflineCap(address(cards), address(usd), 30e6);
        _capture(P1, 80e6, true);
        assertEq(usd.balanceOf(settlement), 50e6);
        (address creditor, uint128 debt) = core.debtOf(alice, address(usd));
        assertEq(creditor, address(cards));
        assertEq(debt, 30e6);

        usd.mint(alice, 40e6);
        core.repay(alice, address(usd));
        cards.forward(address(usd));
        assertEq(usd.balanceOf(settlement), 80e6);
    }

    function test_foreignCashToken_convertsAtRecordedRate() public {
        otherUsd.mint(alice, 1000e6);
        vm.startPrank(alice);
        core.approveHolder(address(cards), address(otherUsd), type(uint128).max);
        cards.setFunding(address(otherUsd), address(0), address(0), 0);
        vm.stopPrank();
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.TokenNotAccepted.selector, address(otherUsd)));
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), false);

        // One unit of the token is worth 1.25 settlement units.
        vm.prank(issuer);
        cards.setRate(address(otherUsd), 1.25e18);
        _authorize(P1, 100e6);
        assertEq(_hold(alice, P1, CASH).held, 80e6);
        _capture(P1, 100e6, true);
        assertEq(otherUsd.balanceOf(settlement), 80e6);
    }

    function test_settlementCursor() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        (uint64 seq,, uint128 net) = cards.ledger();
        assertEq(seq, 2);
        assertEq(net, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.InvalidCursor.selector);
        cards.acknowledgeSettlement(3);
        vm.prank(issuer);
        cards.acknowledgeSettlement(2);
        (, uint64 settledThrough,) = cards.ledger();
        assertEq(settledThrough, 2);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.InvalidCursor.selector);
        cards.acknowledgeSettlement(2);
    }

    // Helpers.

    function _savings(address owner, uint256 assets) internal returns (uint256 shares) {
        usd.mint(owner, assets);
        shares = _depositEarn(owner, assets);
    }

    function _withLine(uint128 limit) internal returns (uint64 lineId) {
        lineId = _openLine(alice, limit, IEarnVault(address(0)), 0);
        vm.prank(alice);
        cards.setFunding(address(usd), address(facility), address(credit), lineId);
    }
}
