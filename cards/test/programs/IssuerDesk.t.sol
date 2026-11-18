// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { IssuerDesk } from "../../src/programs/IssuerDesk.sol";
import { CompEnv } from "./harness/CompStubs.sol";

/// @notice The issuer's dispute desk: provisional credit from the settlement account (the treasury advancing what it
///         lacks), its recovery on a merchant win, refunds that settle provisional credit instead of paying twice,
///         credit-line shares repaid and drawn again for the purchase only, and settle operators within their caps.
contract IssuerDeskTest is CompEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");

    function setUp() public {
        _deployComp();
        vm.prank(alice);
        core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
        vm.prank(alice);
        core.approveHolder(address(desk), address(earnShare), type(uint128).max, 0);
        // Alice spent 80 of her 1000.
        usd.mint(alice, 920e6);
    }

    function test_dispute_lost_takesProvisionalBack_restAsDebt() public {
        _disputed(80e6);
        usd.mint(settlement, 80e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 80e6, "", false);
        assertEq(usd.balanceOf(alice), 1000e6, "provisional credit paid");
        vm.prank(alice);
        usd.transfer(bob, 990e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(_owed(alice, address(usd), settlement), 70e6, "what the cardholder no longer has");
        assertEq(usd.balanceOf(alice), 0, "the rest taken at once");
        assertEq(usd.balanceOf(settlement), 10e6);
        assertEq(desk.disputeOf(P1).state, desk.LOST());
    }

    function test_dispute_lost_takesFreeSavingsSharesBeforeDebt() public {
        _disputed(80e6);
        usd.mint(settlement, 80e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 80e6, "", false);
        vm.prank(alice);
        usd.transfer(bob, 1000e6);
        usd.mint(alice, 50e6);
        _depositEarn(alice, 50e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        // Redeeming rounds down, so at most a unit more stays owed.
        assertApproxEqAbs(_owed(alice, address(usd), settlement), 30e6, 1, "only what neither cash nor savings covered");
        assertApproxEqAbs(usd.balanceOf(settlement), 50e6, 1);
        assertLe(core.available(alice, address(earnShare)), 1);
        assertEq(usd.balanceOf(address(desk)), 0);
        assertEq(earnShare.balanceOf(address(desk)), 0);
        _assertCoreBalanced();
    }

    function test_dispute_provisionalPastTheSettlementBalance_advancedByTheTreasury() public {
        _disputed(80e6);
        usd.mint(settlement, 7e6);
        _fundTreasury(100e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 30e6, "", false);
        assertEq(usd.balanceOf(alice), 950e6, "provisional credit paid in full");
        assertEq(_owed(settlement, address(usd), address(treasury)), 30e6 - 7e6, "what the account lacked");
    }

    function test_dispute_provisionalPastTheIssuersFunds_reverts() public {
        _disputed(80e6);
        vm.prank(issuer);
        vm.expectRevert();
        desk.disputeStep(P1, 2, 30e6, "", false);
    }

    function test_dispute_steps_onlyForward_andProvisionalCapped() public {
        (uint8 representment, uint8 preArbitration, uint8 arbitration, uint8 won) =
            (desk.REPRESENTMENT(), desk.PRE_ARBITRATION(), desk.ARBITRATION(), desk.WON());
        _disputed(50e6);
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.DisputeTooLarge.selector);
        desk.disputeStep(P1, 3, 51e6, "", false);
        vm.prank(issuer);
        desk.disputeStep(P1, representment, 50e6, "", true);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.InvalidDisputeStep.selector);
        desk.disputeStep(P1, 2, 0, "", false);
        // Pre-arbitration and arbitration follow representment, each once; a step never resolves the dispute.
        vm.prank(issuer);
        desk.disputeStep(P1, preArbitration, 0, "", false);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.InvalidDisputeStep.selector);
        desk.disputeStep(P1, preArbitration, 0, "", false);
        vm.prank(issuer);
        desk.disputeStep(P1, arbitration, 0, "", true);
        assertEq(desk.disputeOf(P1).state, arbitration);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.InvalidDisputeStep.selector);
        desk.disputeStep(P1, won, 0, "", false);
    }

    function test_openDispute_aboveWhatStaysUnrefunded_refused() public {
        auth.setPurchase(P1, alice, 80e6, 30e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.DisputeTooLarge.selector);
        desk.openDispute(P1, 50e6 + 1, "");
        vm.prank(issuer);
        desk.openDispute(P1, 50e6, "");
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.DisputeExists.selector);
        desk.openDispute(P1, 1, "");
    }

    function test_dispute_won_refundsTheRestAndCountsTheCreditKept() public {
        _disputed(50e6);
        usd.mint(settlement, 50e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 20e6, "", false);
        vm.prank(issuer);
        desk.resolveDispute(P1, true);
        assertEq(usd.balanceOf(alice), 970e6, "provisional plus the refunded rest");
        assertEq(auth.refundedOut(P1), 30e6, "the program refunded what provisional credit did not cover");
        assertEq(auth.creditedBack(P1), 20e6, "the credit kept counts as refunded");
        assertEq(auth.purchaseOf(P1).refunded, 50e6);
        assertEq(usd.balanceOf(address(desk)), 0, "the desk keeps nothing");
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.NoDispute.selector);
        desk.resolveDispute(P1, true);
    }

    function test_dispute_wonPastTheSettlementBalance_advancedByTheTreasury() public {
        _disputed(80e6);
        usd.mint(settlement, 37.6e6);
        _fundTreasury(100e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, true);
        assertEq(usd.balanceOf(alice), 1000e6, "the whole disputed amount comes back");
        assertEq(_owed(settlement, address(usd), address(treasury)), 80e6 - 37.6e6);
        assertEq(usd.balanceOf(address(desk)), 0);
    }

    function test_refund_duringADispute_settlesProvisionalCreditInsteadOfPayingTwice() public {
        _disputed(80e6);
        usd.mint(settlement, 200e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 80e6, "", false);
        assertEq(usd.balanceOf(alice), 1000e6);
        // The merchant refunds the purchase in full: the cardholder already holds it as provisional credit.
        vm.prank(issuer);
        desk.refund(P1, 80e6);
        assertEq(usd.balanceOf(alice), 1000e6, "never paid twice");
        assertEq(auth.creditedBack(P1), 80e6);
        assertEq(desk.disputeOf(P1).provisional, 0);
        // Nothing provisional is left for a merchant win to take back, and nothing is left to refund on a cardholder
        // win.
        assertEq(desk.winRefund(P1), 0);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(usd.balanceOf(alice), 1000e6);
        assertEq(_owed(alice, address(usd), settlement), 0);
    }

    function test_refund_partialDuringADispute_paysOnlyWhatProvisionalCreditDoesNotCover() public {
        auth.setPurchase(P1, alice, 100e6, 0);
        _setDebtCap(alice, settlement, address(usd), 100e6);
        vm.prank(issuer);
        desk.openDispute(P1, 60e6, "");
        usd.mint(settlement, 200e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 60e6, "", false);
        // A refund of 70 leaves 30 of the purchase; with 60 provisional, 30 of the refund settles that credit.
        vm.prank(issuer);
        desk.refund(P1, 70e6);
        assertEq(auth.refundedOut(P1), 40e6);
        assertEq(auth.creditedBack(P1), 30e6);
        assertEq(desk.disputeOf(P1).provisional, 30e6);
        assertEq(usd.balanceOf(alice), 920e6 + 60e6 + 40e6);
    }

    function test_refund_withoutADispute_paysThroughTheProgram_correctionsToo() public {
        auth.setPurchase(P1, alice, 100e6, 0);
        usd.mint(settlement, 10e6);
        // An overcharge of 10 comes back like a refund.
        vm.prank(issuer);
        desk.refund(P1, 10e6);
        assertEq(usd.balanceOf(alice), 930e6);
        assertEq(auth.purchaseOf(P1).refunded, 10e6);
        assertEq(usd.balanceOf(settlement), 0);
    }

    function test_dispute_open_keepsTheSettlementToken() public {
        assertEq(desk.settlementTokenInUse(address(auth)), 0);
        _disputed(50e6);
        assertEq(desk.openDisputes(), 1);
        assertEq(desk.settlementTokenInUse(address(auth)), 4);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(desk.openDisputes(), 0);
        assertEq(desk.settlementTokenInUse(address(auth)), 0);
    }

    function test_settleOperator_withinItsCap_othersRefused() public {
        // A treasury or authorizing key is not a desk operator.
        auth.setRoles(operator, TREASURY | 1, 1e30);
        _disputed(80e6);
        usd.mint(settlement, 80e6);
        vm.prank(operator);
        vm.expectRevert(IssuerDesk.NotOperator.selector);
        desk.disputeStep(P1, 2, 1, "", false);
        vm.prank(operator);
        vm.expectRevert(IssuerDesk.NotOperator.selector);
        desk.refund(P1, 1);
        auth.setRoles(operator, SETTLE, 50e6);
        vm.prank(operator);
        vm.expectRevert();
        desk.disputeStep(P1, 2, 60e6, "", false);
        vm.prank(operator);
        desk.disputeStep(P1, 2, 30e6, "", false);
        assertEq(auth.usedOf(operator), 30e6);
        // Taking the 30 back would bring it to 60, past its cap of 50.
        vm.prank(operator);
        vm.expectRevert();
        desk.resolveDispute(P1, false);
        vm.prank(operator);
        vm.expectRevert();
        desk.collectedReserve(P1, 21e6);
        vm.prank(operator);
        desk.collectedReserve(P1, 20e6);
        // The issuer itself is never capped.
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
    }

    function test_collectedReserve_boundedByTheDisputeAndWhatStaysUnrefunded() public {
        auth.setPurchase(P1, alice, 100e6, 0);
        vm.prank(issuer);
        desk.openDispute(P1, 60e6, "");
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.ReserveTooLarge.selector);
        desk.collectedReserve(P1, 60e6 + 1);
        vm.prank(issuer);
        desk.collectedReserve(P1, 40e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.ReserveTooLarge.selector);
        desk.collectedReserve(P1, 20e6 + 1);
        // A refund leaves 30 of the purchase unrefunded, below what was already collected.
        usd.mint(settlement, 70e6);
        vm.prank(issuer);
        desk.refund(P1, 70e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.ReserveTooLarge.selector);
        desk.collectedReserve(P1, 1);
        assertEq(desk.disputeOf(P1).collected, 40e6);
    }

    // A $100 purchase, $40 from cash and $60 from a credit line, disputed in full.

    function test_dispute_creditPurchase_provisionalRepaysTheLine_merchantWinDrawsItAgain() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        assertEq(credit.lineOf(lineId).owed, 0, "the line's share repaid it");
        assertEq(usd.balanceOf(alice), 40e6, "only the cash share came as cash");
        IssuerDesk.Dispute memory d = desk.disputeOf(P1);
        assertEq(d.lineRepaid, 60e6);
        assertEq(d.lineLanded, 0);
        uint256 before = usd.balanceOf(settlement);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 60e6, "drawn again");
        assertEq(usd.balanceOf(settlement), before + 100e6, "the lender pays the line's share, the cardholder the rest");
        assertEq(usd.balanceOf(alice), 0);
        assertEq(_owed(alice, address(usd), settlement), 0);
        _assertCoreBalanced();
    }

    function test_dispute_creditPurchase_merchantWinDrawsOnlyWhatTheLenderCanFund() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        vm.prank(lender);
        credit.setLimit(lineId, 25e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 25e6, "what the line could fund");
        // The cardholder owes the other $75: the $40 it holds at once, the rest as debt.
        assertEq(usd.balanceOf(alice), 0);
        assertEq(_owed(alice, address(usd), settlement), 35e6);
    }

    function test_dispute_creditPurchase_lineClosedBeforeTheMerchantWins_recoversFromTheCardholder() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        vm.prank(alice);
        credit.closeLine(lineId);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 0, "a closed line is not drawn again");
        assertEq(usd.balanceOf(alice), 0);
        assertEq(_owed(alice, address(usd), settlement), 60e6);
    }

    function test_dispute_creditPurchase_repaidLineTakesItsShareAsCash() public {
        uint64 lineId = _disputedOnCredit();
        usd.mint(alice, 60e6);
        vm.startPrank(alice);
        usd.approve(address(credit), 60e6);
        credit.repay(lineId, 60e6);
        vm.stopPrank();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 50e6, "", false);
        assertEq(usd.balanceOf(alice), 50e6, "nothing owed, so all cash");
        IssuerDesk.Dispute memory d = desk.disputeOf(P1);
        assertEq(d.lineRepaid, 0);
        assertEq(d.lineLanded, 30e6, "cash that still counts as the line's share");
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 0, "never drawn again");
    }

    function test_dispute_creditPurchase_refundSettlingTheLineShareIsNeverDrawnAgain() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        vm.prank(issuer);
        desk.refund(P1, 100e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 0, "the refund settled the share the line was repaid");
        assertEq(credit.redrawable(lineId, P1), 60e6, "repaid for the purchase but never redrawn");
    }

    function _disputed(uint128 amount) internal {
        auth.setPurchase(P1, alice, uint64(amount), 0);
        _setDebtCap(alice, settlement, address(usd), amount);
        vm.prank(issuer);
        desk.openDispute(P1, amount, hex"c1a1");
    }

    function _disputedOnCredit() internal returns (uint64 lineId) {
        lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        vm.prank(alice);
        usd.transfer(bob, 920e6);
        usd.mint(alice, 40e6);
        // The program captured 60 on the line and 40 from cash.
        _draw(alice, lineId, bytes32("leg-credit"), 60e6, P1);
        auth.setPurchase(P1, alice, 100e6, 0);
        vm.prank(alice);
        usd.transfer(settlement, 40e6);
        assertEq(credit.lineOf(lineId).owed, 60e6, "drawn");
        _setDebtCap(alice, settlement, address(usd), 100e6);
        vm.prank(issuer);
        desk.openDispute(P1, 100e6, hex"c1a1");
        assertEq(desk.disputeOf(P1).creditLeg, bytes32("leg-credit"));
        usd.mint(settlement, 100e6);
        // The test started the settlement account with the purchase it captured; leave it the 100 minted.
        vm.prank(settlement);
        usd.transfer(bob, 100e6);
        usd.mint(settlement, 100e6);
    }

    function _fundTreasury(uint128 cap) internal {
        vm.startPrank(settlement);
        core.approveHolder(address(treasury), address(usd), type(uint128).max, 0);
        vm.stopPrank();
        _setDebtCap(settlement, address(treasury), address(usd), cap);
        usd.mint(address(this), 50e6);
        usd.approve(address(treasury), 50e6);
        treasury.fundIssuerDebt(address(usd), 50e6);
    }
}
