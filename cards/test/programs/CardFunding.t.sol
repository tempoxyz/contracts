// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardFunding } from "../../src/programs/CardFunding.sol";
import { CardProgram } from "../../src/programs/CardProgram.sol";
import { SavingsFacility } from "../../src/programs/SavingsFacility.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice The program's funding: owner-chosen orders across several vaults, cash and lines, the capture waterfall
///         re-planned at capture time, debt within the cap, refunds that repay debt first, impaired vaults and the
///         exposure the program keeps within its collateral.
contract CardFundingTest is ProgramsEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    uint8 internal constant CASH = 1;
    uint8 internal constant SAVINGS = 2;
    uint8 internal constant CREDIT = 4;

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
    }

    // Funding order.

    function test_order_cashFirst_thenSavings() public {
        usd.mint(alice, 30e6);
        _savings(alice, 500e6);
        _authorize(P1, 100e6);
        assertEq(_hold(alice, P1, CASH).held, 30e6);
        assertEq(_hold(alice, P1, SAVINGS).held, earnVault.previewWithdraw(70e6));
    }

    function test_order_savingsFirst_whenTheOwnerChoosesIt() public {
        usd.mint(alice, 50e6);
        _savings(alice, 500e6);
        CardFunding.Source[] memory order = new CardFunding.Source[](2);
        order[0] = CardFunding.Source({ kind: SAVINGS, source: address(facility), lineId: 0 });
        order[1] = CardFunding.Source({ kind: CASH, source: address(usd), lineId: 0 });
        vm.prank(alice);
        cards.setFunding(address(usd), order);
        _authorize(P1, 100e6);
        assertEq(_hold(alice, P1, SAVINGS).held, earnVault.previewWithdraw(100e6));
        assertEq(core.reserved(alice, address(usd)), 0);
    }

    function test_order_keepsTheVersionAPurchaseWasPlacedUnder() public {
        usd.mint(alice, 100e6);
        _savings(alice, 500e6);
        _authorize(P1, 80e6);
        // A new order applies to new purchases only; P1 still captures from its cash leg.
        CardFunding.Source[] memory order = new CardFunding.Source[](1);
        order[0] = CardFunding.Source({ kind: SAVINGS, source: address(facility), lineId: 0 });
        vm.prank(alice);
        cards.setFunding(address(usd), order);
        _capture(P1, 80e6, true);
        assertEq(usd.balanceOf(alice), 20e6);
        assertEq(usd.balanceOf(settlement), 80e6);
    }

    function test_order_rejectsAnUnapprovedSourceOrAForeignCashEntry() public {
        CardFunding.Source[] memory order = new CardFunding.Source[](1);
        order[0] = CardFunding.Source({ kind: SAVINGS, source: address(0xBEEF), lineId: 0 });
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SourceNotApproved.selector, address(0xBEEF)));
        cards.setFunding(address(usd), order);
        order[0] = CardFunding.Source({ kind: CASH, source: address(otherUsd), lineId: 0 });
        vm.prank(alice);
        vm.expectRevert(CardFunding.InvalidOrder.selector);
        cards.setFunding(address(usd), order);
    }

    function test_program_assets_cashOnly() public {
        usd.mint(alice, 30e6);
        _savings(alice, 500e6);
        vm.prank(issuer);
        cards.setAssets(CASH);
        vm.prank(issuer);
        vm.expectPartialRevert(CardProgram.InsufficientFunds.selector);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
        _authorize(P1, 30e6);
        assertEq(core.reserved(alice, address(earnShare)), 0);
    }

    // Capture waterfall.

    function test_capture_overage_takesFreeCashThenDebtThenAbsorbs() public {
        usd.mint(alice, 100e6);
        _tolerance(10_000);
        vm.prank(alice);
        core.setDebtCap(address(cards), address(usd), 15e6);
        _authorize(P1, 80e6);
        // 80 held + 20 free cash + 15 debt; the issuer absorbs the last 5.
        vm.prank(issuer);
        vm.expectEmit(true, false, false, false, address(cards));
        emit CardProgram.PurchaseCaptured(P1, CARD, 120e6, 0, 0, 0, 5e6, true, 0, 0);
        cards.capture(P1, 120e6, true);
        // The debt is the owner's to the program: the settlement account receives what the owner had.
        assertEq(usd.balanceOf(settlement), 100e6);
        (address creditor, uint128 debt) = core.debtOf(alice, address(usd));
        assertEq(creditor, address(cards));
        assertEq(debt, 15e6);
        (uint256 held, uint256 owed, uint256 debtors) = cards.outstanding();
        assertEq(held, 0);
        assertEq(owed, 15e6);
        assertEq(debtors, 1);
        _assertCoreBalanced();
    }

    function test_capture_overTolerance_refused() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        vm.expectRevert(IReservationCore.ToleranceExceeded.selector);
        cards.capture(P1, 101e6, true);
    }

    function test_capture_reaches_savingsDepositedAfterTheHold() public {
        usd.mint(alice, 50e6);
        _tolerance(10_000);
        _authorize(P1, 50e6);
        _savings(alice, 100e6);
        _capture(P1, 80e6, true);
        assertApproxEqAbs(usd.balanceOf(settlement), 80e6, 2);
        (, uint128 debt) = core.debtOf(alice, address(usd));
        assertEq(debt, 0);
    }

    // Refunds.

    function test_refund_repaysDebtFirst() public {
        usd.mint(alice, 100e6);
        _savings(alice, 100e6);
        _tolerance(10_000);
        vm.prank(alice);
        core.setDebtCap(address(cards), address(usd), 100e6);
        _authorize(P1, 150e6);
        // Spend the rest of the savings elsewhere so the overage becomes debt.
        _capture(P1, 230e6, true);
        (, uint128 debt) = core.debtOf(alice, address(usd));
        assertApproxEqAbs(debt, 30e6, 2);
        uint256 sharesBefore = earnShare.balanceOf(alice);

        _fundRefunds(100e6);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        (, debt) = core.debtOf(alice, address(usd));
        assertEq(debt, 0);
        // The remaining 20 went back to the last drawn leg, savings.
        assertGt(earnShare.balanceOf(alice), sharesBefore);
        (uint256 held, uint256 owed,) = cards.outstanding();
        assertEq(held + owed, 0);
    }

    function test_refund_withOutstandingDebtToAnotherCreditor_goesToTheLegs() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        _fundRefunds(40e6);
        vm.prank(issuer);
        cards.refund(P1, 40e6);
        assertEq(usd.balanceOf(alice), 40e6);
    }

    // Impaired vaults.

    function test_impairedVault_captureTakesWhatTheSharesAreWorth_restBecomesDebt() public {
        _savings(alice, 101e6);
        _tolerance(0);
        vm.prank(alice);
        core.setDebtCap(address(cards), address(usd), 50e6);
        _authorize(P1, 100e6);
        // The venue loses half its assets: all of Alice's shares now redeem for about 50.5.
        _impair(usd.balanceOf(address(venue)) / 2);
        _capture(P1, 100e6, true);
        (, uint128 debt) = core.debtOf(alice, address(usd));
        assertApproxEqAbs(debt, 49.5e6, 2);
        assertEq(earnShare.balanceOf(alice), 0);
        assertEq(core.reserved(alice, address(earnShare)), 0);
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

    // Exposure and collateral.

    function test_exposure_countsHoldsDebtAndUnsettled() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 60e6);
        (uint256 holds, uint256 debt, uint256 unsettled,, uint256 total) = cards.exposure();
        assertEq(holds, 60e6);
        assertEq(debt, 0);
        assertEq(unsettled, 0);
        assertEq(total, 60e6);
        _capture(P1, 60e6, true);
        (holds,, unsettled,, total) = cards.exposure();
        assertEq(holds, 0);
        assertEq(unsettled, 60e6);
        (uint64 seq,,,) = cards.ledger();
        vm.prank(issuer);
        cards.acknowledgeSettlement(seq);
        (,, unsettled,, total) = cards.exposure();
        assertEq(unsettled, 0);
        assertEq(total, 0);
    }

    function test_exposure_overCollateral_refused() public {
        usd.mint(alice, 1000e6);
        StaticCollateral c = new StaticCollateral(100e6);
        vm.prank(issuer);
        cards.setCollateral(address(c));
        _authorize(P1, 80e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardFunding.OverExposure.selector, uint256(110e6), uint256(100e6)));
        cards.authorize(CARD, P2, 30e6, merchant, uint64(block.timestamp + 1 days), 0);
        // An increment past the collateral is refused too.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardFunding.OverExposure.selector, uint256(130e6), uint256(100e6)));
        cards.adjust(P1, 130e6);
    }

    function test_onlyIssuer_setsAssetsAndCollateral() public {
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.setAssets(CASH);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.setCollateral(address(1));
    }

    // Helpers.

    function _savings(address owner, uint256 assets) internal returns (uint256 shares) {
        usd.mint(owner, assets);
        shares = _depositEarn(owner, assets);
    }

    function _tolerance(uint32 bps) internal {
        vm.prank(alice);
        core.setCaptureTolerance(address(cards), address(usd), bps);
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

/// @dev Collateral worth a fixed amount, for exposure checks.
contract StaticCollateral {
    uint256 internal immutable VALUE;

    constructor(uint256 value) {
        VALUE = value;
    }

    function valueOf(address) external view returns (uint256) {
        return VALUE;
    }
}
