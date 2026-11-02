// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { BeaconProxy } from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import { CardSpend } from "../../src/CardSpend.sol";
import { CardSpender } from "../../src/CardSpender.sol";
import { CardsEnv } from "../harness/CardsEnv.sol";

/// @notice Public spend with Rain as the provider: the cardholder's account pays its own Rain collateral
///         contract from stablecoin, Earn shares, or both, as Rain's real-time funding commits it.
contract CardSpenderTest is CardsEnv {
    function setUp() public {
        _deployWorld();
        usd.mint(alice, 1000e6);
        usd.mint(bob, 1000e6);
    }

    function test_publicSpend_fromStable_fundsOwnCollateral() public {
        CardSpend memory s = _stableSpend(aliceCollateral, aliceIndex, 42e6, "auth.1");
        vm.prank(alice);
        usd.approve(address(spender), 42e6);
        vm.expectEmit(address(spender));
        emit CardSpender.CardSpent("auth.1", alice, aliceCollateral, address(usd), 42e6, 42e6, 0, 0);
        vm.prank(alice);
        spender.spend(s);
        vm.prank(alice);
        usd.approve(address(spender), 0);
        assertEq(usd.balanceOf(aliceCollateral), 42e6);
        assertEq(usd.balanceOf(alice), 958e6);
        assertEq(usd.allowance(alice, address(spender)), 0, "no standing allowance");
        assertEq(usd.balanceOf(address(spender)), 0);
    }

    function test_publicSpend_fromEarn_redeemsExactlyTheSpend() public {
        uint256 shares = _depositEarn(alice, 500e6);
        uint256 cost = earnVault.previewWithdraw(30e6);
        CardSpend memory s = _earnSpend(aliceCollateral, aliceIndex, 30e6, 30e6, "auth.earn");
        _publicSpend(alice, s);
        assertEq(usd.balanceOf(aliceCollateral), 30e6, "collateral funded in the vault asset");
        assertEq(earnShare.balanceOf(alice), shares - cost, "burned only what the spend cost");
        assertEq(earnShare.balanceOf(address(spender)), 0);
    }

    function test_publicSpend_splitAcrossStableAndEarn() public {
        _depositEarn(alice, 500e6);
        uint256 stableBefore = usd.balanceOf(alice);
        CardSpend memory s = _earnSpend(aliceCollateral, aliceIndex, 50e6, 20e6, "auth.split");
        _publicSpend(alice, s);
        assertEq(usd.balanceOf(aliceCollateral), 50e6);
        assertEq(stableBefore - usd.balanceOf(alice), 30e6);
    }

    function test_availableBalance_countsAllowedVault() public {
        uint256 shares = _depositEarn(alice, 400e6);
        assertEq(spender.availableBalance(alice, address(usd), address(0)), 600e6);
        assertEq(
            spender.availableBalance(alice, address(usd), address(earnVault)), 600e6 + earnVault.previewRedeem(shares)
        );
    }

    function test_revert_anotherCardholdersCollateral() public {
        CardSpend memory s = _stableSpend(bobCollateral, bobIndex, 1e6, "steal");
        vm.prank(alice);
        usd.approve(address(spender), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, bobCollateral));
        spender.spend(s);
    }

    /// @dev Alice hands Bob ownership of her collateral, which keeps her as its only admin: Bob's spends
    ///      cannot fund it until he also administers it, at which point Rain lets him withdraw it.
    function test_revert_transferredCollateralWithoutAdminRights() public {
        vm.prank(alice);
        (bool ok,) = aliceCollateral.call(abi.encodeWithSignature("transferOwnership(address)", bob));
        assertTrue(ok);
        CardSpend memory s = _stableSpend(aliceCollateral, aliceIndex, 1e6, "transferred");
        vm.prank(bob);
        usd.approve(address(spender), 1e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, aliceCollateral));
        spender.spend(s);

        vm.prank(bob);
        (ok,) = aliceCollateral.call(abi.encodeWithSignature("addAdmin(address)", bob));
        assertTrue(ok);
        assertTrue(program.isAuthorizedDestination(bob, aliceCollateral, address(usd), aliceIndex));
        assertFalse(program.isAuthorizedDestination(alice, aliceCollateral, address(usd), aliceIndex));
    }

    function test_publicSpend_programCollateral_isAuthorizedForAnyPayer() public {
        _publicSpend(alice, _stableSpend(programCollateral, programCollateralIndex, 5e6, "pooled"));
        assertEq(usd.balanceOf(programCollateral), 5e6);
    }

    function test_revert_wrongIndex() public {
        CardSpend memory s = _stableSpend(aliceCollateral, bobIndex, 1e6, "index");
        vm.prank(alice);
        usd.approve(address(spender), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, aliceCollateral));
        spender.spend(s);
    }

    /// @dev A proxy on Rain's own beacon, owned by Alice, that Rain's factory did not create.
    function test_revert_collateralNotFromRainsFactory() public {
        vm.prank(alice);
        address fake = address(
            new BeaconProxy(rain.factory.getBeacon(), abi.encodeWithSignature("initialize(string,address)", "x", alice))
        );
        // The factory never recorded it, at any index.
        for (uint256 i; i < 6; ++i) {
            assertFalse(program.isAuthorizedDestination(alice, fake, address(usd), i));
        }
    }

    function test_revert_beaconIsNotADestination() public view {
        for (uint256 i; i < 4; ++i) {
            assertFalse(program.isAuthorizedDestination(alice, rain.factory.getBeacon(), address(usd), i));
        }
    }

    function test_revert_indexPastTheEnd() public view {
        assertFalse(program.isAuthorizedDestination(alice, aliceCollateral, address(usd), 3));
        assertFalse(program.isAuthorizedDestination(alice, aliceCollateral, address(usd), type(uint256).max));
    }

    function test_revert_tokenNotAccepted() public {
        otherUsd.mint(alice, 10e6);
        CardSpend memory s = _stableSpend(aliceCollateral, aliceIndex, 1e6, "token");
        s.token = address(otherUsd);
        vm.prank(alice);
        otherUsd.approve(address(spender), 1e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.DestinationNotAuthorized.selector, aliceCollateral));
        spender.spend(s);
    }

    function test_revert_wrongProgram() public {
        CardSpend memory s = _stableSpend(aliceCollateral, aliceIndex, 1e6, "program");
        s.program = address(0xBEEF);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.WrongProgram.selector, address(0xBEEF)));
        spender.spend(s);
    }

    function test_revert_invalidAmounts() public {
        CardSpend memory s = _stableSpend(aliceCollateral, aliceIndex, 0, "zero");
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
        CardSpender noEarn = new CardSpender(_deployProgram(address(0)));
        _depositEarn(alice, 100e6);
        CardSpend memory s = _earnSpend(aliceCollateral, aliceIndex, 10e6, 10e6, "vault");
        s.program = address(noEarn.PROGRAM());
        vm.prank(alice);
        earnShare.approve(address(noEarn), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.VaultNotAllowed.selector, address(earnVault)));
        noEarn.spend(s);
    }

    function test_revert_shareCostAboveQuote() public {
        _depositEarn(alice, 100e6);
        CardSpend memory s = _earnSpend(aliceCollateral, aliceIndex, 10e6, 10e6, "quote");
        uint256 required = earnVault.previewWithdraw(10e6);
        s.maxShares = required - 1;
        vm.prank(alice);
        earnShare.approve(address(spender), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CardSpender.ShareCostExceeded.selector, required, required - 1));
        spender.spend(s);
    }

    function test_revert_noApproval() public {
        CardSpend memory s = _stableSpend(aliceCollateral, aliceIndex, 1e6, "approval");
        vm.prank(alice);
        vm.expectRevert();
        spender.spend(s);
    }

    function testFuzz_publicSpend_split(uint256 amount, uint256 fromVault) public {
        _depositEarn(alice, 500e6);
        amount = bound(amount, 1, 400e6);
        fromVault = bound(fromVault, 0, amount);
        uint256 total = usd.balanceOf(alice) + earnVault.previewRedeem(earnShare.balanceOf(alice));
        CardSpend memory s = _earnSpend(aliceCollateral, aliceIndex, amount, fromVault, "fuzz");
        if (fromVault == 0) s.vault = address(0);
        _publicSpend(alice, s);
        assertEq(usd.balanceOf(aliceCollateral), amount, "collateral got exactly the spend");
        uint256 left = usd.balanceOf(alice) + earnVault.previewRedeem(earnShare.balanceOf(alice));
        // Rounding in the vault's favor costs at most a unit or two.
        assertApproxEqAbs(total - left, amount, 2);
        assertGe(total - left, amount);
    }
}
