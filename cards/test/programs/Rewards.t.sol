// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Rewards } from "../../src/programs/Rewards.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice Rewards paid on a purchase and clawed back on its refund or write-off, bounded by what the purchase's
///         rewards paid and by what the cardholder still holds, never into debt.
contract RewardsTest is AuthEnv {
    Rewards internal rewards;
    bytes32 internal constant P1 = bytes32("reward-1");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        rewards = new Rewards(cards, address(usd), funder);
        _setting(abi.encodeCall(cards.setCompanion, (address(rewards), true)));
        usd.mint(funder, 1000e6);
        vm.prank(funder);
        usd.approve(address(rewards), type(uint256).max);
        vm.prank(alice);
        core.approveHolder(address(rewards), address(usd), type(uint128).max, 0);
        usd.mint(alice, 100e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
    }

    function test_pay_sendsTheRewardToTheCardholder() public {
        vm.prank(issuer);
        rewards.pay(P1, 5e6);
        assertEq(usd.balanceOf(alice), 5e6);
        (uint128 paid, uint128 clawed) = rewards.rewardOf(P1);
        assertEq(paid, 5e6);
        assertEq(clawed, 0);
    }

    function test_clawBack_neverPastWhatThePurchasesRewardsPaid() public {
        vm.startPrank(issuer);
        rewards.pay(P1, 5e6);
        usd.mint(alice, 50e6);
        assertEq(rewards.clawBack(P1, 3e6), 3e6);
        assertEq(rewards.clawBack(P1, 5e6), 2e6);
        assertEq(rewards.clawBack(P1, 1e6), 0);
        vm.stopPrank();
        assertEq(usd.balanceOf(funder), 1000e6);
        assertEq(usd.balanceOf(alice), 50e6);
        assertEq(usd.balanceOf(address(rewards)), 0);
    }

    function test_clawBack_takesOnlyWhatTheCardholderStillHolds_noDebt() public {
        _setDebtCap(alice, address(rewards), address(usd), 100e6);
        vm.prank(issuer);
        rewards.pay(P1, 5e6);
        // The cardholder spent all but 2 of it.
        vm.prank(alice);
        usd.transfer(bob, 3e6);
        vm.prank(issuer);
        assertEq(rewards.clawBack(P1, 5e6), 2e6);
        assertEq(_owed(alice, address(usd), address(rewards)), 0);
        assertEq(usd.balanceOf(alice), 0);
        // What is left can be taken once the cardholder holds it again.
        usd.mint(alice, 10e6);
        vm.prank(issuer);
        assertEq(rewards.clawBack(P1, 5e6), 3e6);
        _assertCoreBalanced();
    }

    function test_clawBack_withinTheBudgetTheCardholderGave() public {
        vm.prank(issuer);
        rewards.pay(P1, 5e6);
        vm.prank(alice);
        core.approveHolder(address(rewards), address(usd), 1e6, 0);
        vm.prank(issuer);
        assertEq(rewards.clawBack(P1, 5e6), 1e6);
    }

    function test_settleRoleOnly_andOperatorCapCounts() public {
        vm.prank(alice);
        vm.expectRevert(Rewards.Unauthorized.selector);
        rewards.pay(P1, 1e6);
        vm.prank(alice);
        vm.expectRevert(Rewards.Unauthorized.selector);
        rewards.clawBack(P1, 1e6);
        address key = makeAddr("settler");
        vm.prank(issuer);
        cards.setOperator(key, cards.ROLE_SETTLE(), 4e6);
        vm.prank(key);
        rewards.pay(P1, 4e6);
        assertEq(cards.operatorOf(key).used, 4e6);
        vm.prank(key);
        vm.expectRevert();
        rewards.pay(P1, 1);
    }

    function test_unknownPurchase_refused() public {
        vm.prank(issuer);
        vm.expectRevert(Rewards.UnknownPurchase.selector);
        rewards.pay(bytes32("none"), 1e6);
    }
}
