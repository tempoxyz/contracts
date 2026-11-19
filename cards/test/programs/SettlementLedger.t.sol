// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuthBase } from "../../src/programs/CardAuthBase.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice The settlement ledger moves only with money: refunds pay the cardholder, and booking a refund without moving
///         money (creditBack) is for registered companions that paid the cardholder themselves, by at most what they
///         book. A purchase's refunds and what the issuer absorbed together never pass what it captured.
contract SettlementLedgerTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    address internal settleKey = makeAddr("settle-key");
    address internal desk = makeAddr("desk");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 1000e6);
        uint8 settle = cards.ROLE_SETTLE();
        vm.prank(issuer);
        cards.setOperator(settleKey, settle, 1);
        _setting(abi.encodeCall(cards.setCompanion, (desk, true)));
    }

    function _unsettled() internal view returns (uint256 unsettled) {
        (,, unsettled) = cards.exposure();
    }

    function test_creditBack_settleKeyCannotMoveTheLedger() public {
        _authorize(P1, 400e6);
        _capture(P1, 400e6, true);
        assertEq(_unsettled(), 400e6);
        vm.startPrank(settleKey);
        vm.expectRevert(CardAuthBase.NotCompanion.selector);
        cards.creditBack(P1, 0, 400e6);
        vm.expectRevert(CardAuthBase.NotCompanion.selector);
        cards.creditBack(P1, 0, -1_000_000e6);
        vm.expectRevert(CardAuthBase.NotCompanion.selector);
        cards.creditBack(P1, 100e6, 0);
        vm.stopPrank();
        assertEq(_unsettled(), 400e6);
        assertEq(cards.purchaseOf(P1).refunded, 0);
    }

    function test_creditBack_settlesBoundedByAmountAndRefunded() public {
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.startPrank(desk);
        // Nothing booked cannot settle anything.
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.creditBack(P1, 0, 1);
        // Settling more than it books.
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.creditBack(P1, 10e6, 10e6 + 1);
        // Adding back more than the purchase has refunded.
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.creditBack(P1, 10e6, -10e6 - 1);
        // Within both.
        cards.creditBack(P1, 10e6, -10e6);
        cards.creditBack(P1, 20e6, 20e6);
        vm.stopPrank();
        assertEq(cards.purchaseOf(P1).refunded, 30e6);
        assertEq(_unsettled(), 90e6);
    }

    function test_refund_neverPassesCapturedAndNothingReopensIt() public {
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        usd.mint(settleKey, 300e6);
        vm.prank(settleKey);
        usd.approve(address(cards), type(uint256).max);
        uint256 before = usd.balanceOf(alice);
        vm.prank(settleKey);
        cards.refund(P1, 100e6);
        vm.prank(settleKey);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, 1);
        // The desk cannot book more refunded on top either.
        vm.prank(desk);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.creditBack(P1, 1, 0);
        assertEq(usd.balanceOf(alice) - before, 100e6);
        (,, int128 net,) = cards.ledger();
        assertEq(net, 0);
    }

    function test_creditBack_limitsComeBackOnlyOnceAndOnlyFromACompanion() public {
        vm.prank(alice);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 100e6, monthly: 0, utcOffset: 0 }));
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(1)));
        cards.authorize(CARD, P2, 10e6, merchant, uint64(block.timestamp + 1 days), 0);
        // A settle key can neither give the day back nor book the purchase unrefunded again.
        vm.prank(settleKey);
        vm.expectRevert(CardAuthBase.NotCompanion.selector);
        cards.creditBack(P1, 100e6, 0);
        // The desk paid the cardholder 100 itself: the day comes back once.
        vm.prank(desk);
        cards.creditBack(P1, 100e6, 100e6);
        _authorize(P2, 100e6);
        _capture(P2, 100e6, true);
        vm.prank(desk);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.creditBack(P1, 100e6, 0);
    }
}
