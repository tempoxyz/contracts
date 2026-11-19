// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuthBase } from "../../src/programs/CardAuthBase.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice Carried usage never starts a later day or month than the owner's today, so it can only add to today's
///         counts; and a purchase under a merchant mandate counts its increments, tips and late charges toward it.
contract UsageCarryAndMandatesTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    bytes32 internal constant P3 = bytes32("purchase-3");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 10_000e6);
    }

    function _auth(bytes32 ref, uint128 amount, address m) internal {
        vm.prank(issuer);
        cards.authorize(CARD, ref, amount, m, uint64(block.timestamp + 7 days), 0);
    }

    function _carry(CardLimits.Usage memory usage, CardLimits.Mandate memory spent) internal {
        address[] memory ms = new address[](1);
        ms[0] = merchant;
        CardLimits.Mandate[] memory sp = new CardLimits.Mandate[](1);
        sp[0] = spent;
        vm.prank(issuer);
        cards.carryUsage(alice, abi.encode(usage, new bytes32[](0), new CardLimits.Window[](0), ms, sp));
    }

    function test_carryUsage_refusesLaterDaysAndMonths() public {
        vm.prank(alice);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 200e6, monthly: 300e6, utcOffset: 0 }));
        vm.prank(alice);
        cards.setMandate(merchant, false, 200e6);
        _auth(P1, 200e6, merchant);
        (uint64 committed, uint32 day, uint32 month,,) = cards.usageOf(alice);
        CardLimits.Mandate memory none = CardLimits.Mandate(false, 0, month, 0);
        vm.expectRevert(CardLimits.InvalidCard.selector);
        this.carryAs(CardLimits.Usage(committed, day + 1, month, 0, 0), none);
        vm.expectRevert(CardLimits.InvalidCard.selector);
        this.carryAs(CardLimits.Usage(committed, day, month + 1, 0, 0), none);
        vm.expectRevert(CardLimits.InvalidCard.selector);
        this.carryAs(CardLimits.Usage(committed, day, month, 0, 0), CardLimits.Mandate(false, 0, month + 1, 0));
        // Today's own counts carry, and only raise.
        _carry(CardLimits.Usage(committed, day, month, 0, 0), none);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardLimits.LimitExceeded.selector, uint8(1)));
        cards.authorize(CARD, P2, 1e6, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function test_carryUsage_refusesLaterCardWindows() public {
        (, uint32 day, uint32 month,,) = cards.usageOf(alice);
        vm.expectRevert(CardLimits.InvalidCard.selector);
        this.carryWindowAs(CardLimits.Window(day + 1, month, 1, 0, 0, 0), day, month);
        vm.expectRevert(CardLimits.InvalidCard.selector);
        this.carryWindowAs(CardLimits.Window(day, month + 1, 0, 1, 0, 0), day, month);
    }

    /// @dev A new card's window names the UTC day, a day after the owner's late in the day west of UTC. Carried with
    ///      nothing spent, it carries nothing and leaves today's counts.
    function test_carryUsage_skipsLaterCardWindowsWithNothingCounted() public {
        vm.warp(1_798_761_600 + 3 hours); // 2027-01-01 03:00 UTC; 2026-12-31 22:00 at UTC-5.
        vm.prank(alice);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: -5 hours }));
        _auth(P1, 100e6, merchant);
        (, uint32 day, uint32 month,,) = cards.usageOf(alice);
        CardLimits.Window memory before = cards.cardOf(CARD).window;
        (uint32 utcDay, uint32 utcMonth) = CardLimits.calendar(0);
        assertEq(utcDay, day + 1);
        assertEq(utcMonth, month + 1);
        assertEq(before.day, day);
        assertEq(before.daySpent, 100e6);
        // Another instance's new card: the UTC day and month, nothing spent.
        carryWindowAs(CardLimits.Window(utcDay, utcMonth, 0, 0, 0, 0), day, month);
        assertEq(abi.encode(cards.cardOf(CARD).window), abi.encode(before));
    }

    /// @dev Carries one window for CARD as the issuer, so a revert can be expected on the outer call.
    function carryWindowAs(CardLimits.Window memory w, uint32 day, uint32 month) public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = CARD;
        CardLimits.Window[] memory ws = new CardLimits.Window[](1);
        ws[0] = w;
        bytes memory data =
            abi.encode(CardLimits.Usage(0, day, month, 0, 0), ids, ws, new address[](0), new CardLimits.Mandate[](0));
        vm.prank(issuer);
        cards.carryUsage(alice, data);
    }

    /// @dev Calls carryUsage as the issuer, so a revert can be expected on the outer call.
    function carryAs(CardLimits.Usage memory usage, CardLimits.Mandate memory spent) external {
        _carry(usage, spent);
    }

    function test_mandate_countsIncrements() public {
        vm.prank(alice);
        cards.setMandate(merchant, false, 100e6);
        _auth(P1, 60e6, merchant);
        assertEq(cards.mandateMerchant(P1), merchant);
        vm.prank(issuer);
        cards.adjust(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantLimitExceeded.selector);
        cards.adjust(P1, 450e6);
        // A revoked mandate stops increments too.
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantRevoked.selector);
        cards.adjust(P1, 101e6);
    }

    function test_mandate_countsTipsAndLateChargesWithoutRefusingThem() public {
        _setTolerance(alice, address(cash), address(usd), 2000);
        vm.prank(alice);
        cards.setMandate(merchant, false, 100e6);
        _auth(P1, 90e6, merchant);
        // A tip the network already took counts without being refused.
        vm.prank(issuer);
        cards.capture(P1, 100e6, true);
        (,,, uint96 spent) = cards.mandates(alice, merchant);
        assertEq(spent, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantLimitExceeded.selector);
        cards.authorize(CARD, P2, 1e6, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function test_newPurchases_needAMerchant() public {
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.NoMerchant.selector);
        cards.authorize(CARD, P1, 1e6, address(0), uint64(block.timestamp + 7 days), 0);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.NoMerchant.selector);
        cards.charge(CARD, P1, 1e6, address(0));
    }

    function test_mandate_releaseGivesItsSpendBack() public {
        vm.prank(alice);
        cards.setMandate(merchant, false, 100e6);
        _auth(P1, 100e6, merchant);
        vm.prank(issuer);
        cards.release(P1);
        assertEq(_mandateSpent(), 0);
        _auth(P2, 100e6, merchant);
        assertEq(_mandateSpent(), 100e6);
    }

    function test_mandate_decreaseAndFinalCaptureGiveTheirSpendBack() public {
        vm.prank(alice);
        cards.setMandate(merchant, false, 100e6);
        _auth(P1, 100e6, merchant);
        vm.prank(issuer);
        cards.adjust(P1, 70e6);
        assertEq(_mandateSpent(), 70e6);
        vm.prank(issuer);
        cards.capture(P1, 50e6, true);
        assertEq(_mandateSpent(), 50e6);
        _auth(P2, 50e6, merchant);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantLimitExceeded.selector);
        cards.authorize(CARD, P3, 1, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function test_mandate_refundGivesItsSpendBack() public {
        vm.prank(alice);
        cards.setMandate(merchant, false, 100e6);
        _auth(P1, 100e6, merchant);
        vm.prank(issuer);
        cards.capture(P1, 100e6, true);
        _refund(P1, 40e6);
        assertEq(_mandateSpent(), 60e6);
        _auth(P2, 40e6, merchant);
    }

    function test_mandate_tipPastTheLimitCountsInFullSoARefundOfItLeavesTheLimitUsed() public {
        _setTolerance(alice, address(cash), address(usd), 2000);
        vm.prank(alice);
        cards.setMandate(merchant, false, 100e6);
        _auth(P1, 100e6, merchant);
        vm.prank(issuer);
        cards.capture(P1, 120e6, true);
        assertEq(_mandateSpent(), 120e6);
        // Refunding the tip returns exactly what it counted: the purchase still uses the whole limit.
        _refund(P1, 20e6);
        assertEq(_mandateSpent(), 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantLimitExceeded.selector);
        cards.authorize(CARD, P2, 1, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function test_mandate_lateChargeOnAPurchaseCountsAndItsRefundGivesBack() public {
        vm.prank(alice);
        cards.setMandate(merchant, false, 100e6);
        _auth(P1, 60e6, merchant);
        vm.prank(issuer);
        cards.capture(P1, 60e6, true);
        // A late charge on the purchase names no merchant of its own and still counts toward the mandate.
        vm.prank(issuer);
        cards.charge(CARD, P1, 50e6, address(0));
        assertEq(_mandateSpent(), 110e6);
        _refund(P1, 50e6);
        assertEq(_mandateSpent(), 60e6);
    }

    function test_mandate_giveBackFromAnEarlierMonthLeavesThisMonth() public {
        vm.prank(alice);
        cards.setMandate(merchant, false, 100e6);
        _auth(P1, 100e6, merchant);
        vm.prank(issuer);
        cards.capture(P1, 100e6, true);
        vm.warp(block.timestamp + 32 days);
        _auth(P2, 30e6, merchant);
        _refund(P1, 100e6);
        assertEq(_mandateSpent(), 30e6);
    }

    function test_mandate_keepsCountingOnceItsLimitIsLifted() public {
        vm.prank(alice);
        cards.setMandate(merchant, false, 100e6);
        _auth(P1, 80e6, merchant);
        vm.prank(alice);
        cards.setMandate(merchant, false, 0);
        _auth(P2, 50e6, merchant);
        assertEq(_mandateSpent(), 130e6);
        // A limit set again starts from what is still spent this month.
        vm.prank(alice);
        cards.setMandate(merchant, false, 150e6);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.MerchantLimitExceeded.selector);
        cards.authorize(CARD, P3, 21e6, merchant, uint64(block.timestamp + 7 days), 0);
        vm.prank(issuer);
        cards.release(P2);
        _auth(P3, 70e6, merchant);
    }

    function test_mandate_purchasesWithoutALimitKeepNoMerchant() public {
        _auth(P1, 10e6, merchant);
        assertEq(cards.mandateMerchant(P1), address(0));
    }

    function _mandateSpent() internal view returns (uint96 spent) {
        (,,, spent) = cards.mandates(alice, merchant);
    }

    function _refund(bytes32 ref, uint128 amount) internal {
        usd.mint(issuer, amount);
        vm.startPrank(issuer);
        usd.approve(address(cards), amount);
        cards.refund(ref, amount);
        vm.stopPrank();
    }
}
