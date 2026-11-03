// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardSpend } from "../../src/core/CardSpend.sol";
import { CardSpender } from "../../src/core/CardSpender.sol";
import { CoreEnv } from "./harness/CoreEnv.sol";

/// @notice `CardSpender` with no provider: public spends from stablecoin, Earn or both, every check, the
///         pause, and the private entry point only its own settler can use.
contract CardSpenderTest is CoreEnv {
    function setUp() public {
        _deployCore();
        _deployMockProgram();
        usd.mint(alice, 1000e6);
        usd.mint(router, 1000e6);
    }

    function test_publicSpend_fromStable() public {
        CardSpend memory s = _stableSpend(publicWallet, 0, 42e6, "auth.1");
        vm.prank(alice);
        usd.approve(address(spender), 42e6);
        vm.expectEmit(address(spender));
        emit CardSpender.CardSpent("auth.1", alice, publicWallet, address(usd), 42e6, 42e6, 0, 0, false);
        vm.prank(alice);
        spender.spend(s);
        assertEq(usd.balanceOf(publicWallet), 42e6);
        assertEq(usd.balanceOf(alice), 958e6);
        assertEq(usd.balanceOf(address(spender)), 0);
    }

    function test_publicSpend_fromEarn_redeemsExactlyTheSpend() public {
        uint256 shares = _depositEarn(alice, 500e6);
        uint256 cost = earnVault.previewWithdraw(30e6);
        _publicSpend(alice, _earnSpend(publicWallet, 0, 30e6, 30e6, "auth.earn"));
        assertEq(usd.balanceOf(publicWallet), 30e6, "paid in the vault asset");
        assertEq(earnShare.balanceOf(alice), shares - cost, "burned only what the spend cost");
        assertEq(earnShare.balanceOf(address(spender)), 0);
    }

    function test_publicSpend_splitAcrossStableAndEarn() public {
        _depositEarn(alice, 500e6);
        uint256 stableBefore = usd.balanceOf(alice);
        _publicSpend(alice, _earnSpend(publicWallet, 0, 50e6, 20e6, "auth.split"));
        assertEq(usd.balanceOf(publicWallet), 50e6);
        assertEq(stableBefore - usd.balanceOf(alice), 30e6);
    }

    function test_availableBalance_countsAllowedVault() public {
        uint256 shares = _depositEarn(alice, 400e6);
        assertEq(spender.availableBalance(alice, address(usd), address(0)), 600e6);
        assertEq(
            spender.availableBalance(alice, address(usd), address(earnVault)), 600e6 + earnVault.previewRedeem(shares)
        );
        mock.setVault(address(earnVault), false);
        assertEq(spender.availableBalance(alice, address(usd), address(earnVault)), 600e6);
    }

    /// @dev The spender tells the program the path: a destination open only to private spends refuses a
    ///      public one, and the reverse.
    function test_programSeesWhichPathASpendTakes() public {
        address privateOnly = makeAddr("private-only");
        mock.setDestination(privateOnly, false, true);
        CardSpend memory s = _stableSpend(privateOnly, 0, 1e6, "path");
        vm.prank(alice);
        usd.approve(address(spender), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, privateOnly));
        spender.spend(s);
        _routerSettle(address(usd), 1e6, s);
        assertEq(usd.balanceOf(privateOnly), 1e6, "the settler's private spend reaches it");

        CardSpend memory p = _stableSpend(publicWallet, 0, 1e6, "path.2");
        vm.prank(router);
        usd.transfer(address(settler), 1e6);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, publicWallet));
        settler.settle(address(usd), 1e6, abi.encode(p));
    }

    function test_revert_spendPrivate_onlyItsSettler() public {
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "private");
        vm.prank(alice);
        usd.approve(address(spender), 1e6);
        vm.prank(alice);
        vm.expectRevert(CardSpender.NotSettler.selector);
        spender.spendPrivate(s);
    }

    function test_settlerIsDeployedByItsSpender() public view {
        assertEq(address(settler.SPENDER()), address(spender));
        assertEq(settler.PROGRAM(), address(mock));
    }

    function test_revert_paused_stopsPublicAndPrivate() public {
        mock.setPaused(true);
        CardSpend memory s = _stableSpend(pooledWallet, 0, 1e6, "paused");
        vm.prank(alice);
        usd.approve(address(spender), 1e6);
        vm.prank(alice);
        vm.expectRevert(CardSpender.ProgramPaused.selector);
        spender.spend(s);
        vm.prank(router);
        usd.transfer(address(settler), 1e6);
        vm.prank(router);
        vm.expectRevert(CardSpender.ProgramPaused.selector);
        settler.settle(address(usd), 1e6, abi.encode(s));

        mock.setPaused(false);
        vm.prank(alice);
        spender.spend(s);
        assertEq(usd.balanceOf(pooledWallet), 1e6);
    }

    function test_revert_destinationNotAuthorized() public {
        address stranger = makeAddr("stranger");
        CardSpend memory s = _stableSpend(stranger, 0, 1e6, "stranger");
        vm.prank(alice);
        usd.approve(address(spender), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, stranger));
        spender.spend(s);
    }

    function test_revert_tokenNotAccepted() public {
        otherUsd.mint(alice, 10e6);
        CardSpend memory s = _stableSpend(publicWallet, 0, 1e6, "token");
        s.token = address(otherUsd);
        vm.prank(alice);
        otherUsd.approve(address(spender), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, publicWallet));
        spender.spend(s);
    }

    function test_revert_wrongProgram() public {
        CardSpend memory s = _stableSpend(publicWallet, 0, 1e6, "program");
        s.program = address(0xBEEF);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongProgram.selector, address(0xBEEF)));
        spender.spend(s);
    }

    function test_revert_invalidAmounts() public {
        CardSpend memory s = _stableSpend(publicWallet, 0, 0, "zero");
        vm.prank(alice);
        vm.expectRevert(CardSpender.InvalidAmount.selector);
        spender.spend(s);
        s.amount = 1e6;
        s.fromVault = 2e6;
        vm.prank(alice);
        vm.expectRevert(CardSpender.InvalidAmount.selector);
        spender.spend(s);
    }

    function test_revert_vaultNotAllowed() public {
        mock.setVault(address(earnVault), false);
        _depositEarn(alice, 100e6);
        CardSpend memory s = _earnSpend(publicWallet, 0, 10e6, 10e6, "vault");
        vm.prank(alice);
        earnShare.approve(address(spender), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.VaultNotAllowed.selector, address(earnVault)));
        spender.spend(s);
    }

    function test_revert_shareCostAboveQuote() public {
        _depositEarn(alice, 100e6);
        CardSpend memory s = _earnSpend(publicWallet, 0, 10e6, 10e6, "quote");
        uint256 required = earnVault.previewWithdraw(10e6);
        s.maxShares = required - 1;
        vm.prank(alice);
        earnShare.approve(address(spender), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.ShareCostExceeded.selector, required, required - 1));
        spender.spend(s);
    }

    function test_revert_noApproval() public {
        CardSpend memory s = _stableSpend(publicWallet, 0, 1e6, "approval");
        vm.prank(alice);
        vm.expectRevert();
        spender.spend(s);
    }

    function testFuzz_publicSpend_split(uint256 amount, uint256 fromVault) public {
        _depositEarn(alice, 500e6);
        amount = bound(amount, 1, 400e6);
        fromVault = bound(fromVault, 0, amount);
        uint256 total = usd.balanceOf(alice) + earnVault.previewRedeem(earnShare.balanceOf(alice));
        CardSpend memory s = _earnSpend(publicWallet, 0, amount, fromVault, "fuzz");
        if (fromVault == 0) s.vault = address(0);
        _publicSpend(alice, s);
        assertEq(usd.balanceOf(publicWallet), amount, "destination got exactly the spend");
        uint256 left = usd.balanceOf(alice) + earnVault.previewRedeem(earnShare.balanceOf(alice));
        // Rounding in the vault's favor costs at most a unit or two.
        assertApproxEqAbs(total - left, amount, 2);
        assertGe(total - left, amount);
    }
}
