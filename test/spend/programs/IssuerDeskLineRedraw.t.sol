// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";

import { CompEnv } from "./harness/CompStubs.sol";

/// @notice A merchant win closes even when the lender refuses to draw the line again: the cardholder owes what the
///         line does not take back.
contract IssuerDeskLineRedrawTest is CompEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");

    function setUp() public {
        _deployComp();
        vm.prank(alice);
        core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
        vm.prank(alice);
        core.approveHolder(address(desk), address(earnShare), type(uint128).max, 0);
        usd.mint(alice, 920e6);
    }

    function test_resolveDispute_merchantWinClosesWhenTheLenderRefusesTheRedraw() public {
        uint64 lineId = _disputedOnCredit();
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 100e6, "", false);
        assertEq(credit.lineOf(lineId).owed, 0, "provisional credit repaid the line");
        assertGt(credit.redrawable(lineId, P1), 0);
        // The lender withdraws the credit source's budget.
        vm.prank(lender);
        core.approveHolder(address(credit), address(usd), 0, 0);
        uint256 cash = usd.balanceOf(alice);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(desk.openDisputes(), 0);
        assertEq(desk.settlementTokenInUse(address(0)), 0);
        // The line stays repaid and can no longer draw for this purchase.
        assertEq(credit.lineOf(lineId).owed, 0);
        assertEq(credit.redrawable(lineId, P1), 0);
        // The cardholder gives back all 100 of provisional credit: its cash, then a receivable.
        uint256 taken = cash - usd.balanceOf(alice);
        uint256 owed = desk.receivables(alice, address(usd));
        assertEq(taken + owed, 100e6);
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
        vm.prank(issuer);
        desk.openDispute(P1, 100e6, hex"c1a1");
        assertEq(desk.disputeOf(P1).creditLeg, bytes32("leg-credit"));
        usd.mint(settlement, 100e6);
        vm.prank(settlement);
        usd.transfer(bob, 100e6);
        usd.mint(settlement, 100e6);
    }
}
