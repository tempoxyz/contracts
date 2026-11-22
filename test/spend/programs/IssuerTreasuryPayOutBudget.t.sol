// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IssuerTreasury } from "../../../src/spend/programs/IssuerTreasury.sol";
import { CompEnv } from "./harness/CompStubs.sol";

/// @notice payOut's advances: each adds only what it advances to the settlement account's receivable, bounded by the
///         issuer's funds, and the receivable stands until the account repays it.
contract IssuerTreasuryPayOutBudgetTest is CompEnv {
    function setUp() public {
        _deployComp();
        vm.prank(settlement);
        usd.approve(address(treasury), type(uint256).max);
        usd.mint(address(this), 100e6);
        usd.approve(address(treasury), 100e6);
        treasury.fundIssuerDebt(address(usd), 100e6);
    }

    function test_payOut_advancesJoinTheReceivable_withinTheIssuersFunds() public {
        vm.prank(settlement);
        treasury.payOut(bob, 40e6, bytes32("p1"));
        vm.prank(settlement);
        assertEq(treasury.payOut(bob, 40e6, bytes32("p2")), 40e6);
        assertEq(treasury.advanceOf(address(usd)), 80e6);
        assertEq(treasury.issuerFunds(address(usd)), 20e6);
        assertEq(usd.balanceOf(bob), 80e6);
        // The issuer's funds still bound advances: 20 left.
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.IssuerFundsShort.selector, 20e6 + 1, 20e6));
        treasury.payOut(bob, 20e6 + 1, bytes32("p3"));
    }

    function test_payOut_smallAdvancesAddOnlyWhatTheyAdvance() public {
        vm.startPrank(settlement);
        treasury.payOut(bob, 40e6, bytes32("p1"));
        treasury.payOut(bob, 1, bytes32("p2"));
        treasury.payOut(bob, 1, bytes32("p3"));
        vm.stopPrank();
        assertEq(treasury.advanceOf(address(usd)), 40e6 + 2);
        assertEq(usd.balanceOf(address(treasury)), 100e6 - 40e6 - 2);
    }

    function test_payOut_paysTheWholeAmountAndTheAdvanceJoinsTheReceivable() public {
        vm.prank(settlement);
        treasury.payOut(bob, 30e6, bytes32("p1"));
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
        assertEq(treasury.advanceOf(address(usd)), 55e6);
        // The receivable never lapses: it stands until the account repays it.
        vm.warp(block.timestamp + 400 days);
        assertEq(treasury.advanceOf(address(usd)), 55e6);
        usd.mint(settlement, 55e6);
        vm.prank(settlement);
        treasury.repayAdvance(address(usd), 55e6);
        assertEq(treasury.issuerFunds(address(usd)), 100e6);
        assertEq(usd.balanceOf(address(treasury)), 100e6);
    }
}
