// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IssuerTreasury } from "../../src/programs/IssuerTreasury.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { CompEnv } from "./harness/CompStubs.sol";

/// @notice payOut's advances against a finite holder budget: each spends only what it advances.
contract IssuerTreasuryPayOutBudgetTest is CompEnv {
    function setUp() public {
        _deployComp();
        vm.startPrank(settlement);
        usd.approve(address(treasury), type(uint256).max);
        // A daily budget of 100 for the treasury.
        core.approveHolder(address(treasury), address(usd), 100e6, 1 days);
        vm.stopPrank();
        _setDebtCap(settlement, address(treasury), address(usd), 100e6);
        usd.mint(address(this), 100e6);
        usd.approve(address(treasury), 100e6);
        treasury.fundIssuerDebt(address(usd), 100e6);
    }

    function test_payOut_chargesOnlyTheAdvanceAgainstTheHolderBudget() public {
        vm.prank(settlement);
        treasury.payOut(bob, 40e6, bytes32("p1"));
        vm.prank(settlement);
        assertEq(treasury.payOut(bob, 40e6, bytes32("p2")), 40e6);
        assertEq(_owed(settlement, address(usd), address(treasury)), 80e6);
        assertEq(core.budget(settlement, address(treasury), address(usd)).spent, 80e6);
        assertEq(usd.balanceOf(bob), 80e6);
        // The budget still bounds advances: 20 left today.
        vm.prank(settlement);
        vm.expectRevert();
        treasury.payOut(bob, 20e6 + 1, bytes32("p3"));
    }

    function test_payOut_smallAdvancesSpendOnlyWhatTheyAdvance() public {
        vm.startPrank(settlement);
        treasury.payOut(bob, 40e6, bytes32("p1"));
        treasury.payOut(bob, 1, bytes32("p2"));
        treasury.payOut(bob, 1, bytes32("p3"));
        vm.stopPrank();
        assertEq(_owed(settlement, address(usd), address(treasury)), 40e6 + 2);
        assertEq(core.budget(settlement, address(treasury), address(usd)).spent, 40e6 + 2);
    }

    function test_payOut_paysTheWholeAmountAndTheAdvanceJoinsTheExistingDebt() public {
        vm.prank(settlement);
        treasury.payOut(bob, 30e6, bytes32("p1"));
        IReservationCore.Debt[] memory first = core.debtOf(settlement, address(usd));
        vm.warp(block.timestamp + 1 days);
        usd.mint(settlement, 15e6);
        uint256 held = usd.balanceOf(address(treasury));
        // 15 of the 40 comes from the account's free balance, the treasury advances 25.
        vm.prank(settlement);
        assertEq(treasury.payOut(bob, 40e6, bytes32("p2")), 25e6);
        assertEq(usd.balanceOf(bob), 70e6);
        assertEq(usd.balanceOf(settlement), 0);
        assertEq(usd.balanceOf(address(treasury)), held - 25e6);
        assertEq(treasury.issuerFunds(address(usd)), 100e6 - 55e6);
        IReservationCore.Debt[] memory debts = core.debtOf(settlement, address(usd));
        assertEq(debts.length, 1);
        assertEq(debts[0].amount, 55e6);
        // The advance lapses with the debt it joins.
        assertEq(debts[0].lapsesAt, first[0].lapsesAt);
    }
}
