// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardLegs } from "../../src/programs/CardLegs.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { CashSource } from "../../src/programs/CashSource.sol";
import { ICardAuth } from "../../src/programs/interfaces/ICardAuth.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ISource } from "../../src/programs/interfaces/ISource.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice Card funding through the cash source: owner-chosen orders across cash and savings, the capture waterfall
///         (holds, then the first cash leg's free cash and debt within the owner's caps, then the issuer), refunds
///         that repay the owner's debt to the source first, an impaired savings vault and the program's exposure.
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

    function test_capture_overage_takesFreeCashThenDebtThenAbsorbs() public {
        usd.mint(alice, 100e6);
        _tolerance(10_000);
        _setDebtCap(alice, address(cash), address(usd), 15e6);
        _authorize(P1, 80e6);
        // 80 held + 20 free cash + 15 debt; the issuer absorbs the last 5.
        vm.prank(issuer);
        vm.expectEmit(true, false, false, false, address(cards));
        emit CardAuth.PurchaseCaptured(P1, 120e6, 115e6, true, false, 0);
        cards.capture(P1, 120e6, true);
        // The debt is the owner's to the cash source: the settlement account receives what the owner had.
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(_owed(alice, address(usd), address(cash)), 15e6);
        ICardAuth.PurchaseView memory v = cards.purchaseOf(P1);
        assertEq(v.captured, 120e6);
        // What the issuer absorbed counts as refunded, so refunds stop at what the sources covered.
        assertEq(v.refunded, 5e6);
        (uint256 held,, uint256 unsettled) = cards.exposure();
        assertEq(held, 0);
        assertEq(unsettled, 115e6);
        _assertCoreBalanced();
        _assertSourcesEmpty();

        // The repaid debt reaches the source, which forwards it to the settlement account.
        usd.mint(alice, 15e6);
        _repay(alice, address(usd));
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        cash.sweep(address(usd));
        assertEq(usd.balanceOf(settlement), 115e6);
    }

    function test_capture_overage_debtNeverPastTheCap() public {
        // No free cash and no debt cap: the overage is the issuer's, never the owner's debt.
        usd.mint(alice, 80e6);
        _tolerance(10_000);
        _authorize(P1, 80e6);
        _capture(P1, 150e6, true);
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        assertEq(usd.balanceOf(settlement), 80e6);
        assertEq(cards.purchaseOf(P1).refunded, 70e6);
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

    function test_capture_overage_standIn_debtWithinTheOfflineCap() public {
        usd.mint(alice, 30e6);
        _setDebtCap(alice, address(cash), address(usd), 10e6);
        _setOfflineCap(alice, address(cash), address(usd), 50e6);
        uint8 standInFlag = cards.STAND_IN();
        vm.prank(issuer);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), standInFlag);
        assertEq(_hold(alice, P1, CASH_LEG).held, 30e6);
        // A stand-in has no tolerance.
        vm.prank(issuer);
        vm.expectRevert(CardLegs.CaptureLimitExceeded.selector);
        cards.capture(P1, 100e6 + 1, true);
        _capture(P1, 100e6, true);
        // 30 free, 50 debt within the offline cap; the issuer absorbs 20.
        assertEq(usd.balanceOf(settlement), 30e6);
        assertEq(_owed(alice, address(usd), address(cash)), 50e6);
        assertEq(cards.purchaseOf(P1).refunded, 20e6);
        _assertCoreBalanced();
    }

    function test_capture_overage_noNewCreditorPastTheCoreLimit() public {
        _tolerance(10_000);
        _setDebtCap(alice, address(cash), address(usd), 100e6);
        // Alice already owes the core's maximum number of other creditors.
        for (uint256 i; i < 4; ++i) {
            address creditor = address(uint160(0xC0FFEE + i));
            vm.prank(alice);
            core.approveHolder(creditor, address(usd), type(uint128).max, 0);
            _setDebtCap(alice, creditor, address(usd), 1e6);
            vm.prank(creditor);
            core.charge(alice, address(usd), bytes32(i), 1e6, creditor, false);
        }
        usd.mint(alice, 50e6);
        _authorize(P1, 50e6);
        _capture(P1, 80e6, true);
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        assertEq(usd.balanceOf(settlement), 50e6);
        assertEq(cards.purchaseOf(P1).refunded, 30e6);
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
        vm.expectRevert(CardAuth.PurchaseNotOpen.selector);
        cards.capture(P2, 1e6, true);
    }

    function test_capture_overage_doesNotReachSavingsDepositedAfterTheHold() public {
        // Captures do not re-plan: savings deposited after a cash-only hold stay untouched, the overage the issuer's.
        usd.mint(alice, 50e6);
        _tolerance(10_000);
        _authorize(P1, 50e6);
        uint256 shares = _savings(alice, 100e6);
        _capture(P1, 80e6, true);
        assertEq(usd.balanceOf(settlement), 50e6);
        assertEq(earnShare.balanceOf(alice), shares);
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        assertEq(cards.purchaseOf(P1).refunded, 30e6);
    }

    // Refunds.

    function test_refund_repaysDebtFirst() public {
        usd.mint(alice, 100e6);
        _savings(alice, 100e6);
        _tolerance(10_000);
        _setDebtCap(alice, address(cash), address(usd), 100e6);
        _authorize(P1, 150e6);
        // 100 cash, savings worth 50, then 80 of debt through the cash leg.
        _capture(P1, 230e6, true);
        assertApproxEqAbs(_owed(alice, address(usd), address(cash)), 80e6, 2);
        uint256 debt = _owed(alice, address(usd), address(cash));
        uint256 sharesBefore = earnShare.balanceOf(alice);

        _fundRefunds(100e6);
        vm.prank(issuer);
        cards.refund(P1, 100e6);
        // The refund forgives the debt first and pays the owner the rest in cash; savings get nothing.
        assertEq(_owed(alice, address(usd), address(cash)), 0);
        assertEq(usd.balanceOf(alice), 100e6 - debt);
        assertEq(earnShare.balanceOf(alice), sharesBefore);
        // The forgiven part stays with the source until it is swept back to the settlement account.
        assertEq(usd.balanceOf(address(cash)), debt);
        uint256 before = usd.balanceOf(settlement);
        cash.sweep(address(usd));
        assertEq(usd.balanceOf(settlement), before + debt);
        (uint256 held,,) = cards.exposure();
        assertEq(held, 0);
    }

    function test_refund_withOutstandingDebtToAnotherCreditor_goesToTheOwner() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        address creditor = makeAddr("creditor");
        vm.prank(alice);
        core.approveHolder(creditor, address(usd), type(uint128).max, 0);
        _setDebtCap(alice, creditor, address(usd), 10e6);
        vm.prank(creditor);
        core.charge(alice, address(usd), bytes32("other"), 10e6, creditor, false);
        assertEq(_owed(alice, address(usd), creditor), 10e6);

        _fundRefunds(40e6);
        vm.prank(issuer);
        cards.refund(P1, 40e6);
        // The source forgives only its own debt: the whole refund is paid to the owner, and the node repays the
        // other creditor from that credit as it lands.
        assertEq(_owed(alice, address(usd), creditor), 0);
        assertEq(usd.balanceOf(creditor), 10e6);
        assertEq(usd.balanceOf(alice), 30e6);
        assertEq(usd.balanceOf(address(cash)), 0);
        assertEq(cards.purchaseOf(P1).refunded, 40e6);
    }

    function test_refund_neverPastWhatTheSourcesCovered() public {
        usd.mint(alice, 80e6);
        _tolerance(10_000);
        _authorize(P1, 80e6);
        _capture(P1, 100e6, true);
        _fundRefunds(200e6);
        vm.startPrank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 80e6 + 1);
        cards.refund(P1, 80e6);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
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
        uint256 worth = earnVault.previewRedeem(_hold(alice, P1, SAVINGS_LEG).held);
        _capture(P1, 100e6, true);
        // A savings-only purchase has no cash leg to carry debt: the issuer absorbs what the shares lack.
        assertEq(usd.balanceOf(settlement), worth);
        assertEq(cards.purchaseOf(P1).refunded, 100e6 - worth);
        assertEq(core.reserved(alice, address(earnShare)), 0);
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice)), 0.5e6, 2);
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

    function test_exposure_countsHeldStandInAndUnsettled() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 60e6);
        (uint256 held, uint256 standIn, uint256 unsettled) = cards.exposure();
        assertEq(held, 60e6);
        assertEq(standIn, 0);
        assertEq(unsettled, 0);
        uint8 standInFlag = cards.STAND_IN();
        vm.prank(issuer);
        cards.authorize(CARD, P2, 70e6, merchant, uint64(block.timestamp + 1 days), standInFlag);
        (held, standIn,) = cards.exposure();
        assertEq(held, 130e6);
        assertEq(standIn, 70e6);
        _capture(P1, 60e6, true);
        (held, standIn, unsettled) = cards.exposure();
        assertEq(held, 70e6);
        assertEq(standIn, 70e6);
        assertEq(unsettled, 60e6);
        vm.prank(issuer);
        cards.release(P2);
        (uint64 seq,,,) = cards.ledger();
        vm.prank(issuer);
        cards.acknowledgeSettlement(seq);
        (held, standIn, unsettled) = cards.exposure();
        assertEq(held, 0);
        assertEq(standIn, 0);
        assertEq(unsettled, 0);
    }

    // The source itself.

    function test_onlyProgram() public {
        bytes32 position = _position(address(usd), 0);
        vm.startPrank(bob);
        vm.expectRevert(CashSource.NotProgram.selector);
        cash.hold(alice, position, P1, 1e6, uint64(block.timestamp + 1 days), false);
        vm.expectRevert(CashSource.NotProgram.selector);
        cash.capture(alice, position, P1, 1e6, 0);
        vm.expectRevert(CashSource.NotProgram.selector);
        cash.charge(alice, position, P1, 1e6, false);
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

    function test_charge_forcePost_takesFreeCashThenDebtThenAbsorbs() public {
        usd.mint(alice, 30e6);
        _setDebtCap(alice, address(cash), address(usd), 20e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 60e6, merchant);
        assertEq(usd.balanceOf(settlement), 30e6);
        assertEq(_owed(alice, address(usd), address(cash)), 20e6);
        ICardAuth.PurchaseView memory v = cards.purchaseOf(P1);
        assertEq(v.captured, 60e6);
        assertEq(v.refunded, 10e6);
        assertTrue(v.charged);
        _assertSourcesEmpty();
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
