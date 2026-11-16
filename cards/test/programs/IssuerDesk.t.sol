// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IssuerDesk } from "../../src/programs/IssuerDesk.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice An issuer desk over a card program: splits and rewards paid at capture from the settlement account,
///         taken back in proportion by refunds, and corrections linked to the step they fix.
contract IssuerDeskTest is ProgramsEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    IssuerDesk internal desk;
    address internal network = makeAddr("network");
    address internal partner = makeAddr("partner");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        desk = new IssuerDesk(cards);
        vm.prank(issuer);
        cards.setOperator(address(desk), true);
        vm.prank(settlement);
        usd.approve(address(desk), type(uint256).max);
        for (uint256 i; i < 2; ++i) {
            address payee = i == 0 ? network : partner;
            vm.startPrank(payee);
            core.approveHolder(address(desk), address(usd), type(uint128).max);
            core.setDebtCap(settlement, address(usd), 1000e6);
            vm.stopPrank();
        }
        vm.prank(alice);
        core.approveHolder(address(desk), address(usd), type(uint128).max);
        IssuerDesk.Line[] memory lines = new IssuerDesk.Line[](2);
        lines[0] = IssuerDesk.Line({ payee: network, bps: 100, kind: "interchange" });
        lines[1] = IssuerDesk.Line({ payee: partner, bps: 200, kind: "program" });
        vm.prank(issuer);
        desk.setTerms(lines);
        usd.mint(alice, 1000e6);
    }

    function _purchase(uint128 amount) internal {
        _authorize(P1, amount);
        vm.prank(issuer);
        desk.capture(P1, amount, true);
    }

    function test_capture_paysSplits() public {
        _purchase(100e6);
        assertEq(usd.balanceOf(network), 1e6, "network split");
        assertEq(usd.balanceOf(partner), 2e6, "partner split");
        assertEq(usd.balanceOf(settlement), 97e6, "issuer keeps the rest");
    }

    function test_refund_takesSplitsBackInProportion() public {
        _purchase(100e6);
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        desk.refund(P1, 50e6);
        assertEq(usd.balanceOf(network), 0.5e6, "half the network split back");
        assertEq(usd.balanceOf(partner), 1e6, "half the partner split back");
        assertEq(usd.balanceOf(alice), 950e6, "refund reaches the owner");
    }

    function test_refund_payeeWithoutFunds_owesTheRest() public {
        _purchase(100e6);
        vm.prank(network);
        usd.transfer(bob, 1e6);
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        desk.refund(P1, 100e6);
        (address creditor, uint128 debt) = core.debtOf(network, address(usd));
        assertEq(creditor, settlement, "owed to the settlement account");
        assertEq(debt, 1e6, "the split it no longer has");
    }

    function test_rewards_paidFromFunderSplit() public {
        IssuerDesk.Reward[] memory rewards = new IssuerDesk.Reward[](1);
        rewards[0] = IssuerDesk.Reward({ funder: partner, bps: 150, kind: "cashback" });
        vm.prank(issuer);
        desk.setRewards(rewards);
        _purchase(100e6);
        assertEq(usd.balanceOf(partner), 0.5e6, "partner keeps its split less the reward");
        assertEq(usd.balanceOf(alice), 900e6 + 1.5e6, "owner gets the reward");
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        desk.refund(P1, 100e6);
        assertEq(usd.balanceOf(alice), 1000e6, "reward taken back with the refund");
        assertEq(usd.balanceOf(partner), 1.5e6, "the reward returns to its funder");
    }

    function test_rewards_aboveFunderSplit_refused() public {
        IssuerDesk.Reward[] memory rewards = new IssuerDesk.Reward[](1);
        rewards[0] = IssuerDesk.Reward({ funder: partner, bps: 201, kind: "cashback" });
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.InvalidRewards.selector);
        desk.setRewards(rewards);
    }

    function test_terms_wholeCapture_refused() public {
        IssuerDesk.Line[] memory lines = new IssuerDesk.Line[](1);
        lines[0] = IssuerDesk.Line({ payee: network, bps: 10_000, kind: "all" });
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.InvalidTerms.selector);
        desk.setTerms(lines);
    }

    function test_correct_overcharge_comesBackLikeARefund() public {
        _purchase(100e6);
        (uint64 seq,,) = cards.ledger();
        usd.mint(settlement, 10e6);
        vm.prank(issuer);
        desk.correct(P1, seq, 10e6, "duplicate fee");
        assertEq(usd.balanceOf(alice), 910e6, "overcharge returned");
        assertEq(usd.balanceOf(partner), 1.8e6, "split taken back in proportion");
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.CorrectionTooLarge.selector);
        desk.correct(P1, seq, 91e6, "too much");
    }

    function test_correct_undercharge_isChargedWithSplits() public {
        _purchase(100e6);
        (uint64 seq,,) = cards.ledger();
        vm.prank(issuer);
        desk.correct(P1, seq, -10e6, "short capture");
        assertEq(usd.balanceOf(alice), 890e6, "difference charged");
        assertEq(usd.balanceOf(partner), 2.2e6, "split on the difference");
    }

    function test_correct_unknownStep_refused() public {
        _purchase(100e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.NotCorrectable.selector);
        desk.correct(P1, 99, 1e6, "none");
    }

    function test_onlyOperators() public {
        _authorize(P1, 100e6);
        vm.prank(bob);
        vm.expectRevert(IssuerDesk.NotIssuer.selector);
        desk.capture(P1, 100e6, true);
    }

    function _disputed(uint128 amount) internal {
        _purchase(amount);
        vm.prank(alice);
        core.setDebtCap(settlement, address(usd), amount);
        vm.prank(issuer);
        desk.openDispute(P1, amount, hex"c1a1");
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
        (address creditor, uint128 debt) = core.debtOf(alice, address(usd));
        assertEq(creditor, settlement, "owed to the settlement account");
        assertEq(debt, 70e6, "what the cardholder no longer has");
        assertEq(usd.balanceOf(alice), 0, "the rest taken at once");
    }

    function test_dispute_steps_onlyForward_andProvisionalCapped() public {
        _disputed(50e6);
        usd.mint(settlement, 100e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.DisputeTooLarge.selector);
        desk.disputeStep(P1, 3, 51e6, "", false);
        vm.prank(issuer);
        desk.disputeStep(P1, 3, 50e6, "", true);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.InvalidDisputeStep.selector);
        desk.disputeStep(P1, 2, 0, "", false);
    }

    function test_dispute_won_countsAsRefund() public {
        _disputed(50e6);
        usd.mint(settlement, 50e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 20e6, "", false);
        vm.prank(issuer);
        desk.resolveDispute(P1, true);
        assertEq(usd.balanceOf(alice), 1000e6, "provisional plus the refunded rest");
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.RefundTooLarge.selector);
        desk.refund(P1, 1e6);
    }

    function test_dispute_aboveCaptured_refused() public {
        _purchase(50e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerDesk.DisputeTooLarge.selector);
        desk.openDispute(P1, 51e6, "");
    }
}
