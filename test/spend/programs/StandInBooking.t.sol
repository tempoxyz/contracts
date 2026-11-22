// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuthBase } from "../../../src/spend/programs/CardAuthBase.sol";
import { CardLimits } from "../../../src/spend/programs/CardLimits.sol";
import { ICardAuth } from "../../../src/interfaces/spend/programs/ICardAuth.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice A purchase the network approved without asking (a stand-in) is booked with bookStandIn once it clears: it
///         counts toward the card's limits and the merchant's mandate without being refused by them, while a force
///         post with charge is still refused by them. The operator's cap, a revoked merchant and a card that cannot
///         start a purchase still refuse a stand-in.
contract StandInBookingTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    bytes32 internal constant P3 = bytes32("purchase-3");
    address internal op = makeAddr("operator");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 10_000e6);
    }

    function test_standIn_pastPerPurchaseLimit_booksAndCountsUsage() public {
        // A force post past the 500 per-purchase limit is refused; the same amount approved by the network books.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(0)));
        cards.charge(CARD, P1, 700e6, merchant);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P1, 700e6, merchant);
        ICardAuth.PurchaseView memory p = cards.purchaseOf(P1);
        assertTrue(p.charged);
        assertFalse(p.open);
        assertEq(p.captured, 700e6);
        assertEq(p.refunded, 0, "free cash covered all of it");
        assertEq(usd.balanceOf(settlement), 700e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 700e6, "counted on the card");
        (,,, uint64 daySpent,) = cards.usageOf(alice);
        assertEq(daySpent, 700e6, "counted on the owner");
        // What it used counts: the day has 300 left, so a 301 authorization is refused.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(1)));
        cards.authorize(CARD, P2, 300e6 + 1, merchant, uint64(block.timestamp + 1 days), 0);
        _authorize(P2, 300e6);
        _assertCoreBalanced();
    }

    function test_standIn_pastDailyLimit_books_andForcePostStillRefused() public {
        _authorize(P1, 500e6);
        vm.prank(issuer);
        cards.charge(CARD, P2, 400e6, merchant);
        // 900 of the 1,000 day used: a 200 force post is refused, a 200 stand-in books and takes the day past it.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(1)));
        cards.charge(CARD, P3, 200e6, merchant);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P3, 200e6, merchant);
        assertEq(cards.cardOf(CARD).window.daySpent, 1100e6);
        // Past the limit, nothing ordinary goes through until the day turns.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(1)));
        cards.charge(CARD, bytes32("purchase-4"), 1, merchant);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(issuer);
        cards.charge(CARD, bytes32("purchase-4"), 1e6, merchant);
    }

    function test_standIn_pastTermsCapAndMandateLimit_countsWithoutRefusing() public {
        _grant(150e6, 100e6);
        vm.prank(alice);
        cards.setMandate(merchant, false, 50e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(0)));
        cards.charge(CARD, P1, 200e6, merchant);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P1, 200e6, merchant);
        (uint64 committed,,,,) = cards.usageOf(alice);
        assertEq(committed, 200e6, "past the 150 terms cap");
        (,, uint32 month, uint96 spent) = cards.mandates(alice, merchant);
        assertGt(month, 0);
        assertEq(spent, 200e6, "past the 50 mandate limit");
        // A refund gives back exactly what was counted.
        _refund(P1, 200e6);
        (,,, spent) = cards.mandates(alice, merchant);
        assertEq(spent, 0);
        (committed,,,,) = cards.usageOf(alice);
        assertEq(committed, 0);
    }

    function test_standIn_revokedMerchant_refused() public {
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantRevoked.selector);
        cards.bookStandIn(CARD, P1, 10e6, merchant);
        // Late on a purchase whose hold ended, too.
        vm.prank(alice);
        cards.setMandate(merchant, false, 0);
        _authorize(P2, 10e6);
        vm.prank(issuer);
        cards.release(P2);
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantRevoked.selector);
        cards.bookStandIn(CARD, P2, 700e6, merchant);
    }

    function test_standIn_lateOnEndedHold_pastLimits_books() public {
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P1, 1200e6, merchant);
        assertEq(cards.purchaseOf(P1).captured, 1200e6);
        assertEq(cards.cardOf(CARD).window.daySpent, 1200e6);
        // A reference books at most once, through either call.
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.PurchaseExists.selector);
        cards.bookStandIn(CARD, P1, 1e6, merchant);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.PurchaseExists.selector);
        cards.charge(CARD, P1, 1e6, merchant);
    }

    function test_standIn_onOpenPurchase_refused() public {
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.PurchaseExists.selector);
        cards.bookStandIn(CARD, P1, 100e6, merchant);
    }

    function test_standIn_frozenCard_refused() public {
        // A card frozen after the network approved offline refuses the booking under a new reference, as a force
        // post is; the issuer settles it with the network without the program.
        vm.prank(alice);
        cards.setOwnStatus(CARD, 1);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.CardNotActive.selector);
        cards.bookStandIn(CARD, P1, 10e6, merchant);
        vm.prank(alice);
        cards.setOwnStatus(CARD, 2);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P1, 10e6, merchant);
    }

    function test_standIn_boundedByTheOperatorCap() public {
        uint8 role = cards.ROLE_AUTHORIZE();
        vm.prank(issuer);
        cards.setOperator(op, role, 1000e6);
        vm.prank(op);
        cards.bookStandIn(CARD, P1, 900e6, merchant);
        vm.prank(op);
        vm.expectRevert(CardAuthBase.OperatorCapExceeded.selector);
        cards.bookStandIn(CARD, P2, 100e6 + 1, merchant);
        vm.prank(op);
        cards.bookStandIn(CARD, P2, 100e6, merchant);
        assertEq(cards.operatorOf(op).used, 1000e6);
        // A key without the authorize role cannot book one.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.bookStandIn(CARD, P3, 1e6, merchant);
    }

    function test_standIn_freeCashPays_issuerAbsorbsTheRest() public {
        // Alice spent down to 30 free, 10 more held by another purchase, before the network's 700 stand-in cleared.
        vm.prank(alice);
        usd.transfer(bob, 10_000e6 - 40e6);
        _authorize(P2, 10e6);
        vm.expectEmit(address(cards));
        emit CardAuthBase.PurchaseCaptured(P1, 700e6, 30e6, true, true, 2);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P1, 700e6, merchant);
        assertEq(usd.balanceOf(settlement), 30e6);
        assertEq(core.reserved(alice, address(usd)), 10e6, "other holds untouched");
        ICardAuth.PurchaseView memory p = cards.purchaseOf(P1);
        assertEq(p.captured, 700e6);
        assertEq(p.refunded, 670e6, "absorbed, so never refunded");
        (uint256 held, uint256 unsettled) = cards.exposure();
        assertEq(held, 10e6);
        assertEq(unsettled, 700e6, "the network settles all of it");
        _fundRefund(31e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, 31e6);
        vm.prank(issuer);
        cards.refund(P1, 30e6);
        _assertCoreBalanced();
        _assertSourcesEmpty();
    }

    function _grant(uint64 limit, uint64 perPurchase) internal {
        vm.prank(alice);
        cards.grant(CardLimits.Terms({ limit: limit, perPurchase: perPurchase, daily: 0, monthly: 0, utcOffset: 0 }));
    }

    function _fundRefund(uint256 amount) internal {
        usd.mint(issuer, amount);
        vm.prank(issuer);
        usd.approve(address(cards), amount);
    }

    function _refund(bytes32 ref, uint128 amount) internal {
        _fundRefund(amount);
        vm.prank(issuer);
        cards.refund(ref, amount);
    }
}
