// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { FaultyMockToken } from "../helpers/EarnVaultMocks.sol";
import { ILocalMorphoVault, LocalMorphoFeeWrapper } from "../../script/local/contracts/LocalMorphoFeeWrapper.sol";

/// @dev Exercises actual ERC-4626 custody and rounding with an independently held venue position.
contract LocalMorphoFeeWrapperTest is Test {
    FaultyMockToken private asset;
    Simple4626Vault private venue;
    LocalMorphoFeeWrapper private wrapper;

    address private constant HOLDER = address(0xA11CE);
    address private constant ENTRANT = address(0xB0B);
    address private constant OUTSIDER = address(0xCAFE);
    address private constant SPENDER = address(0xDE1E);

    function setUp() public {
        asset = new FaultyMockToken("Asset", "AST", 6);
        venue = new Simple4626Vault(address(asset), "Local venue", "VENUE", 6);
        wrapper = new LocalMorphoFeeWrapper(ILocalMorphoVault(address(venue)));
    }

    function testTinyRedeemCannotBurnAllVenueBacking() public {
        _seedVenue(1, 1e12);
        assertEq(_deposit(HOLDER, 1e12), 1e12);
        assertEq(venue.balanceOf(address(wrapper)), 1);
        assertEq(wrapper.convertToAssets(1), 1);
        assertEq(wrapper.previewRedeem(1), 0);

        vm.prank(HOLDER);
        wrapper.approve(SPENDER, 1);
        vm.prank(SPENDER);
        vm.expectRevert(LocalMorphoFeeWrapper.InsufficientOutput.selector);
        wrapper.redeem(1, SPENDER, HOLDER);

        assertEq(wrapper.balanceOf(HOLDER), 1e12);
        assertEq(wrapper.totalSupply(), 1e12);
        assertEq(wrapper.allowance(HOLDER, SPENDER), 1);
        assertEq(venue.balanceOf(address(wrapper)), 1);
        assertEq(wrapper.totalAssets(), 1e12);
        assertEq(asset.balanceOf(SPENDER), 0);

        vm.prank(HOLDER);
        assertEq(wrapper.redeem(1e12, HOLDER, HOLDER), 1e12);
        assertEq(asset.balanceOf(HOLDER), 1e12);
        assertEq(wrapper.totalSupply(), 0);
        assertEq(venue.balanceOf(address(wrapper)), 0);
        assertEq(venue.previewRedeem(venue.balanceOf(OUTSIDER)), 1e12);
    }

    function testPartialRedeemRoundsVenueSharesDownAndFinalRedeemClearsBacking() public {
        _seedVenue(1, 100);
        _deposit(HOLDER, 300);
        uint256 preview = wrapper.previewRedeem(150);
        assertEq(preview, 100);

        vm.prank(HOLDER);
        wrapper.approve(SPENDER, 150);
        vm.prank(SPENDER);
        assertEq(wrapper.redeem(150, SPENDER, HOLDER), preview);

        assertEq(asset.balanceOf(SPENDER), 100);
        assertEq(wrapper.allowance(HOLDER, SPENDER), 0);
        assertEq(wrapper.balanceOf(HOLDER), 150);
        assertEq(venue.balanceOf(address(wrapper)), 2);
        assertEq(wrapper.totalAssets(), 200);
        assertEq(wrapper.previewRedeem(150), 200);

        vm.prank(HOLDER);
        assertEq(wrapper.redeem(150, HOLDER, HOLDER), 200);
        assertEq(wrapper.totalSupply(), 0);
        assertEq(wrapper.totalAssets(), 0);
        assertEq(venue.balanceOf(address(wrapper)), 0);
    }

    function testRoundedDepositDoesNotDiluteExistingHolderWithOutsideVenueShares() public {
        _seedVenue(1, 100);
        assertEq(_deposit(HOLDER, 100), 100);
        uint256 before = wrapper.previewRedeem(wrapper.balanceOf(HOLDER));
        assertEq(before, 100);
        assertEq(wrapper.convertToShares(199), 199);
        assertEq(wrapper.previewDeposit(199), 100);

        uint256 minted = _deposit(ENTRANT, 199);
        assertEq(minted, 100);
        assertEq(wrapper.totalSupply(), 200);
        assertEq(venue.balanceOf(address(wrapper)), 2);
        assertEq(venue.balanceOf(OUTSIDER), 1);
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(HOLDER)), 133);

        uint256 holderShares = wrapper.balanceOf(HOLDER);
        vm.prank(HOLDER);
        uint256 redeemed = wrapper.redeem(holderShares, HOLDER, HOLDER);
        assertGe(redeemed, before);
        assertEq(redeemed, 133);
        assertEq(asset.balanceOf(HOLDER), redeemed);
        assertEq(wrapper.previewRedeem(minted), 133);
        vm.prank(ENTRANT);
        assertEq(wrapper.redeem(minted, ENTRANT, ENTRANT), 133);
        assertEq(wrapper.totalSupply(), 0);
        assertEq(venue.balanceOf(address(wrapper)), 0);
        assertEq(venue.previewRedeem(venue.balanceOf(OUTSIDER)), 133);
    }

    function testZeroVenueShareDepositRollsBackCustodyAndSupply() public {
        _seedVenue(1, 100);
        _deposit(HOLDER, 100);
        asset.mint(ENTRANT, 1);
        vm.prank(ENTRANT);
        asset.approve(address(wrapper), 1);
        assertEq(wrapper.previewDeposit(1), 0);

        vm.prank(ENTRANT);
        vm.expectRevert(Simple4626Vault.InsufficientOutput.selector);
        wrapper.deposit(1, ENTRANT);

        assertEq(asset.balanceOf(ENTRANT), 1);
        assertEq(asset.allowance(ENTRANT, address(wrapper)), 1);
        assertEq(asset.balanceOf(address(wrapper)), 0);
        assertEq(wrapper.totalSupply(), 100);
        assertEq(wrapper.balanceOf(ENTRANT), 0);
        assertEq(venue.balanceOf(address(wrapper)), 1);
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(HOLDER)), 100);
    }

    function testZeroWrapperShareDepositRollsBackCompletedVenueDeposit() public {
        _seedVenue(100, 1);
        _deposit(HOLDER, 1);
        vm.prank(OUTSIDER);
        venue.transfer(address(wrapper), 100);
        asset.mint(ENTRANT, 1);
        vm.prank(ENTRANT);
        asset.approve(address(wrapper), 1);
        assertEq(wrapper.previewDeposit(1), 0);

        vm.prank(ENTRANT);
        vm.expectRevert(LocalMorphoFeeWrapper.InsufficientOutput.selector);
        wrapper.deposit(1, ENTRANT);

        assertEq(asset.balanceOf(ENTRANT), 1);
        assertEq(asset.allowance(ENTRANT, address(wrapper)), 1);
        assertEq(asset.balanceOf(address(wrapper)), 0);
        assertEq(asset.balanceOf(address(venue)), 101);
        assertEq(wrapper.totalSupply(), 1);
        assertEq(wrapper.balanceOf(ENTRANT), 0);
        assertEq(venue.totalSupply(), 101);
        assertEq(venue.balanceOf(address(wrapper)), 101);
        assertEq(wrapper.previewRedeem(wrapper.balanceOf(HOLDER)), 101);
    }

    function testVenueExitFailureRollsBackBurnAndAllowance() public {
        _deposit(HOLDER, 100);
        vm.prank(HOLDER);
        wrapper.approve(SPENDER, 100);
        asset.setBlockedRecipient(ENTRANT, true);

        vm.prank(SPENDER);
        vm.expectRevert(Simple4626Vault.TokenCallFailed.selector);
        wrapper.redeem(100, ENTRANT, HOLDER);

        assertEq(wrapper.totalSupply(), 100);
        assertEq(wrapper.balanceOf(HOLDER), 100);
        assertEq(wrapper.allowance(HOLDER, SPENDER), 100);
        assertEq(venue.balanceOf(address(wrapper)), 100);
        assertEq(wrapper.totalAssets(), 100);
        assertEq(asset.balanceOf(ENTRANT), 0);
    }

    function testDepositsAndYieldRemainAssetDenominated() public {
        assertEq(wrapper.previewDeposit(1_000e6), 1_000e6);
        assertEq(_deposit(HOLDER, 1_000e6), 1_000e6);
        assertEq(_deposit(ENTRANT, 1_000e6), 1_000e6);
        asset.mint(address(venue), 1_000e6);
        assertEq(wrapper.totalAssets(), 3_000e6);
        assertEq(wrapper.previewRedeem(1_000e6), 1_500e6);

        vm.prank(HOLDER);
        assertEq(wrapper.redeem(1_000e6, HOLDER, HOLDER), 1_500e6);
        vm.prank(ENTRANT);
        assertEq(wrapper.redeem(1_000e6, ENTRANT, ENTRANT), 1_500e6);
        assertEq(asset.balanceOf(HOLDER), 1_500e6);
        assertEq(asset.balanceOf(ENTRANT), 1_500e6);
        assertEq(wrapper.totalSupply(), 0);
        assertEq(wrapper.totalAssets(), 0);
    }

    function testFuzzDepositCannotReduceExistingHolderExit(
        uint256 outsideShares,
        uint256 held,
        uint256 rate,
        uint256 assets
    ) public {
        outsideShares = bound(outsideShares, 1, 1e12);
        held = bound(held, 1, 1e12);
        rate = bound(rate, 1, 1e12);
        assets = bound(assets, rate * 2, rate * 1e6);
        _seedVenue(outsideShares, rate);
        // The first deposit also rounds, so wrapper and venue supplies need not share an integer ratio.
        uint256 shares = _deposit(HOLDER, held * rate + rate - 1);
        uint256 before = wrapper.previewRedeem(shares);
        uint256 preview = wrapper.previewDeposit(assets);
        assertEq(_deposit(ENTRANT, assets), preview);

        vm.prank(HOLDER);
        uint256 redeemed = wrapper.redeem(shares, HOLDER, HOLDER);
        assertGe(redeemed, before);
        assertEq(asset.balanceOf(HOLDER), redeemed);
        assertGt(wrapper.previewRedeem(wrapper.balanceOf(ENTRANT)), 0);
    }

    function testFuzzPartialRedeemNeverConsumesOtherHoldersVenueShares(uint256 held, uint256 rate, uint256 shares)
        public
    {
        held = bound(held, 1, 1e12);
        rate = bound(rate, 2, 1e12);
        _seedVenue(1, rate);
        uint256 supply = _deposit(HOLDER, held * rate);
        shares = bound(shares, 1, supply - 1);
        uint256 preview = wrapper.previewRedeem(shares);
        if (preview == 0) {
            vm.prank(HOLDER);
            vm.expectRevert(LocalMorphoFeeWrapper.InsufficientOutput.selector);
            wrapper.redeem(shares, HOLDER, HOLDER);
            assertEq(wrapper.totalSupply(), supply);
            assertEq(venue.balanceOf(address(wrapper)), held);
            return;
        }

        vm.prank(HOLDER);
        assertEq(wrapper.redeem(shares, HOLDER, HOLDER), preview);
        uint256 burned = held - venue.balanceOf(address(wrapper));
        assertLe(burned * supply, shares * held);
        assertEq(wrapper.totalSupply(), supply - shares);
        assertEq(asset.balanceOf(HOLDER), preview);
        assertGt(wrapper.totalAssets(), 0);
    }

    function _seedVenue(uint256 shares, uint256 rate) private {
        asset.mint(OUTSIDER, shares);
        vm.startPrank(OUTSIDER);
        asset.approve(address(venue), shares);
        venue.deposit(shares, OUTSIDER);
        vm.stopPrank();
        asset.mint(address(venue), shares * (rate - 1));
    }

    function _deposit(address owner, uint256 assets) private returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.startPrank(owner);
        asset.approve(address(wrapper), assets);
        shares = wrapper.deposit(assets, owner);
        vm.stopPrank();
    }
}
