// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuth } from "../../../src/spend/programs/CardAuth.sol";
import { CardAuthBase } from "../../../src/spend/programs/CardAuthBase.sol";
import { CardLimits } from "../../../src/spend/programs/CardLimits.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice Credit backs add back to settlement at most what a purchase refunded across all of them; a revoked merchant
///         refuses late charges and stand-ins; an issuer change ends the previous issuer's operator keys and proposals.
contract CardAuthBoundsTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    address internal op = makeAddr("operator");
    address internal companion = makeAddr("companion");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 10_000e6);
    }

    function test_creditBack_negativeSettlesNeverCountWhatTheIssuerAbsorbed() public {
        _setting(abi.encodeCall(CardAuth.setCompanion, (companion, true)));
        // 30 of alice's cash pays, the issuer absorbs 70.
        vm.prank(alice);
        usd.transfer(bob, 10_000e6 - 30e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(cards.purchaseOf(P1).refunded, 70e6);
        vm.prank(companion);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.creditBack(P1, 0, -1);
        // A refund of what the cash covered widens the bound by exactly that.
        usd.mint(issuer, 30e6);
        vm.startPrank(issuer);
        usd.approve(address(cards), 30e6);
        cards.refund(P1, 30e6);
        vm.stopPrank();
        vm.startPrank(companion);
        cards.creditBack(P1, 0, -30e6);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.creditBack(P1, 0, -1);
        vm.stopPrank();
        (, uint256 unsettled) = cards.exposure();
        assertEq(unsettled, 100e6, "never past what was captured");
    }

    function test_creditBack_negativeSettlesBoundedByRefundedAcrossCalls() public {
        _setting(abi.encodeCall(CardAuth.setCompanion, (companion, true)));
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.prank(companion);
        cards.creditBack(P1, 10e6, 10e6);
        (, uint256 unsettled) = cards.exposure();
        assertEq(unsettled, 90e6);
        // Up to the 10 refunded adds back, in any number of calls; no more.
        vm.startPrank(companion);
        cards.creditBack(P1, 0, -6e6);
        cards.creditBack(P1, 0, -4e6);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.creditBack(P1, 0, -1);
        vm.stopPrank();
        (, unsettled) = cards.exposure();
        assertEq(unsettled, 100e6, "never past what was captured");
        // A later refund widens the bound by exactly what it refunds.
        vm.prank(companion);
        cards.creditBack(P1, 5e6, 5e6);
        vm.prank(companion);
        cards.creditBack(P1, 0, -5e6);
        vm.prank(companion);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.creditBack(P1, 0, -1);
        (, unsettled) = cards.exposure();
        assertEq(unsettled, 100e6);
        assertEq(cards.purchaseOf(P1).refunded, 15e6);
    }

    function test_lateCharge_countsTowardLimits_unrecordedMerchantPays() public {
        _authorize(P1, 1e6);
        vm.prank(issuer);
        cards.release(P1);
        // No mandate recorded the purchase's merchant, so revoking a merchant later does not reach it.
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);
        vm.prank(issuer);
        cards.charge(CARD, P1, 300e6, merchant);
        assertEq(cards.purchaseOf(P1).refunded, 0, "alice's free cash paid it");
        (,,, uint64 daySpent,) = cards.usageOf(alice);
        assertEq(daySpent, 300e6, "the release gave the 1 back");
    }

    function test_lateCharge_revokedMandateWithLimit_absorbedByTheIssuer() public {
        vm.prank(alice);
        cards.setMandate(merchant, false, 50e6);
        _authorize(P1, 10e6);
        vm.prank(issuer);
        cards.release(P1);
        vm.prank(alice);
        cards.setMandate(merchant, true, 50e6);
        uint256 before = usd.balanceOf(alice);
        vm.prank(issuer);
        cards.charge(CARD, P1, 10e6, merchant);
        assertEq(cards.purchaseOf(P1).refunded, 10e6);
        assertEq(usd.balanceOf(alice), before);
        (,, uint32 month, uint96 spent) = cards.mandates(alice, merchant);
        assertGt(month, 0);
        assertEq(spent, 0, "absorbed, so not counted");
    }

    function test_issuerChange_endsPreviousOperatorsAndProposals() public {
        uint8 role = cards.ROLE_AUTHORIZE();
        vm.prank(issuer);
        cards.setOperator(op, role, 1000e6);
        assertTrue(cards.hasRoles(op, role));
        bytes memory data = abi.encodeCall(CardAuth.setCompanion, (companion, true));
        vm.prank(issuer);
        (bool ok,) = address(cards).call(data);
        assertTrue(ok);
        assertFalse(cards.isCompanion(companion));
        address next = makeAddr("next");
        vm.prank(issuer);
        cards.transferIssuer(next);
        vm.prank(next);
        cards.acceptIssuer();
        // The previous issuer's key no longer acts, for the program or for companions.
        assertFalse(cards.hasRoles(op, role));
        vm.prank(op);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 7 days), 0);
        // The previous issuer's proposal never applies; calling it records a fresh one for the new issuer.
        vm.warp(block.timestamp + 2 days);
        vm.prank(next);
        (ok,) = address(cards).call(data);
        assertTrue(ok);
        assertFalse(cards.isCompanion(companion));
        vm.warp(cards.pendingSetting(keccak256(data)));
        vm.prank(next);
        (ok,) = address(cards).call(data);
        assertTrue(ok);
        assertTrue(cards.isCompanion(companion));
        // Keys the new issuer sets work.
        vm.prank(next);
        cards.setOperator(op, role, 1000e6);
        vm.prank(op);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 7 days), 0);
    }
}
