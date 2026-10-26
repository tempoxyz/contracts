// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { FeeConfig, FeePreview, FixedFeeRecipient } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnFees } from "../../src/interfaces/core/IEarnFees.sol";
import { CoreMockEngine, CoreMockToken, MockRateEngine, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract MockShareScaleEngine is MockRateEngine {
    uint256 internal immutable _shareScale;

    constructor(CoreMockToken asset_, uint256 shareScale_) MockRateEngine(asset_, 1 ether) {
        _shareScale = shareScale_;
    }

    function shareScale() external view override returns (uint256) {
        return _shareScale;
    }
}

contract EarnVaultMigrateTest is Test {
    CoreMockToken asset;
    CoreMockToken share;
    Simple4626Vault venue;
    ERC4626Engine fromEngine;
    MockRateEngine toEngine;
    EarnVault core;

    address user = address(0xA11CE);
    address receiver = address(0xB0B);
    address operator = address(0x0FF1CE);
    address stranger = address(0xDEAD);

    // 1 share == 2 assets: 100 assets -> 50 venue shares, so the venue-share count halves on migrate.
    uint256 constant TO_RATE_WAD = 2e18;

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        share = new CoreMockToken("Share", "SH", 18);
        venue = new Simple4626Vault(address(asset), "Venue", "VEN", 18);
        fromEngine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        core = EarnVaultTestDeployer.deploy(address(fromEngine), address(share), operator, earnVaultTestNoFees());
        fromEngine.initializeEarnVault(address(core));

        toEngine = new MockRateEngine(asset, TO_RATE_WAD);
        toEngine.initializeEarnVault(address(core));

        asset.mint(user, 1_000 ether);
        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        share.approve(address(core), type(uint256).max);
        core.deposit(100 ether, user, 100 ether);
        vm.stopPrank();

        // The first deposit preserves the 1:1 rate and records the exact active pair.
        assertEq(core.anchorEngineShares(), 100 ether);
        assertEq(core.anchorEarnShares(), 100 ether);
        assertEq(core.totalEarnShares(), 100 ether);
        assertEq(core.engineShares(), 100 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testMigratePreservesSupplyNavAndBalancesAndReAnchors() public {
        uint256 supplyBefore = core.totalEarnShares();
        uint256 userBalBefore = share.balanceOf(user);

        vm.prank(operator);
        uint256 newShares = core.migrateEngine(address(toEngine), 50 ether, 100 ether);

        // Venue-share COUNT changed (100 -> 50) but TIP20 supply and user balances did NOT.
        assertEq(newShares, 50 ether);
        assertEq(core.engine(), address(toEngine));
        assertEq(core.engineShares(), 50 ether);
        assertEq(core.totalEarnShares(), supplyBefore); // TIP20 supply UNCHANGED
        assertEq(share.balanceOf(user), userBalBefore); // user balance UNTOUCHED
        assertEq(fromEngine.totalShares(), 0); // old engine fully drained

        // Re-anchor captured the new rate: R = 50/100 venue-shares per TIP20.
        assertEq(core.anchorEngineShares(), 50 ether);
        assertEq(core.anchorEarnShares(), 100 ether);
        assertEq(core.convertToEngineShares(100 ether), 50 ether);
        assertEq(core.convertEngineSharesToEarnShares(50 ether), 100 ether);
        assertTrue(core.isAccountingAligned());

        // NAV preserved: the new engine holds the same 100 assets of backing.
        assertEq(asset.balanceOf(address(toEngine)), 100 ether);
    }

    function testMigrationResetsFixedRewardRateBaselineForNewShareDenomination() public {
        assertEq(core.rewardRateBaseline(), 1 ether);

        vm.prank(operator);
        core.migrateEngine(address(toEngine), 50 ether, 100 ether);

        assertEq(core.normalizedRewardRate(), 0.5 ether);
        assertEq(core.rewardRateBaseline(), 0.5 ether);

        asset.mint(stranger, 100 ether);
        vm.startPrank(stranger);
        asset.approve(address(core), 100 ether);
        core.contribute(100 ether);
        vm.stopPrank();

        assertEq(core.normalizedRewardRate(), 1 ether);
        assertEq(core.rewardRateBaseline(), 0.5 ether);
    }

    function testEmptyingMigratedPoolResetsRewardRateBaselineBeforeNextDeposit() public {
        CoreMockToken localAsset = new CoreMockToken("Local Asset", "LAST", 18);
        CoreMockToken localShare = new CoreMockToken("Local Share", "LSH", 18);
        CoreMockEngine oldEngine = new CoreMockEngine(localAsset, 18);
        EarnVault localCore =
            EarnVaultTestDeployer.deploy(address(oldEngine), address(localShare), operator, earnVaultTestNoFees());
        MockRateEngine highRateEngine = new MockRateEngine(localAsset, 1_000 ether);
        highRateEngine.initializeEarnVault(address(localCore));

        localAsset.mint(user, 100 ether + 2_000);
        vm.startPrank(user);
        localAsset.approve(address(localCore), type(uint256).max);
        localShare.approve(address(localCore), type(uint256).max);
        localCore.deposit(100 ether, user, 100 ether);
        vm.stopPrank();

        vm.prank(operator);
        localCore.migrateEngine(address(highRateEngine), 0.1 ether, 100 ether);
        assertEq(localCore.rewardRateBaseline(), 0.001 ether);

        vm.prank(user);
        localCore.redeem(100 ether, user, 100 ether);

        assertEq(localCore.totalEarnShares(), 0);
        assertEq(localCore.engineShares(), 0);
        assertEq(localCore.anchorEngineShares(), 1 ether);
        assertEq(localCore.rewardRateBaseline(), 1 ether);

        vm.prank(user);
        assertEq(localCore.deposit(1_000, user, 1), 1);

        assertEq(localCore.totalEarnShares(), 1);
        assertEq(localCore.engineShares(), 1);
        assertEq(localCore.surplusEngineShares(), 0);
        assertTrue(localCore.isAccountingAligned());

        vm.prank(user);
        assertEq(localCore.redeem(1, user, 1_000), 1_000);
    }

    function testMigrationMovesManagedBackingAndQuarantinedSurplus() public {
        vm.startPrank(user);
        asset.approve(address(venue), 10 ether);
        assertEq(venue.deposit(10 ether, user), 10 ether);
        assertTrue(venue.transfer(address(fromEngine), 10 ether));
        vm.stopPrank();

        assertEq(core.engineShares(), 100 ether);
        assertEq(core.rawEngineShares(), 110 ether);
        assertEq(core.surplusEngineShares(), 10 ether);

        vm.prank(operator);
        uint256 newManagedShares = core.migrateEngine(address(toEngine), 50 ether, 100 ether);

        assertEq(newManagedShares, 50 ether);
        assertEq(fromEngine.totalShares(), 0);
        assertEq(core.engine(), address(toEngine));
        assertEq(core.engineShares(), 50 ether);
        assertEq(core.rawEngineShares(), 55 ether);
        assertEq(core.surplusEngineShares(), 5 ether);
        assertEq(core.previewRedeem(100 ether), 100 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testMigrateRejectsCoarseReplacementThatCannotPreserveMixedClassification() public {
        asset.mint(user, 9_900 ether);
        vm.startPrank(user);
        asset.approve(address(venue), 9_900 ether);
        assertEq(venue.deposit(9_900 ether, user), 9_900 ether);
        assertTrue(venue.transfer(address(fromEngine), 9_900 ether));
        vm.stopPrank();

        assertEq(core.engineShares(), 100 ether);
        assertEq(core.rawEngineShares(), 10_000 ether);

        // The complete replacement deposit produces one raw share. Rounding the 1% managed
        // fraction up to that share would otherwise reclassify all 9,900 surplus assets as backing.
        MockRateEngine coarseEngine = new MockRateEngine(asset, 10_000 ether * 1 ether);
        coarseEngine.initializeEarnVault(address(core));

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(EarnVault.ExcessiveMigrationClassificationError.selector, 100 ether, 10_000 ether)
        );
        core.migrateEngine(address(coarseEngine), 1, 100 ether);

        assertEq(core.engine(), address(fromEngine));
        assertEq(core.engineShares(), 100 ether);
        assertEq(core.rawEngineShares(), 10_000 ether);
        assertEq(fromEngine.totalShares(), 10_000 ether);
        assertEq(coarseEngine.totalShares(), 0);
        assertTrue(core.isAccountingAligned());
    }

    function testMigrateRejectsOldEngineAssetReturnMismatch() public {
        (CoreMockToken localAsset,, CoreMockEngine oldEngine, MockRateEngine replacement, EarnVault localCore) =
            _newMockMigrationPool();
        oldEngine.setRedeemReportOverride(99 ether);

        vm.prank(operator);
        vm.expectRevert(EarnVault.InsufficientOutput.selector);
        localCore.migrateEngine(address(replacement), 100 ether, 100 ether);

        assertEq(localCore.engine(), address(oldEngine));
        assertEq(oldEngine.totalShares(), 100 ether);
        assertEq(replacement.totalShares(), 0);
        assertEq(localAsset.balanceOf(address(localCore)), 0);
        assertTrue(localCore.isAccountingAligned());
    }

    function testMigrateRejectsReplacementThatDoesNotConsumeAllAssets() public {
        // The replacement pulls only half the measured source redemption and truthfully reports the
        // resulting share delta/value. Deliberately permissive output bounds would otherwise let the
        // migration switch engines while leaving the other half stranded on the EarnVault.
        toEngine.setDepositPullOverride(50 ether);

        vm.prank(operator);
        vm.expectRevert(EarnVault.InsufficientOutput.selector);
        core.migrateEngine(address(toEngine), 25 ether, 50 ether);

        assertEq(core.engine(), address(fromEngine));
        assertEq(core.engineShares(), 100 ether);
        assertEq(fromEngine.totalShares(), 100 ether);
        assertEq(toEngine.totalShares(), 0);
        assertEq(asset.balanceOf(address(core)), 0);
        assertEq(asset.balanceOf(address(toEngine)), 0);
        assertTrue(core.isAccountingAligned());
    }

    function testMigrateRejectsResidualOldEngineCustody() public {
        (,, CoreMockEngine oldEngine, MockRateEngine replacement, EarnVault localCore) = _newMockMigrationPool();
        oldEngine.setRedeemBurnOverride(99 ether);

        vm.prank(operator);
        vm.expectRevert(EarnVault.ResidualBacking.selector);
        localCore.migrateEngine(address(replacement), 99 ether, 99 ether);

        assertEq(localCore.engine(), address(oldEngine));
        assertEq(oldEngine.totalShares(), 100 ether);
        assertEq(replacement.totalShares(), 0);
        assertTrue(localCore.isAccountingAligned());
    }

    function testEmptyMigrationMovesPureSurplusOffAbandonedEngine() public {
        vm.startPrank(user);
        asset.approve(address(venue), 10 ether);
        assertEq(venue.deposit(10 ether, user), 10 ether);
        assertTrue(venue.transfer(address(fromEngine), 10 ether));
        core.redeem(100 ether, user, 100 ether);
        vm.stopPrank();

        assertEq(core.totalEarnShares(), 0);
        assertEq(core.engineShares(), 0);
        assertEq(core.rawEngineShares(), 10 ether);
        assertEq(core.surplusEngineShares(), 10 ether);

        vm.prank(operator);
        assertEq(core.migrateEngine(address(toEngine), 5 ether, 10 ether), 0);

        assertEq(fromEngine.totalShares(), 0);
        assertEq(core.engine(), address(toEngine));
        assertEq(core.engineShares(), 0);
        assertEq(core.rawEngineShares(), 5 ether);
        assertEq(core.surplusEngineShares(), 5 ether);
        assertEq(core.totalAssets(), 0);
        assertTrue(core.isAccountingAligned());
    }

    function testPureSurplusMigrationRequiresAndEnforcesTotalOutputBounds() public {
        vm.startPrank(user);
        asset.approve(address(venue), 10 ether);
        assertEq(venue.deposit(10 ether, user), 10 ether);
        assertTrue(venue.transfer(address(fromEngine), 10 ether));
        core.redeem(100 ether, user, 100 ether);
        vm.stopPrank();

        Simple4626Vault inflatedVenue = new Simple4626Vault(address(asset), "Inflated", "INF", 18);
        ERC4626Engine inflatedEngine = new ERC4626Engine(IERC4626Vault(address(inflatedVenue)), address(this), "", "");
        inflatedEngine.initializeEarnVault(address(core));

        asset.mint(stranger, 6 ether + 1);
        vm.startPrank(stranger);
        asset.approve(address(inflatedVenue), type(uint256).max);
        inflatedVenue.deposit(1, stranger);
        inflatedVenue.donate(6 ether);
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(EarnVault.ZeroMinimumEngineShares.selector);
        core.migrateEngine(address(inflatedEngine), 0, 10 ether);
        vm.expectRevert(EarnVault.ZeroMinimumAssets.selector);
        core.migrateEngine(address(inflatedEngine), 1, 0);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.MinimumAssetsNotMet.selector, 10 ether, 8 ether));
        core.migrateEngine(address(inflatedEngine), 1, 10 ether);
        vm.stopPrank();

        assertEq(core.engine(), address(fromEngine));
        assertEq(core.engineShares(), 0);
        assertEq(core.rawEngineShares(), 10 ether);
        assertEq(fromEngine.totalShares(), 10 ether);
        assertEq(inflatedEngine.totalShares(), 0);
        assertTrue(core.isAccountingAligned());
    }

    function testMigrateRejectsInflatedDestinationBelowRetainedAssetMinimum() public {
        Simple4626Vault inflatedVenue = new Simple4626Vault(address(asset), "Inflated", "INF", 18);
        ERC4626Engine inflatedEngine = new ERC4626Engine(IERC4626Vault(address(inflatedVenue)), address(this), "", "");
        inflatedEngine.initializeEarnVault(address(core));

        asset.mint(stranger, 60 ether + 1);
        vm.startPrank(stranger);
        asset.approve(address(inflatedVenue), type(uint256).max);
        inflatedVenue.deposit(1, stranger);
        inflatedVenue.donate(60 ether);
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.MinimumAssetsNotMet.selector, 100 ether, 80 ether));
        core.migrateEngine(address(inflatedEngine), 1, 100 ether);

        assertEq(core.engine(), address(fromEngine));
        assertEq(core.engineShares(), 100 ether);
        assertEq(inflatedEngine.totalShares(), 0);
        assertEq(core.totalEarnShares(), 100 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testMigrateRequiresAndEnforcesOutputBounds() public {
        vm.startPrank(operator);
        vm.expectRevert(EarnVault.ZeroMinimumEngineShares.selector);
        core.migrateEngine(address(toEngine), 0, 100 ether);
        vm.expectRevert(EarnVault.ZeroMinimumAssets.selector);
        core.migrateEngine(address(toEngine), 50 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.MinimumEngineSharesNotMet.selector, 50 ether + 1, 50 ether));
        core.migrateEngine(address(toEngine), 50 ether + 1, 100 ether);
        vm.stopPrank();

        assertEq(core.engine(), address(fromEngine));
        assertEq(core.engineShares(), 100 ether);
        assertEq(core.totalEarnShares(), 100 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testFeeAccrualReanchorsWhenProjectedSupplyOnlyFloorMapsToHeldShares() public {
        CoreMockToken feeAsset = new CoreMockToken("Fee Asset", "FAST", 18);
        CoreMockToken feeShare = new CoreMockToken("Fee Share", "FSH", 18);
        Simple4626Vault feeVenue = new Simple4626Vault(address(feeAsset), "Fee Venue", "FVEN", 18);
        ERC4626Engine feeFromEngine = new ERC4626Engine(IERC4626Vault(address(feeVenue)), address(this), "", "");

        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(address(this), 2_500);
        EarnVault feeCore = EarnVaultTestDeployer.deploy(address(feeFromEngine), address(feeShare), operator, config);
        feeFromEngine.initializeEarnVault(address(feeCore));

        MockRateEngine feeToEngine = new MockRateEngine(feeAsset, TO_RATE_WAD);
        feeToEngine.initializeEarnVault(address(feeCore));
        feeAsset.mint(user, 4);
        vm.startPrank(user);
        feeAsset.approve(address(feeCore), type(uint256).max);
        feeShare.approve(address(feeCore), type(uint256).max);
        feeCore.deposit(4, user, 4);
        vm.stopPrank();

        vm.prank(operator);
        feeCore.migrateEngine(address(feeToEngine), 2, 4);
        feeAsset.mint(address(feeToEngine), 16);

        IEarnFees feeModule = IEarnFees(feeCore.earnFees());
        FeePreview memory fees = feeModule.previewAccruedFees();
        assertEq(fees.totalFeeAssets, 4);
        assertEq(fees.totalFeeEarnShares, 1);
        assertEq(feeCore.previewRedeem(2), 0);
        assertEq(feeCore.previewWithdraw(1), 3);

        feeCore.accrueFees();
        assertEq(feeCore.anchorEngineShares(), 2);
        assertEq(feeCore.anchorEarnShares(), 5);
        assertEq(feeModule.claimableEarnShares(address(this)), 1);
        assertTrue(feeCore.isAccountingAligned());

        vm.prank(user);
        vm.expectRevert(EarnVault.InsufficientOutput.selector);
        feeCore.redeem(2, receiver, 1);

        vm.prank(user);
        assertEq(feeCore.redeem(4, receiver, 10), 10);
        assertEq(feeCore.engineShares(), 1);
        assertEq(feeCore.totalEarnShares(), 1);

        feeModule.claim(address(this), 1);
        feeShare.approve(address(feeCore), 1);
        assertEq(feeCore.redeem(1, address(this), 10), 10);
        assertEq(feeCore.engineShares(), 0);
        assertEq(feeCore.totalEarnShares(), 0);
    }

    function testMigrateRevertsIfDepositLegFailsAndPoolStaysOnOldEngine() public {
        toEngine.setRevertOnDeposit(true);

        vm.prank(operator);
        vm.expectRevert(); // leg 2 reverts -> whole tx (including the leg-1 redeem) rolls back
        core.migrateEngine(address(toEngine), 1, 1);

        // Pool is entirely intact on the OLD engine.
        assertEq(core.engine(), address(fromEngine));
        assertEq(core.engineShares(), 100 ether);
        assertEq(core.totalEarnShares(), 100 ether);
        assertEq(venue.balanceOf(address(fromEngine)), 100 ether);
        assertEq(core.anchorEngineShares(), 100 ether);
        assertEq(core.anchorEarnShares(), 100 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testMigrateIsOperatorOnly() public {
        vm.prank(stranger);
        vm.expectRevert(EarnVault.NotOperator.selector);
        core.migrateEngine(address(toEngine), 1, 1);
    }

    function testEmptyMigrationUsesNewEngineShareScale() public {
        vm.prank(user);
        core.redeem(100 ether, user, 100 ether);

        MockShareScaleEngine sixDecimalEngine = new MockShareScaleEngine(asset, 1e6);
        sixDecimalEngine.initializeEarnVault(address(core));
        vm.prank(operator);
        assertEq(core.migrateEngine(address(sixDecimalEngine), 0, 0), 0);

        assertEq(core.totalEarnShares(), 0);
        assertEq(core.engineShares(), 0);
        assertEq(core.anchorEngineShares(), 1e6);
        assertEq(core.anchorEarnShares(), 1e18);
    }

    function testEmptyMigrationRejectsReplacementNotBoundToThisVault() public {
        vm.prank(user);
        core.redeem(100 ether, user, 100 ether);

        MockRateEngine unbound = new MockRateEngine(asset, 1 ether);
        vm.prank(operator);
        vm.expectRevert(EarnVault.EngineEarnVaultMismatch.selector);
        core.migrateEngine(address(unbound), 0, 0);

        unbound.initializeEarnVault(stranger);
        vm.prank(operator);
        vm.expectRevert(EarnVault.EngineEarnVaultMismatch.selector);
        core.migrateEngine(address(unbound), 0, 0);

        assertEq(core.engine(), address(fromEngine));
        assertEq(core.anchorEngineShares(), 1 ether);
        assertEq(core.anchorEarnShares(), 1 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testMigrateRejectsAssetMismatch() public {
        CoreMockToken otherAsset = new CoreMockToken("Other", "OTH", 18);
        MockRateEngine mismatched = new MockRateEngine(otherAsset, 1e18);
        vm.prank(operator);
        vm.expectRevert(EarnVault.EngineAssetMismatch.selector);
        core.migrateEngine(address(mismatched), 1, 1);
    }

    function testMigrateRejectsEngineWithoutExitCapabilityBeforeMovingBacking() public {
        (,, CoreMockEngine oldEngine,, EarnVault localCore) = _newMockMigrationPool();
        CoreMockEngine replacement = new CoreMockEngine(CoreMockToken(oldEngine.asset()), 18);
        replacement.setExitCapabilities(false, false);

        vm.prank(operator);
        vm.expectRevert(EarnVault.EngineExitUnsupported.selector);
        localCore.migrateEngine(address(replacement), 100 ether, 100 ether);

        assertEq(localCore.engine(), address(oldEngine));
        assertEq(oldEngine.totalShares(), 100 ether);
        assertEq(replacement.totalShares(), 0);
        assertEq(localCore.totalEarnShares(), 100 ether);
        assertTrue(localCore.isAccountingAligned());
    }

    function _newMockMigrationPool()
        private
        returns (
            CoreMockToken localAsset,
            CoreMockToken localShare,
            CoreMockEngine oldEngine,
            MockRateEngine replacement,
            EarnVault localCore
        )
    {
        localAsset = new CoreMockToken("Local Asset", "LAST", 18);
        localShare = new CoreMockToken("Local Share", "LSH", 18);
        oldEngine = new CoreMockEngine(localAsset, 18);
        localCore =
            EarnVaultTestDeployer.deploy(address(oldEngine), address(localShare), operator, earnVaultTestNoFees());
        replacement = new MockRateEngine(localAsset, 1 ether);
        replacement.initializeEarnVault(address(localCore));

        localAsset.mint(user, 100 ether);
        vm.startPrank(user);
        localAsset.approve(address(localCore), 100 ether);
        localCore.deposit(100 ether, user, 100 ether);
        vm.stopPrank();
    }
}
