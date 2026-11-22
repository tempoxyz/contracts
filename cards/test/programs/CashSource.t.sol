// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardAuthBase } from "../../src/programs/CardAuthBase.sol";
import { CardLegs } from "../../src/programs/CardLegs.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { CashSource } from "../../src/programs/CashSource.sol";
import { ICardAuth } from "../../src/programs/interfaces/ICardAuth.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ISource } from "../../src/programs/interfaces/ISource.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice Card funding through the cash source: owner-chosen orders across cash and savings, the capture waterfall
///         (holds, then the owner's free funds within its budget, then the issuer), refunds to each leg, an impaired
///         savings vault and the program's exposure.
contract CashSourceTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
    }

    // Funding order.

    function test_order_cashFirst_thenSavings() public {
        usd.mint(alice, 30e6);
        _savings(alice, 500e6);
        _authorize(P1, 100e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 30e6);
        assertEq(_hold(alice, P1, SAVINGS_LEG).held, earnVault.previewWithdraw(70e6));
        assertEq(_legs(P1), 1 << CASH_LEG | 1 << SAVINGS_LEG);
    }

    function test_order_savingsFirst_whenTheOwnerChoosesIt() public {
        usd.mint(alice, 50e6);
        _savings(alice, 500e6);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        order[1] = _cashEntry(address(usd), 0);
        vm.prank(alice);
        cards.setFunding(order);
        _authorize(P1, 100e6);
        assertEq(core.getHold(alice, address(savings), cards.legId(P1, 0)).held, earnVault.previewWithdraw(100e6));
        assertEq(core.reserved(alice, address(usd)), 0);
    }

    function test_order_keepsTheVersionAPurchaseWasPlacedUnder() public {
        usd.mint(alice, 100e6);
        _savings(alice, 500e6);
        _authorize(P1, 80e6);
        // A new order applies to new purchases only; P1 still captures from its cash leg.
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        vm.prank(alice);
        cards.setFunding(order);
        _capture(P1, 80e6, true);
        assertEq(usd.balanceOf(alice), 20e6);
        assertEq(usd.balanceOf(settlement), 80e6);
        // A new purchase draws on savings only.
        _authorize(P2, 10e6);
        assertEq(core.reserved(alice, address(usd)), 0);
        assertEq(core.getHold(alice, address(savings), cards.legId(P2, 0)).held, earnVault.previewWithdraw(10e6));
    }

    function test_order_rejectsAnUnapprovedSourceOrTooManyEntries() public {
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = CardLegs.Funding(ISource(address(0xBEEF)), bytes32(0));
        vm.prank(alice);
        vm.expectRevert(CardLegs.InvalidOrder.selector);
        cards.setFunding(order);
        order = new CardLegs.Funding[](5);
        for (uint256 i; i < 5; ++i) {
            order[i] = _cashEntry(address(usd), 0);
        }
        vm.prank(alice);
        vm.expectRevert(CardLegs.InvalidOrder.selector);
        cards.setFunding(order);
    }

    function test_order_foreignCashEntry_holdsNothingWithoutAConversion() public {
        // A cash entry in another stablecoin is accepted, but with no Conversion it covers nothing.
        otherUsd.mint(alice, 100e6);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(otherUsd), 100);
        vm.startPrank(alice);
        core.approveHolder(address(cash), address(otherUsd), type(uint128).max, 0);
        cards.setFunding(order);
        vm.stopPrank();
        assertEq(cash.coverable(alice, _position(address(otherUsd), 100)), 0);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.InsufficientAvailable.selector);
        cards.authorize(CARD, P1, 10e6, merchant, uint64(block.timestamp + 1 days), 0);
        assertEq(core.reserved(alice, address(otherUsd)), 0);
    }

    function test_cardKinds_cashOnly_skipsSavings() public {
        bytes32 card = bytes32("card-cash");
        usd.mint(alice, 30e6);
        _savings(alice, 500e6);
        vm.prank(issuer);
        cards.issueCard(card, alice, uint40(block.timestamp + 365 days), _limits(5000e6, 10_000e6, 50_000e6), 1);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.InsufficientAvailable.selector);
        cards.authorize(card, P1, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(issuer);
        cards.authorize(card, P1, 30e6, merchant, uint64(block.timestamp + 1 days), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertEq(core.reserved(alice, address(usd)), 30e6);
    }

    // Capture waterfall.

    function test_capture_overage_takesFreeCashThenAbsorbs() public {
        usd.mint(alice, 100e6);
        _tolerance(10_000);
        _authorize(P1, 80e6);
        // 80 held + 20 free cash; the owner has nothing more, so the issuer absorbs the last 20.
        vm.prank(issuer);
        vm.expectEmit(true, false, false, false, address(cards));
        emit CardAuthBase.PurchaseCaptured(P1, 120e6, 100e6, true, false, 0);
        cards.capture(P1, 120e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(usd.balanceOf(alice), 0);
        assertEq(core.reserved(alice, address(usd)), 0);
        ICardAuth.PurchaseView memory v = cards.purchaseOf(P1);
        assertEq(v.captured, 120e6);
        // What the issuer absorbed counts as refunded, so refunds stop at what the sources covered.
        assertEq(v.refunded, 20e6);
        (uint256 held, uint256 unsettled) = cards.exposure();
        assertEq(held, 0);
        // The network settles all 120, the absorbed 20 included: it stays in the program's exposure until acknowledged.
        assertEq(unsettled, 120e6);
        _assertCoreBalanced();
        _assertSourcesEmpty();
    }

    function test_capture_overage_noFreeCash_issuerAbsorbsIt() public {
        // No free cash: the overage is the issuer's, and the capture of the hold still lands.
        usd.mint(alice, 80e6);
        _tolerance(10_000);
        _authorize(P1, 80e6);
        _capture(P1, 150e6, true);
        assertEq(usd.balanceOf(settlement), 80e6);
        assertEq(cards.purchaseOf(P1).refunded, 70e6);
        (, uint256 unsettled) = cards.exposure();
        assertEq(unsettled, 150e6);
        _assertCoreBalanced();
    }

    function test_capture_overage_boundedByTheOwnersBudgetForTheSource() public {
        usd.mint(alice, 200e6);
        _tolerance(10_000);
        vm.prank(alice);
        core.approveHolder(address(cash), address(usd), 90e6, 0);
        _authorize(P1, 80e6);
        // The budget leaves 10 past the hold, though 120 is free.
        _capture(P1, 150e6, true);
        assertEq(usd.balanceOf(settlement), 90e6);
        assertEq(usd.balanceOf(alice), 110e6);
        assertEq(cards.purchaseOf(P1).refunded, 60e6);
    }

    function test_capture_overage_multiLeg_takesTheCashEntrysFreeCashUpToThePurchasesTolerance() public {
        // Cash holds 1 and savings 99; the owner allows 100% on cash.
        _setTolerance(alice, address(cash), address(usd), 10_000);
        usd.mint(alice, 100e6 + 2);
        _depositEarn(alice, 99e6 + 2);
        uint256 spare = usd.balanceOf(alice) - 1e6;
        vm.prank(alice);
        usd.transfer(bob, spare);
        _authorize(P1, 100e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, 1e6);
        // Cash arrives after the authorization: the capture takes it through the cash leg, past its own hold.
        usd.mint(alice, 30e6);
        uint256 before = usd.balanceOf(settlement);
        _capture(P1, 150e6, true);
        // 1 held + 30 free on the cash leg, 99 on savings (and its dust of free shares); the issuer absorbs about 20.
        assertEq(usd.balanceOf(alice), 0);
        assertApproxEqAbs(cards.purchaseOf(P1).refunded, 20e6, 2);
        assertApproxEqAbs(usd.balanceOf(settlement) - before, 130e6, 2);
        _assertCoreBalanced();
        _assertSourcesEmpty();
    }

    function test_capture_overTolerance_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(CardLegs.CaptureLimitExceeded.selector);
        cards.capture(P1, 101e6, true);
        // Within the owner's tolerance it captures.
        _tolerance(1000);
        _authorize(P2, 100e6);
        _capture(P2, 110e6, true);
        assertEq(usd.balanceOf(settlement), 110e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.PurchaseNotOpen.selector);
        cards.capture(P2, 1e6, true);
    }

    function test_capture_overage_takesSavingsDepositedAfterTheHold() public {
        // The capture walks the order: savings deposited after a cash-only hold cover the overage before any debt.
        usd.mint(alice, 50e6);
        _tolerance(10_000);
        _authorize(P1, 50e6);
        _savings(alice, 100e6);
        _capture(P1, 80e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 80e6, 2);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice)), 70e6, 2);
        assertEq(cards.purchaseOf(P1).refunded, 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        _assertCoreBalanced();
    }

    // Refunds.

    function test_refund_eachLegTakesBackWhatItCovered() public {
        usd.mint(alice, 100e6);
        _savings(alice, 100e6);
        _tolerance(10_000);
        _authorize(P1, 150e6);
        // 100 cash, savings worth 100 (50 held, 50 free); the issuer absorbs the last 30.
        _capture(P1, 230e6, true);
        assertApproxEqAbs(cards.purchaseOf(P1).refunded, 30e6, 2);
        uint256 sharesBefore = earnShare.balanceOf(alice);
        uint256 restored = savings.refundable(alice, bytes32(0), cards.legId(P1, 1));
        assertApproxEqAbs(restored, 100e6, 2);

        _fundRefunds(100e6 + restored);
        vm.prank(issuer);
        cards.refund(P1, uint128(100e6 + restored));
        // Savings take back what they captured; the cash leg pays the owner the rest.
        assertEq(usd.balanceOf(alice), 100e6);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice) - sharesBefore), restored, 2);
        assertEq(usd.balanceOf(address(cash)), 0);
        (uint256 held,) = cards.exposure();
        assertEq(held, 0);
        // What the issuer absorbed is never refunded.
        _fundRefunds(1);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, 30e6);
    }

    function test_refund_neverPastWhatTheSourcesCovered() public {
        usd.mint(alice, 80e6);
        _tolerance(10_000);
        _authorize(P1, 80e6);
        _capture(P1, 100e6, true);
        _fundRefunds(200e6);
        vm.startPrank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, 80e6 + 1);
        cards.refund(P1, 80e6);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, 1);
        vm.stopPrank();
        assertEq(usd.balanceOf(alice), 80e6);
    }

    // Impaired vaults.

    function test_impairedVault_captureTakesWhatTheSharesAreWorth_issuerAbsorbsTheRest() public {
        _savings(alice, 101e6);
        _authorize(P1, 100e6);
        assertEq(_legs(P1), 1 << SAVINGS_LEG);
        // The venue loses half its assets: all of Alice's shares now redeem for about 50.5.
        _impair(usd.balanceOf(address(venue)) / 2);
        uint256 worth = earnVault.previewRedeem(_hold(alice, P1, SAVINGS_LEG).held + earnShare.balanceOf(alice));
        _capture(P1, 100e6, true);
        // A savings-only purchase has no cash leg to carry debt: the held and free shares pay what they are worth and
        // the issuer absorbs what they lack.
        assertApproxEqAbs(usd.balanceOf(settlement), worth, 2);
        assertEq(cards.purchaseOf(P1).refunded, 100e6 - usd.balanceOf(settlement));
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice)), 0, 2);
        _assertCoreBalanced();
    }

    function test_impairedVault_partialReversalFreesShares() public {
        _savings(alice, 101e6);
        _authorize(P1, 100e6);
        _impair(usd.balanceOf(address(venue)) / 2);
        vm.prank(issuer);
        cards.adjust(P1, 40e6);
        assertEq(cards.purchaseOf(P1).held, 40e6);
        uint256 held = core.reserved(alice, address(earnShare));
        assertApproxEqAbs(earnVault.previewRedeem(held), 40e6, 2);
    }

    // Exposure.

    function test_exposure_countsHeldAndUnsettled() public {
        usd.mint(alice, 200e6);
        _authorize(P1, 60e6);
        (uint256 held, uint256 unsettled) = cards.exposure();
        assertEq(held, 60e6);
        assertEq(unsettled, 0);
        _authorize(P2, 70e6);
        (held,) = cards.exposure();
        assertEq(held, 130e6);
        _capture(P1, 60e6, true);
        (held, unsettled) = cards.exposure();
        assertEq(held, 70e6);
        assertEq(unsettled, 60e6);
        vm.prank(issuer);
        cards.release(P2);
        (uint64 seq,,,) = cards.ledger();
        vm.prank(issuer);
        cards.acknowledgeSettlement(seq);
        (held, unsettled) = cards.exposure();
        assertEq(held, 0);
        assertEq(unsettled, 0);
    }

    // The source itself.

    function test_onlyProgram() public {
        bytes32 position = _position(address(usd), 0);
        vm.startPrank(bob);
        vm.expectRevert(CashSource.NotProgram.selector);
        cash.hold(alice, position, P1, 1e6, uint64(block.timestamp + 1 days));
        vm.expectRevert(CashSource.NotProgram.selector);
        cash.capture(alice, position, P1, 1e6, 0);
        vm.expectRevert(CashSource.NotProgram.selector);
        cash.charge(alice, position, P1, 1e6);
        vm.expectRevert(CashSource.NotProgram.selector);
        cash.release(alice, position, P1);
        vm.expectRevert(CashSource.NotProgram.selector);
        cash.refund(alice, position, P1, 1e6);
        vm.stopPrank();
    }

    function test_views() public {
        usd.mint(alice, 70e6);
        bytes32 position = _position(address(usd), 0);
        assertEq(cash.KIND(), 1);
        assertEq(cash.SETTLEMENT_ACCOUNT(), settlement);
        assertEq(cash.coverable(alice, position), 70e6);
        assertEq(cash.refundable(alice, position, P1), type(uint256).max);
        _tolerance(250);
        assertEq(cash.toleranceBps(alice, position), 250);
        _authorize(P1, 50e6);
        assertEq(cash.held(alice, position, cards.legId(P1, CASH_LEG)), 50e6);
        assertEq(cash.coverable(alice, position), 20e6);
    }

    function test_charge_forcePost_takesFreeCashThenAbsorbs() public {
        usd.mint(alice, 30e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 60e6, merchant);
        assertEq(usd.balanceOf(settlement), 30e6);
        assertEq(usd.balanceOf(alice), 0);
        ICardAuth.PurchaseView memory v = cards.purchaseOf(P1);
        assertEq(v.captured, 60e6);
        assertEq(v.refunded, 30e6);
        assertTrue(v.charged);
        (, uint256 unsettled) = cards.exposure();
        assertEq(unsettled, 60e6);
        _assertSourcesEmpty();
    }

    function test_charge_standInApproval_bookedAfterTheFact_onlyFromFreeCash() public {
        // The network approved 100 without asking while alice had 30, then 10 more of hers was held by another
        // purchase: the issuer books it as a force post, which takes only what is free.
        usd.mint(alice, 40e6);
        _authorize(P2, 10e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(usd.balanceOf(settlement), 30e6);
        assertEq(core.reserved(alice, address(usd)), 10e6, "other holds untouched");
        assertEq(cards.purchaseOf(P1).refunded, 70e6);
        (uint256 held, uint256 unsettled) = cards.exposure();
        assertEq(held, 10e6);
        assertEq(unsettled, 100e6);
        _assertCoreBalanced();
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(CashSource.ZeroAddress.selector);
        new CashSource(ICardAuth(address(0)));
    }

    // Helpers.

    function _savings(address owner, uint256 assets) internal returns (uint256 shares) {
        usd.mint(owner, assets);
        shares = _depositEarn(owner, assets);
    }

    function _tolerance(uint16 bps) internal {
        _setTolerance(alice, address(cash), address(usd), bps);
    }

    function _fundRefunds(uint256 amount) internal {
        usd.mint(issuer, amount);
        vm.prank(issuer);
        usd.approve(address(cards), amount);
    }

    function _impair(uint256 assets) internal {
        vm.prank(address(venue));
        usd.transfer(address(0xdead), assets);
    }
}
