// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CreditSource } from "../../src/programs/CreditSource.sol";
import { CompEnv } from "./harness/CompStubs.sol";

/// @notice What a credit line may draw again for a purchase whose provisional credit repaid it: only for a purchase
///         whose credit leg drew the line, at most that leg's captures less refunds, only through the program's
///         companions (its issuer desk), and nothing once the dispute ends for the cardholder.
contract RedrawRightsTest is CompEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");

    function setUp() public {
        _deployComp();
        vm.prank(alice);
        core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
        vm.prank(alice);
        core.approveHolder(address(desk), address(earnShare), type(uint128).max, 0);
        usd.mint(alice, 920e6);
    }

    function test_redraw_endsWhenTheCardholderWins() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        (uint128 repaid,) = credit.repaymentOf(lineId, P1);
        assertEq(repaid, 60e6);
        vm.prank(issuer);
        desk.resolveDispute(P1, true);
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(credit.redrawable(lineId, P1), 0);
        // Not even the desk draws it again, and a treasury key alone never could.
        vm.prank(address(desk));
        vm.expectRevert(CreditSource.NothingToRedraw.selector);
        credit.redraw(lineId, 60e6, P1);
        auth.setRoles(operator, TREASURY, type(uint256).max);
        vm.prank(operator);
        vm.expectRevert(CreditSource.NotProgram.selector);
        credit.redraw(lineId, 60e6, P1);
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    function test_redraw_noneOnceARefundSettledTheCreditLeg() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        vm.prank(issuer);
        desk.refund(P1, 100e6);
        assertEq(credit.redrawable(lineId, P1), 0);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 0);
        vm.prank(address(desk));
        vm.expectRevert(CreditSource.NothingToRedraw.selector);
        credit.redraw(lineId, 60e6, P1);
        assertEq(credit.lineOf(lineId).owed, 0);
    }

    function test_redraw_aMerchantWinStillDrawsWhatTheDeskRepaid() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(credit.lineOf(lineId).owed, 60e6);
        assertEq(credit.redrawable(lineId, P1), 0);
    }

    function test_repayFor_refusedForAPurchaseWithNoLegOnTheLine() public {
        uint64 lineId = _disputedOnCredit();
        auth.setRoles(operator, TREASURY, type(uint256).max);
        usd.mint(operator, 10e6);
        vm.startPrank(operator);
        usd.approve(address(credit), 10e6);
        vm.expectRevert(CreditSource.NotProgram.selector);
        credit.repayFor(lineId, 10e6, bytes32("never-a-purchase"));
        vm.stopPrank();
        auth.setCompanion(operator, true);
        vm.prank(operator);
        vm.expectRevert(CreditSource.UnknownLeg.selector);
        credit.repayFor(lineId, 10e6, bytes32("never-a-purchase"));
        // A purchase whose leg drew another line is no leg of this one.
        uint64 other = _openLine(bob, 1000e6, IEarnVault(address(0)), 0, 0);
        vm.prank(operator);
        vm.expectRevert(CreditSource.UnknownLeg.selector);
        credit.repayFor(other, 10e6, P1);
        assertEq(credit.redrawable(lineId, bytes32("never-a-purchase")), 0);
    }

    function test_repayFor_boundedByTheLegsCapturesLessRefunds() public {
        uint64 lineId = _disputedOnCredit();
        auth.setCompanion(operator, true);
        usd.mint(operator, 100e6);
        vm.startPrank(operator);
        usd.approve(address(credit), 100e6);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.RepayExceedsLeg.selector, 61e6, 60e6));
        credit.repayFor(lineId, 61e6, P1);
        credit.repayFor(lineId, 40e6, P1);
        vm.expectRevert(abi.encodeWithSelector(CreditSource.RepayExceedsLeg.selector, 60e6 + 1, 60e6));
        credit.repayFor(lineId, 20e6 + 1, P1);
        // What is drawn again may be repaid again.
        assertEq(credit.redraw(lineId, 10e6, P1), 10e6);
        credit.repayFor(lineId, 30e6, P1);
        vm.stopPrank();
        assertEq(credit.redrawable(lineId, P1), 60e6);
        // A refund of the leg lowers what may be drawn again.
        auth.refundLeg(credit, alice, bytes32("leg-credit"), 25e6);
        assertEq(credit.redrawable(lineId, P1), 35e6);
    }

    /// @dev The program captured 60 on alice's line and 40 from her cash for P1, which she disputes for 100.
    function _disputedOnCredit() internal returns (uint64 lineId) {
        lineId = _openLine(alice, 1000e6, IEarnVault(address(0)), 0, 0);
        vm.prank(alice);
        usd.transfer(bob, 920e6);
        usd.mint(alice, 40e6);
        _draw(alice, lineId, bytes32("leg-credit"), 60e6, P1);
        auth.setPurchase(P1, alice, 100e6, 0);
        vm.prank(alice);
        usd.transfer(settlement, 40e6);
        vm.prank(issuer);
        desk.openDispute(P1, 100e6, hex"c1a1");
        vm.prank(settlement);
        usd.transfer(bob, 100e6);
        usd.mint(settlement, 100e6);
    }
}
