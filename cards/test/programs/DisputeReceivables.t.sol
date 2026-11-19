// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IssuerDesk } from "../../src/programs/IssuerDesk.sol";
import { CompEnv } from "./harness/CompStubs.sol";

/// @notice A merchant win always closes its dispute: what the desk cannot take back from the cardholder, because they
///         revoked the desk or have neither free funds nor debt room, stays owed as a receivable the desk collects later.
contract DisputeReceivablesTest is CompEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");

    function setUp() public {
        _deployComp();
        vm.prank(alice);
        core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
        usd.mint(alice, 920e6);
        auth.setPurchase(P1, alice, 80e6, 0);
        _setDebtCap(alice, settlement, address(usd), 80e6);
        vm.prank(issuer);
        desk.openDispute(P1, 80e6, hex"c1a1");
        usd.mint(settlement, 80e6);
        vm.prank(issuer);
        desk.disputeStep(P1, 2, 80e6, "", false);
    }

    function test_resolveDispute_merchantWinClosesWhenTheDeskWasRevoked() public {
        vm.prank(alice);
        core.approveHolder(address(desk), address(usd), 0, 0);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(desk.openDisputes(), 0);
        assertEq(desk.settlementTokenInUse(address(auth)), 0);
        assertEq(desk.disputeOf(P1).state, desk.LOST());
        assertEq(desk.receivables(alice, address(usd)), 80e6);
        // Once the cardholder lets the desk take it again, the desk collects what is owed, and no more.
        vm.prank(alice);
        core.approveHolder(address(desk), address(usd), type(uint128).max, 0);
        uint256 before = usd.balanceOf(settlement);
        vm.prank(bob);
        vm.expectRevert(IssuerDesk.NotOperator.selector);
        desk.collectReceivable(alice, address(usd), 80e6);
        vm.prank(issuer);
        desk.collectReceivable(alice, address(usd), 1000e6);
        assertEq(usd.balanceOf(settlement) - before, 80e6);
        assertEq(desk.receivables(alice, address(usd)), 0);
    }

    function test_resolveDispute_merchantWinClosesWhenTheCardholderHasNothingLeft() public {
        vm.prank(alice);
        usd.transfer(bob, 1000e6);
        _setDebtCap(alice, settlement, address(usd), 0);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(desk.openDisputes(), 0);
        assertEq(desk.receivables(alice, address(usd)), 80e6);
    }

    function test_resolveDispute_takesFreeCashAndRecordsOnlyTheRest() public {
        vm.prank(alice);
        usd.transfer(bob, 970e6);
        _setDebtCap(alice, settlement, address(usd), 0);
        uint256 before = usd.balanceOf(settlement);
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(usd.balanceOf(settlement) - before, 30e6);
        assertEq(desk.receivables(alice, address(usd)), 50e6);
    }

    function test_resolveDispute_withRoomRecordsNoReceivable() public {
        vm.prank(issuer);
        desk.resolveDispute(P1, false);
        assertEq(desk.receivables(alice, address(usd)), 0);
        assertEq(desk.openDisputes(), 0);
    }
}
