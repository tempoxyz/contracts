// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuthBase } from "../../../src/spend/programs/CardAuthBase.sol";
import { CardLegs } from "../../../src/spend/programs/CardLegs.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice A purchase's captures together stay within its authorized amount plus the owner's capture tolerance, never
///         raise the authorized amount, and count what passes the hold against the operator's cap.
contract CaptureBoundsTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    address internal op = makeAddr("operator");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 10_000e6);
        // A 20% tip tolerance.
        _setTolerance(alice, address(cash), address(usd), 2000);
    }

    function _authorize(address who, uint128 amount) internal {
        vm.prank(who);
        cards.authorize(CARD, P1, amount, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function _capture(address who, uint128 amount, bool isFinal) internal {
        vm.prank(who);
        cards.capture(P1, amount, isFinal);
    }

    function test_capture_totalBoundedByAuthorizationAndTolerance() public {
        _authorize(issuer, 100e6);
        _capture(issuer, 100e6, false);
        _capture(issuer, 15e6, false);
        _capture(issuer, 5e6, false);
        assertEq(cards.purchaseOf(P1).captured, 120e6);
        assertEq(cards.purchaseOf(P1).held, 0);
        // Tolerance used by earlier captures never adds to the next.
        vm.prank(issuer);
        vm.expectRevert(CardLegs.CaptureLimitExceeded.selector);
        cards.capture(P1, 1, false);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.CaptureLimitExceeded.selector);
        cards.capture(P1, 1, true);
        // A final capture of nothing closes it at what it captured.
        _capture(issuer, 0, true);
        assertFalse(cards.purchaseOf(P1).open);
        assertEq(cards.purchaseOf(P1).captured, 120e6);
    }

    function test_capture_repeatedTipsStopAtTolerance() public {
        uint256 before = usd.balanceOf(alice);
        _authorize(issuer, 100e6);
        _capture(issuer, 100e6, false);
        uint256 reverted;
        for (uint256 i; i < 18; ++i) {
            uint256 tip = (uint256(cards.purchaseOf(P1).held) + cards.purchaseOf(P1).captured) * 2000 / 10_000;
            vm.prank(issuer);
            try cards.capture(P1, uint128(tip), false) { }
            catch {
                ++reverted;
            }
        }
        assertEq(reverted, 17, "only the first tip fits the tolerance");
        assertEq(cards.purchaseOf(P1).captured, 120e6);
        assertEq(before - usd.balanceOf(alice), 120e6);
        (,,, uint64 daySpent,) = cards.usageOf(alice);
        assertEq(daySpent, 120e6);
    }

    function test_capture_pastHoldCountsAgainstOperatorCap() public {
        uint8 role = cards.ROLE_AUTHORIZE();
        vm.prank(issuer);
        cards.setOperator(op, role, 100e6);
        _authorize(op, 100e6);
        assertEq(cards.operatorOf(op).used, 100e6);
        // Within the hold the capture uses no more cap.
        _capture(op, 100e6, false);
        assertEq(cards.operatorOf(op).used, 100e6);
        // A tip past the hold needs cap the key no longer has.
        vm.prank(op);
        vm.expectRevert(CardAuthBase.OperatorCapExceeded.selector);
        cards.capture(P1, 20e6, false);
        vm.prank(issuer);
        cards.setOperator(op, role, 120e6);
        // setOperator starts the key's usage afresh.
        _capture(op, 20e6, true);
        assertEq(cards.operatorOf(op).used, 20e6);
    }

    function test_adjust_afterTipPastAuthorization_refused() public {
        _authorize(issuer, 100e6);
        _capture(issuer, 110e6, false);
        assertEq(cards.purchaseOf(P1).held, 0);
        // Neither the captured amount (which would make the tip the new authorized amount) nor any increase moves it.
        vm.startPrank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.adjust(P1, 110e6);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.adjust(P1, 130e6);
        vm.stopPrank();
        // What is left of the tolerance on the authorized 100 still captures; then the purchase is at its bound.
        _capture(issuer, 10e6, false);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.CaptureLimitExceeded.selector);
        cards.capture(P1, 1, true);
        _capture(issuer, 0, true);
        assertEq(cards.purchaseOf(P1).captured, 120e6);
        (,,, uint64 daySpent,) = cards.usageOf(alice);
        assertEq(daySpent, 120e6);
    }

    function test_adjustBetweenTips_neverRaisesTheCaptureBound() public {
        uint8 role = cards.ROLE_AUTHORIZE();
        vm.prank(issuer);
        cards.setOperator(op, role, 3000e6);
        uint256 before = usd.balanceOf(alice);
        _authorize(op, 100e6);
        _capture(op, 120e6, false);
        for (uint256 i; i < 3; ++i) {
            uint256 captured = cards.purchaseOf(P1).captured;
            vm.prank(op);
            vm.expectRevert(CardAuthBase.InvalidAmount.selector);
            cards.adjust(P1, uint128(captured));
            vm.prank(op);
            vm.expectRevert(CardLegs.CaptureLimitExceeded.selector);
            cards.capture(P1, uint128(captured * 2000 / 10_000), false);
        }
        assertEq(cards.purchaseOf(P1).captured, 120e6);
        assertEq(before - usd.balanceOf(alice), 120e6);
        // The owner's next ordinary purchase still fits the limits.
        vm.prank(op);
        cards.authorize(CARD, bytes32("p2"), 1e6, merchant, uint64(block.timestamp + 7 days), 0);
    }
}
