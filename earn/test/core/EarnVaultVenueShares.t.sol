// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { FeeConfig, FixedFeeRecipient } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnFees } from "../../src/interfaces/core/IEarnFees.sol";
import { IEarnEngineInKindDeposit } from "../../src/interfaces/engines/IEarnEngineInKindDeposit.sol";
import { CoreMockEngine, CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract EarnVaultVenueShareDepositTest is Test {
    CoreMockToken asset;
    CoreMockToken earnShare;
    Simple4626Vault venue;
    ERC4626Engine engine;
    EarnVault earnVault;

    address user = address(0xA11CE);
    address receiver = address(0xB0B);
    address funder = address(0xF00D);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        earnShare = new CoreMockToken("Earn", "EARN", 18);
        venue = new Simple4626Vault(address(asset), "Existing Vault", "xVAULT", 18);
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        earnVault = EarnVaultTestDeployer.deploy(
            address(engine), address(earnShare), address(0x0FF1CE), earnVaultTestNoFees()
        );
        engine.initializeEarnVault(address(earnVault));
    }

    function testExistingVenueSharesMintAtCurrentEarnRate() public {
        asset.mint(funder, 200 ether);
        vm.startPrank(funder);
        asset.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(100 ether, funder, 100 ether);
        earnVault.contribute(100 ether);
        vm.stopPrank();

        _mintVenueShares(user, 100 ether);
        vm.startPrank(user);
        venue.approve(address(engine), 100 ether);
        uint256 minted = earnVault.depositVenueShares(100 ether, user, 50 ether);
        vm.stopPrank();

        assertEq(minted, 50 ether);
        assertEq(earnShare.balanceOf(user), 50 ether);
        assertEq(earnVault.engineShares(), 300 ether);
        assertEq(earnVault.totalEarnShares(), 150 ether);
        assertTrue(earnVault.isAccountingAligned());
    }

    function testInKindDepositCannotRecapitalizeValuelessExistingVenueShares() public {
        _mintVenueShares(funder, 200 ether);
        vm.startPrank(funder);
        venue.approve(address(engine), 100 ether);
        earnVault.depositVenueShares(100 ether, funder, 100 ether);
        vm.stopPrank();

        _removeAllVenueAssetsWithoutBurningShares();
        assertEq(engine.totalShares(), 100 ether);
        assertEq(engine.totalAssets(), 0);
        assertEq(venue.balanceOf(funder), 100 ether);

        vm.startPrank(funder);
        venue.approve(address(engine), 100 ether);
        vm.expectRevert(EarnVault.ActiveSupplyWithoutBacking.selector);
        earnVault.depositVenueShares(100 ether, funder, 1);
        vm.stopPrank();

        assertEq(venue.balanceOf(funder), 100 ether);
        assertEq(venue.balanceOf(address(engine)), 100 ether);
        assertEq(earnShare.balanceOf(funder), 100 ether);
        assertEq(engine.totalAssets(), 0);
    }

    function testExistingVenueSharesArePrincipalNotFeeableAccrual() public {
        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(receiver, 1_000);
        CoreMockToken feeEarnShare = new CoreMockToken("Fee Earn", "fEARN", 18);
        ERC4626Engine feeEngine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        EarnVault feeEarnVault =
            EarnVaultTestDeployer.deploy(address(feeEngine), address(feeEarnShare), address(this), config);
        feeEngine.initializeEarnVault(address(feeEarnVault));

        _mintVenueShares(user, 100 ether);
        _mintVenueShares(funder, 100 ether);

        vm.startPrank(user);
        venue.approve(address(feeEngine), 100 ether);
        feeEarnVault.depositVenueShares(100 ether, user, 100 ether);
        vm.stopPrank();

        // The fee engine owns half the vault shares, so this 20-asset donation creates 10 assets of
        // positive accrual for Earn and a 1-asset fixed fee before the second holder enters.
        asset.mint(address(venue), 20 ether);
        IEarnFees feeModule = IEarnFees(feeEarnVault.earnFees());
        assertEq(feeModule.previewAccruedFees().totalFeeAssets, 1 ether);

        vm.startPrank(funder);
        venue.approve(address(feeEngine), 100 ether);
        feeEarnVault.depositVenueShares(100 ether, funder, 1);
        vm.stopPrank();

        assertGt(feeModule.claimableEarnShares(receiver), 0);
        assertEq(feeModule.previewAccruedFees().totalFeeAssets, 0);
        assertTrue(feeEarnVault.isAccountingAligned());
    }

    function testExactWithdrawalCannotBurnFinalShareAndStrandVenueAssets() public {
        _leaveUserOneShareWorthOneHundredAssets();

        vm.startPrank(user);
        vm.expectRevert(EarnVault.ResidualBacking.selector);
        earnVault.withdrawExact(40, receiver, 1);
        vm.stopPrank();

        assertEq(asset.balanceOf(receiver), 0);
        assertEq(asset.balanceOf(address(venue)), 100);
        assertEq(venue.totalSupply(), 1);
        assertEq(venue.balanceOf(address(engine)), 1);
        assertEq(earnShare.totalSupply(), 1);
        assertEq(earnShare.balanceOf(user), 1);
        assertTrue(earnVault.isAccountingAligned());
    }

    function testExactWithdrawalCanConsumeFinalShareWhenTakingAllVenueAssets() public {
        _leaveUserOneShareWorthOneHundredAssets();

        vm.prank(user);
        assertEq(earnVault.withdrawExact(100, receiver, 1), 1);

        assertEq(asset.balanceOf(receiver), 100);
        assertEq(asset.balanceOf(address(venue)), 0);
        assertEq(venue.totalSupply(), 0);
        assertEq(earnShare.totalSupply(), 0);
        assertTrue(earnVault.isAccountingAligned());
    }

    function testInKindEntryRejectsEngineWithoutInKindCapability() public {
        CoreMockEngine plainEngine = new CoreMockEngine(asset, 18);
        EarnVault plainVault = EarnVaultTestDeployer.deploy(
            address(plainEngine), address(earnShare), address(0x0FF1CE), earnVaultTestNoFees()
        );
        asset.mint(user, 10 ether);
        plainEngine.mintShares(user, 5 ether);
        vm.startPrank(user);
        asset.approve(address(plainVault), 10 ether);
        plainVault.deposit(10 ether, user, 10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                EarnVault.EngineCapabilityUnsupported.selector, type(IEarnEngineInKindDeposit).interfaceId
            )
        );
        plainVault.depositVenueShares(5 ether, user, 1);
        vm.stopPrank();

        assertEq(plainEngine.balanceOf(user), 5 ether);
        assertEq(earnShare.balanceOf(user), 10 ether);
        assertEq(plainVault.engineShares(), 10 ether);
        assertTrue(plainVault.isAccountingAligned());
    }

    function _mintVenueShares(address to, uint256 assets) internal {
        asset.mint(to, assets);
        vm.startPrank(to);
        asset.approve(address(venue), assets);
        venue.deposit(assets, to);
        vm.stopPrank();
    }

    function _removeAllVenueAssetsWithoutBurningShares() internal {
        uint256 venueAssets = asset.balanceOf(address(venue));
        vm.prank(address(venue));
        asset.burn(venueAssets);
    }

    function _leaveUserOneShareWorthOneHundredAssets() internal {
        asset.mint(user, 1 ether);
        vm.startPrank(user);
        asset.approve(address(earnVault), 1 ether);
        earnVault.deposit(1 ether, user, 1 ether);
        earnShare.approve(address(earnVault), type(uint256).max);
        earnVault.redeem(1 ether - 1, user, 1 ether - 1);
        vm.stopPrank();

        asset.mint(address(venue), 99);
        assertEq(venue.previewRedeem(1), 100);
        assertEq(earnVault.previewWithdraw(40), 1);
    }
}
