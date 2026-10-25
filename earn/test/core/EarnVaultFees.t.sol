// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// EarnVault-to-EarnFees economic-equivalence coverage.
import { Test } from "forge-std/Test.sol";

import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { EarnFees } from "../../src/core/EarnFees.sol";
import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { ExcessReturnFee, FeeConfig, FeePreview, FixedFeeRecipient } from "../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnFees } from "../../src/interfaces/core/IEarnFees.sol";
import { DistributorConfig, DistributorFeeUpdate } from "../../src/interfaces/core/EarnVaultTypes.sol";
import { FaultyMockToken } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract EarnVaultFeesTest is Test {
    FaultyMockToken asset;
    FaultyMockToken share;
    Simple4626Vault venue;
    ERC4626Engine engine;
    EarnVault earnVault;
    IEarnFees fees;

    address user = address(0xA11CE);
    address secondUser = address(0xB0B);
    address fixedRecipient = address(0xF1);
    address secondFixedRecipient = address(0xF2);
    address thirdFixedRecipient = address(0xF3);
    address excessRecipient = address(0xE1);

    function setUp() public {
        _deploy(_fixedConfig(fixedRecipient, 1_000));
    }

    function testPrincipalDepositsDoNotCreateFees() public {
        _deposit(user, 100 ether);

        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.positiveAccrualAssets, 0);
        assertEq(preview.totalFeeAssets, 0);
        assertEq(fees.highWaterMark(), 1 ether);

        _deposit(secondUser, 100 ether);
        assertEq(fees.claimableEarnShares(fixedRecipient), 0);
        assertEq(share.balanceOf(user), 100 ether);
        assertEq(share.balanceOf(secondUser), 100 ether);
        assertEq(fees.highWaterMark(), 1 ether);
    }

    function testQuarantinedEngineSharesAreNotFeeableUntilAbsorbed() public {
        _deposit(user, 100 ether);

        asset.mint(secondUser, 100 ether);
        vm.startPrank(secondUser);
        asset.approve(address(venue), 100 ether);
        venue.deposit(100 ether, secondUser);
        assertTrue(venue.transfer(address(engine), 100 ether));
        vm.stopPrank();

        assertEq(earnVault.rawEngineShares(), 200 ether);
        assertEq(earnVault.engineShares(), 100 ether);
        assertEq(earnVault.surplusEngineShares(), 100 ether);
        assertEq(earnVault.totalAssets(), 100 ether);
        assertEq(fees.previewAccruedFees().totalFeeAssets, 0);

        earnVault.absorbEngineShareSurplus(100 ether);

        assertEq(earnVault.totalAssets(), 200 ether);
        assertEq(earnVault.surplusEngineShares(), 0);
        assertGt(fees.claimableEarnShares(fixedRecipient), 0);
    }

    function testHigherPrecisionEngineSharesAreNormalizedForFeeAccrual() public {
        _deployWithEngineShareDecimals(_fixedConfig(fixedRecipient, 1_000), 6, 18);

        _deposit(user, 100e6);
        assertEq(engine.shareScale(), 1e18);
        assertEq(engine.totalShares(), 100e18);
        assertEq(share.balanceOf(user), 100e6);
        assertEq(earnVault.anchorEngineShares(), 100e18);
        assertEq(earnVault.anchorEarnShares(), 100e6);
        assertEq(fees.highWaterMark(), 1e6);

        asset.mint(address(venue), 20e6);
        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.preFeeValuePerEarnShare, 1.2e6);
        assertEq(preview.positiveAccrualAssets, 20e6);
        assertEq(preview.totalFeeAssets, 2e6);

        (uint256 feeAssets, uint256 feeEarnShares) = earnVault.accrueFees();
        assertEq(feeAssets, 2e6);
        assertEq(feeEarnShares, 1_694_915);
        assertEq(fees.claimableEarnShares(fixedRecipient), feeEarnShares);
    }

    function testHigherPrecisionEngineNormalizesFirstInKindEntry() public {
        _deployWithEngineShareDecimals(_fixedConfig(fixedRecipient, 1_000), 6, 18);

        vm.startPrank(user);
        asset.approve(address(venue), 100e6);
        uint256 venueShares = venue.deposit(100e6, user);
        venue.approve(address(engine), venueShares);
        uint256 earnShares = earnVault.depositVenueShares(venueShares, user, 100e6);
        vm.stopPrank();

        assertEq(venueShares, 100e18);
        assertEq(earnShares, 100e6);
        assertEq(share.balanceOf(user), 100e6);
        assertEq(fees.highWaterMark(), 1e6);
    }

    function testFractionalHighWaterBandIsNotChargedAcrossCheckpoints() public {
        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        _deposit(user, 3);

        uint256 totalFeeAssets;
        for (uint256 i = 0; i < 100; i++) {
            asset.mint(address(venue), 1);
            (uint256 feeAssets,) = earnVault.accrueFees();
            totalFeeAssets += feeAssets;
        }

        assertEq(totalFeeAssets, 0);
        assertEq(fees.claimableEarnShares(fixedRecipient), 0);
        assertEq(fees.highWaterMark(), 34_333_334);
    }

    function testNoAccrualFastPathRoundsExcessTargetUp() public {
        FeeConfig memory config;
        config.excess = ExcessReturnFee(true, excessRecipient, 0, 10_000);
        _deployWithDecimals(config, 6);
        _deposit(user, 3_000_000);

        asset.mint(address(this), 3);
        asset.approve(address(earnVault), 3);
        earnVault.contribute(1);

        assertEq(fees.targetBase(), 1_000_001);
        assertEq(fees.claimableEarnShares(excessRecipient), 0);

        earnVault.contribute(2);

        assertEq(fees.claimableEarnShares(excessRecipient), 0);
        assertEq(fees.previewAccruedFees().totalFeeAssets, 0);
    }

    function testLaterDepositDoesNotMakeDustEntryPrincipalFeeable() public {
        _deployWithEngineShareDecimals(_fixedConfig(fixedRecipient, 1_000), 6, 18);

        vm.startPrank(user);
        asset.approve(address(venue), 2e6);
        assertEq(venue.deposit(2e6, user), 2e18);
        venue.approve(address(engine), 1e12);
        vm.stopPrank();
        asset.mint(address(venue), 1e6);

        vm.prank(user);
        assertEq(earnVault.depositVenueShares(1e12, user, 1), 1);
        assertEq(earnVault.totalAssets(), 1);
        assertEq(fees.highWaterMark(), 1e6);

        _deposit(secondUser, 300e6);

        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.positiveAccrualAssets, 0);
        assertEq(preview.totalFeeAssets, 0);
        assertEq(fees.highWaterMark(), 1_500_000);
    }

    function testPreviewRedeemIncludesPendingFeeDilutionAndMatchesRedeem() public {
        _deposit(user, 100 ether);
        asset.mint(address(venue), 20 ether);

        uint256 naiveAssets = engine.previewRedeem(earnVault.convertToEngineShares(100 ether));
        uint256 previewedAssets = earnVault.previewRedeem(100 ether);

        assertEq(naiveAssets, 120 ether);
        assertEq(earnVault.previewRedeem(100 ether), previewedAssets);
        assertApproxEqAbs(previewedAssets, 118 ether, 2);

        vm.prank(user);
        uint256 redeemedAssets = earnVault.redeem(100 ether, user, previewedAssets);
        assertEq(redeemedAssets, previewedAssets);
    }

    function testUnrepresentableFeeCheckpointDoesNotAmplifyLaterDeposit() public {
        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        _deposit(user, 1);

        asset.mint(address(this), 99);
        asset.approve(address(earnVault), 99);
        earnVault.contribute(99);

        assertEq(fees.highWaterMark(), 100_000_000);
        assertEq(fees.claimableEarnShares(fixedRecipient), 0);
        assertEq(fees.previewAccruedFees().totalFeeAssets, 0);

        _deposit(secondUser, 100_000_000);
        uint256 victimShares = share.balanceOf(secondUser);
        assertEq(victimShares, 1_000_000);
        assertEq(fees.previewAccruedFees().totalFeeAssets, 0);
        assertEq(earnVault.previewRedeem(victimShares), 100_000_000);
    }

    function testFixedFeeUsesCombinedYieldAndContributionsAndCanBeClaimed() public {
        _deposit(user, 100 ether);
        asset.mint(address(venue), 20 ether);

        FeePreview memory yieldPreview = fees.previewAccruedFees();
        assertEq(yieldPreview.positiveAccrualAssets, 20 ether);
        assertEq(yieldPreview.totalFeeAssets, 2 ether);
        uint256 expectedYieldFeeShares = uint256(2 ether) * 100 ether / 118 ether;
        assertEq(yieldPreview.totalFeeEarnShares, expectedYieldFeeShares);

        earnVault.accrueFees();
        assertEq(fees.claimableEarnShares(fixedRecipient), expectedYieldFeeShares);
        assertEq(fees.highWaterMark(), yieldPreview.postFeeValuePerEarnShare);

        asset.mint(address(this), 10 ether);
        asset.approve(address(earnVault), 10 ether);
        earnVault.contribute(10 ether);

        uint256 totalClaimable = fees.claimableEarnShares(fixedRecipient);
        assertGt(totalClaimable, expectedYieldFeeShares);
        assertEq(share.balanceOf(address(fees)), totalClaimable);

        vm.prank(fixedRecipient);
        fees.claim(fixedRecipient, totalClaimable);
        assertEq(share.balanceOf(fixedRecipient), totalClaimable);
        assertEq(fees.claimableEarnShares(fixedRecipient), 0);
        assertEq(fees.totalClaimableEarnShares(), 0);
    }

    function testBlockedFeeRecipientCannotBlockUserActions() public {
        _deposit(user, 100 ether);
        asset.mint(address(venue), 10 ether);
        earnVault.accrueFees();
        uint256 claimable = fees.claimableEarnShares(fixedRecipient);

        share.setForceTransferFalse(true);
        vm.prank(fixedRecipient);
        vm.expectRevert(EarnFees.InvalidFeeClaimReceiver.selector);
        fees.claim(fixedRecipient, claimable);
        assertEq(fees.claimableEarnShares(fixedRecipient), claimable);
        assertEq(fees.totalClaimableEarnShares(), claimable);
        assertEq(share.balanceOf(address(fees)), claimable);

        _deposit(secondUser, 100 ether);
        assertGt(share.balanceOf(secondUser), 0);

        share.setForceTransferFalse(false);
        vm.prank(fixedRecipient);
        fees.claim(fixedRecipient, claimable);
        assertEq(fees.totalClaimableEarnShares(), 0);
    }

    function testFixedAndExcessReturnFeesFollowWaterfall() public {
        FeeConfig memory config;
        config.fixedFeeCount = 2;
        config.fixedFees[0] = FixedFeeRecipient(fixedRecipient, 25);
        config.fixedFees[1] = FixedFeeRecipient(secondFixedRecipient, 500);
        config.excess = ExcessReturnFee(true, excessRecipient, 300, 10_000);
        _deploy(config);

        _deposit(user, 1_000 ether);
        vm.warp(block.timestamp + 365 days);
        asset.mint(address(venue), 50 ether);

        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.positiveAccrualAssets, 50 ether);
        assertEq(preview.fixedFeeAssets, 2.625 ether);
        assertEq(preview.targetValuePerEarnShare, 1.03 ether);
        assertEq(preview.excessFeeAssets, 17.375 ether);
        assertEq(preview.totalFeeAssets, 20 ether);
        assertEq(preview.allocationCount, 3);
        assertEq(preview.allocations[0].account, fixedRecipient);
        assertEq(preview.allocations[0].feeAssets, 0.125 ether);
        assertEq(preview.allocations[1].account, secondFixedRecipient);
        assertEq(preview.allocations[1].feeAssets, 2.5 ether);
        assertEq(preview.allocations[2].account, excessRecipient);
        assertEq(preview.allocations[2].feeAssets, 17.375 ether);

        earnVault.accrueFees();
        assertEq(
            fees.claimableEarnShares(fixedRecipient) + fees.claimableEarnShares(secondFixedRecipient)
                + fees.claimableEarnShares(excessRecipient),
            preview.totalFeeEarnShares
        );
        assertEq(fees.highWaterMark(), preview.postFeeValuePerEarnShare);
    }

    function testLossMustRecoverPostFeeHighWaterBeforeNewFee() public {
        _deposit(user, 100 ether);
        asset.mint(address(venue), 20 ether);
        FeePreview memory initialPreview = fees.previewAccruedFees();
        earnVault.accrueFees();
        uint256 firstFeeShares = fees.claimableEarnShares(fixedRecipient);
        assertEq(fees.highWaterMark(), initialPreview.postFeeValuePerEarnShare);

        vm.prank(address(venue));
        asset.burn(10 ether);
        earnVault.accrueFees();
        assertEq(fees.claimableEarnShares(fixedRecipient), firstFeeShares);

        asset.mint(address(venue), 10 ether);
        earnVault.accrueFees();
        assertEq(fees.claimableEarnShares(fixedRecipient), firstFeeShares);

        asset.mint(address(venue), 10 ether);
        FeePreview memory preview = fees.previewAccruedFees();
        uint256 expectedPositiveAccrualAssets =
            (preview.preFeeValuePerEarnShare - fees.highWaterMark()) * share.totalSupply() / 1 ether;
        assertEq(preview.positiveAccrualAssets, expectedPositiveAccrualAssets);
        assertLt(preview.positiveAccrualAssets, 10 ether);
        assertEq(preview.totalFeeAssets, expectedPositiveAccrualAssets / 10);
    }

    function testDrawdownRecoveryRatchetsNewExcessTargetBelowHighWaterMark() public {
        _deposit(user, 100 ether);

        vm.prank(address(venue));
        asset.burn(20 ether);

        FeeConfig memory excessConfig;
        excessConfig.excess = ExcessReturnFee(true, excessRecipient, 1_000, 5_000);
        earnVault.setFeeConfig(excessConfig);

        assertEq(fees.highWaterMark(), 1 ether);
        assertEq(fees.targetBase(), 0.8 ether);

        asset.mint(address(venue), 10 ether);
        (uint256 feeAssets, uint256 feeEarnShares) = earnVault.accrueFees();

        assertEq(feeAssets, 0);
        assertEq(feeEarnShares, 0);
        assertEq(fees.highWaterMark(), 1 ether);
        assertEq(fees.targetBase(), 0.9 ether);
        assertEq(fees.targetStartedAt(), block.timestamp);
    }

    function testMissedTargetCarriesForward() public {
        FeeConfig memory config;
        config.excess = ExcessReturnFee(true, excessRecipient, 1_000, 10_000);
        _deploy(config);
        _deposit(user, 100 ether);
        uint256 targetStartedAt = fees.targetStartedAt();

        vm.warp(targetStartedAt + 365 days);
        asset.mint(address(venue), 5 ether);
        earnVault.accrueFees();
        assertEq(fees.claimableEarnShares(excessRecipient), 0);
        assertEq(fees.targetBase(), 1 ether);

        vm.warp(targetStartedAt + 2 * 365 days);
        asset.mint(address(venue), 20 ether);
        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.targetValuePerEarnShare, 1.2 ether);
        assertApproxEqAbs(preview.excessFeeAssets, 5 ether, 100);
        assertEq(preview.totalFeeAssets, preview.excessFeeAssets);
    }

    function testConfigurationChangeSettlesOldRateAndAppliesNewRateProspectively() public {
        _deposit(user, 100 ether);
        asset.mint(address(venue), 10 ether);

        earnVault.setFeeConfig(_fixedConfig(fixedRecipient, 2_000));
        uint256 oldRateShares = fees.claimableEarnShares(fixedRecipient);
        assertGt(oldRateShares, 0);
        assertEq(fees.currentFeeConfigId(), 2);

        asset.mint(address(venue), 10 ether);
        FeePreview memory preview = fees.previewAccruedFees();
        assertApproxEqAbs(preview.totalFeeAssets, 2 ether, 100);
        earnVault.accrueFees();
        assertGt(fees.claimableEarnShares(fixedRecipient), oldRateShares);
    }

    function testLaterDepositSettlesEarlierGrowthBeforeMinting() public {
        _deposit(user, 100 ether);
        asset.mint(address(venue), 20 ether);

        _deposit(secondUser, 118 ether);

        assertEq(share.balanceOf(user), 100 ether);
        assertApproxEqAbs(share.balanceOf(secondUser), 100 ether, 2);
        assertGt(fees.claimableEarnShares(fixedRecipient), 0);
        assertTrue(earnVault.isAccountingAligned());
    }

    /// @dev A near-total exit cannot make carried fixed fees over-allocate the next checkpoint.
    function testCarriedFixedFeesCheckpointAfterNearTotalExit() public {
        FeeConfig memory config;
        config.fixedFeeCount = 3;
        config.fixedFees[0] = FixedFeeRecipient(fixedRecipient, 3_334);
        config.fixedFees[1] = FixedFeeRecipient(secondFixedRecipient, 3_333);
        config.fixedFees[2] = FixedFeeRecipient(thirdFixedRecipient, 3_333);
        config.excess = ExcessReturnFee(true, excessRecipient, 0, 10_000);
        _deploy(config);

        uint256 initialDeposit = 1 ether;
        _deposit(user, initialDeposit);
        asset.mint(address(venue), 9_999);
        (uint256 firstFeeAssets, uint256 firstFeeEarnShares) = earnVault.accrueFees();

        assertEq(firstFeeAssets, 9_999);
        assertEq(firstFeeEarnShares, 9_999);
        assertEq(fees.feeRemainder(1, 0), 6_666);
        assertEq(fees.feeRemainder(1, 1), 6_667);
        assertEq(fees.feeRemainder(1, 2), 6_667);

        address[4] memory recipients = [fixedRecipient, secondFixedRecipient, thirdFixedRecipient, excessRecipient];
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 claimable = fees.claimableEarnShares(recipients[i]);
            vm.prank(recipients[i]);
            fees.claim(user, claimable);
        }

        vm.prank(user);
        earnVault.redeem(initialDeposit + 9_997, user, 1);
        assertEq(earnVault.totalEarnShares(), 2);
        assertEq(engine.totalAssets(), 3);

        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.positiveAccrualAssets, 1);
        assertEq(preview.fixedFeeAssets, 1);
        assertEq(preview.totalFeeAssets, 1);
        assertEq(preview.totalFeeEarnShares, 1);
        assertEq(preview.allocations[0].feeAssets, 0);
        assertEq(preview.allocations[1].feeAssets, 0);
        assertEq(preview.allocations[2].feeAssets, 1);

        (uint256 secondFeeAssets, uint256 secondFeeEarnShares) = earnVault.accrueFees();
        assertEq(secondFeeAssets, 1);
        assertEq(secondFeeEarnShares, 1);
        assertEq(fees.claimableEarnShares(thirdFixedRecipient), 1);
        assertEq(fees.totalClaimableEarnShares(), 1);
        assertEq(share.balanceOf(address(fees)), 1);
    }

    function testOperatorDisableWaivesUncrystallizedGrowthAndReactivatesProspectively() public {
        _deposit(user, 100 ether);
        asset.mint(address(venue), 10 ether);

        earnVault.disableFees();
        assertFalse(fees.feesActive());
        assertEq(fees.claimableEarnShares(fixedRecipient), 0);

        asset.mint(address(venue), 10 ether);
        earnVault.setFeeConfig(_fixedConfig(fixedRecipient, 1_000));
        assertTrue(fees.feesActive());
        assertEq(fees.currentFeeConfigId(), 2);
        assertEq(fees.highWaterMark(), 1.2 ether);

        asset.mint(address(venue), 10 ether);
        earnVault.accrueFees();
        assertGt(fees.claimableEarnShares(fixedRecipient), 0);
    }

    function testConfigurationIsOperatorOnlyAndClaimsAreBounded() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(EarnVault.NotOperator.selector);
        earnVault.setFeeConfig(_fixedConfig(fixedRecipient, 500));

        vm.prank(address(0xBAD));
        vm.expectRevert(EarnVault.NotOperator.selector);
        earnVault.disableFees();

        FeeConfig memory excessiveFixedTotal;
        excessiveFixedTotal.fixedFeeCount = 2;
        excessiveFixedTotal.fixedFees[0] = FixedFeeRecipient(fixedRecipient, 6_000);
        excessiveFixedTotal.fixedFees[1] = FixedFeeRecipient(secondFixedRecipient, 6_000);
        vm.expectRevert(EarnFees.InvalidFeeConfiguration.selector);
        earnVault.setFeeConfig(excessiveFixedTotal);

        FeeConfig memory excessiveExcessRate;
        excessiveExcessRate.excess = ExcessReturnFee(true, excessRecipient, 0, 10_001);
        vm.expectRevert(EarnFees.InvalidFeeConfiguration.selector);
        earnVault.setFeeConfig(excessiveExcessRate);

        _deposit(user, 100 ether);
        asset.mint(address(venue), 10 ether);
        earnVault.accrueFees();
        uint256 claimable = fees.claimableEarnShares(fixedRecipient);

        vm.prank(address(0xBAD));
        vm.expectRevert(EarnFees.InsufficientClaimableEarnShares.selector);
        fees.claim(address(0xBAD), claimable);
        assertEq(fees.claimableEarnShares(fixedRecipient), claimable);
    }

    function testEarnFeesMutationsAreRestrictedToItsImmutableEarnVault() public {
        vm.expectRevert(EarnFees.NotEarnVault.selector);
        fees.accrueFees();

        vm.expectRevert(EarnFees.NotEarnVault.selector);
        fees.setFeeConfig(_fixedConfig(fixedRecipient, 100));

        vm.expectRevert(EarnFees.NotEarnVault.selector);
        fees.disableFees(address(this));

        vm.expectRevert(EarnFees.NotEarnVault.selector);
        fees.initializeBaselines();

        vm.expectRevert(EarnFees.NotEarnVault.selector);
        fees.recordRedeemRequest(bytes32(uint256(1)), 1 ether, 1 ether);
    }

    function testProxyCanOnlyInitializeOnce() public {
        vm.expectRevert(EarnVault.AlreadyInitialized.selector);
        earnVault.initialize(
            address(engine),
            address(share),
            address(fees),
            address(this),
            EarnVaultTestDeployer.defaultControls(address(this)),
            DistributorConfig(address(0), 0)
        );
    }

    function _deploy(FeeConfig memory config) internal {
        _deployWithDecimals(config, 18);
    }

    function _deployWithDecimals(FeeConfig memory config, uint8 decimals) internal {
        _deployWithEngineShareDecimals(config, decimals, decimals);
    }

    function _deployWithEngineShareDecimals(FeeConfig memory config, uint8 tokenDecimals, uint8 engineShareDecimals)
        internal
    {
        asset = new FaultyMockToken("Asset", "AST", tokenDecimals);
        share = new FaultyMockToken("Earn Share", "EARN", tokenDecimals);
        venue = new Simple4626Vault(address(asset), "Venue", "VEN", engineShareDecimals);
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        earnVault = EarnVaultTestDeployer.deploy(address(engine), address(share), address(this), config);
        fees = IEarnFees(earnVault.earnFees());
        engine.initializeEarnVault(address(earnVault));
        asset.mint(user, 10_000 ether);
        asset.mint(secondUser, 10_000 ether);
    }

    function _deposit(address account, uint256 amount) internal {
        vm.startPrank(account);
        asset.approve(address(earnVault), type(uint256).max);
        share.approve(address(earnVault), type(uint256).max);
        earnVault.deposit(amount, account, 1);
        vm.stopPrank();
    }

    function _fixedConfig(address recipient, uint16 rateBps) internal pure returns (FeeConfig memory config) {
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(recipient, rateBps);
    }
}

contract EarnVaultDistributorTest is Test {
    FaultyMockToken private asset;
    FaultyMockToken private share;
    Simple4626Vault private venue;
    ERC4626Engine private engine;
    EarnVault private earnVault;
    IEarnFees private fees;

    address private constant DISTRIBUTOR = address(0xD157);
    address private constant NEW_DISTRIBUTOR = address(0xD158);
    address private constant DISTRIBUTOR_RECIPIENT = address(0xFEE1);
    address private constant NEW_RECIPIENT = address(0xFEE2);
    address private constant OPERATOR_RECIPIENT = address(0xFEE3);
    address private constant USER = address(0xA11CE);
    uint40 private constant UPDATE_DELAY = 7 days;

    function setUp() public {
        _deploy(4_000, 3_000);
    }

    function testDistributorFeeIsProtectedFromOperatorUpdates() public {
        FeeConfig memory removed;
        vm.expectRevert(EarnVault.InvalidDistributorFeeConfiguration.selector);
        earnVault.setFeeConfig(removed);

        FeeConfig memory replaced = _config(NEW_RECIPIENT, 4_000, OPERATOR_RECIPIENT, 3_000);
        vm.expectRevert(EarnVault.InvalidDistributorFeeConfiguration.selector);
        earnVault.setFeeConfig(replaced);

        FeeConfig memory operatorUpdate = _config(DISTRIBUTOR_RECIPIENT, 4_000, OPERATOR_RECIPIENT, 2_000);
        assertEq(earnVault.setFeeConfig(operatorUpdate), 2);
        FeeConfig memory installed = fees.feeConfig(2);
        assertEq(installed.fixedFees[0].account, DISTRIBUTOR_RECIPIENT);
        assertEq(installed.fixedFees[0].rateBps, 4_000);
        assertEq(installed.fixedFees[1].rateBps, 2_000);
    }

    function testDistributorUpdateIsTimelockedPermissionlessAndProspective() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(EarnVault.NotDistributor.selector);
        earnVault.scheduleDistributorFeeUpdate(NEW_RECIPIENT, 5_000);

        uint256 scheduledAt = block.timestamp;
        vm.prank(DISTRIBUTOR);
        earnVault.scheduleDistributorFeeUpdate(NEW_RECIPIENT, 5_000);

        DistributorFeeUpdate memory pending = earnVault.pendingDistributorFeeUpdate();
        assertTrue(pending.pending);
        assertEq(pending.recipient, NEW_RECIPIENT);
        assertEq(pending.rateBps, 5_000);
        assertEq(pending.executableAt, scheduledAt + UPDATE_DELAY);

        vm.expectRevert(abi.encodeWithSelector(EarnVault.DistributorFeeUpdateNotReady.selector, pending.executableAt));
        earnVault.executeDistributorFeeUpdate();

        _deposit(100 ether);
        asset.mint(address(venue), 10 ether);
        vm.warp(pending.executableAt);
        assertEq(earnVault.executeDistributorFeeUpdate(), 2);
        assertGt(fees.claimableEarnShares(DISTRIBUTOR_RECIPIENT), 0);
        assertEq(fees.claimableEarnShares(NEW_RECIPIENT), 0);

        (address recipient, uint16 rateBps) = earnVault.distributorFee();
        assertEq(recipient, NEW_RECIPIENT);
        assertEq(rateBps, 5_000);
        assertFalse(earnVault.pendingDistributorFeeUpdate().pending);

        asset.mint(address(venue), 10 ether);
        earnVault.accrueFees();
        assertGt(fees.claimableEarnShares(NEW_RECIPIENT), 0);
    }

    function testEitherAuthorityCannotExceedAggregateFixedFeeLimit() public {
        vm.prank(DISTRIBUTOR);
        vm.expectRevert(EarnFees.InvalidFeeConfiguration.selector);
        earnVault.scheduleDistributorFeeUpdate(NEW_RECIPIENT, 8_000);

        FeeConfig memory excessiveOperator = _config(DISTRIBUTOR_RECIPIENT, 4_000, OPERATOR_RECIPIENT, 7_000);
        vm.expectRevert(EarnFees.InvalidFeeConfiguration.selector);
        earnVault.setFeeConfig(excessiveOperator);

        vm.prank(DISTRIBUTOR);
        earnVault.scheduleDistributorFeeUpdate(NEW_RECIPIENT, 7_000);

        FeeConfig memory invalidatesPending = _config(DISTRIBUTOR_RECIPIENT, 4_000, OPERATOR_RECIPIENT, 4_000);
        vm.expectRevert(EarnFees.InvalidFeeConfiguration.selector);
        earnVault.setFeeConfig(invalidatesPending);
    }

    function testGlobalFeeDisableIsUnavailableWhenDistributorConfigured() public {
        vm.expectRevert(EarnVault.GlobalFeeDisableUnavailable.selector);
        earnVault.disableFees();

        vm.prank(DISTRIBUTOR);
        vm.expectRevert(EarnVault.GlobalFeeDisableUnavailable.selector);
        earnVault.disableFees();
        assertFalse(fees.feesDisabled());
    }

    function testDistributorTransfersItselfInTwoStepsAndClearsPendingFeeUpdate() public {
        vm.startPrank(DISTRIBUTOR);
        earnVault.scheduleDistributorFeeUpdate(NEW_RECIPIENT, 5_000);
        earnVault.transferDistributor(NEW_DISTRIBUTOR);
        vm.stopPrank();
        assertEq(earnVault.pendingDistributor(), NEW_DISTRIBUTOR);

        vm.prank(address(0xBAD));
        vm.expectRevert(EarnVault.NotPendingDistributor.selector);
        earnVault.acceptDistributor();

        vm.prank(NEW_DISTRIBUTOR);
        earnVault.acceptDistributor();
        assertEq(earnVault.distributor(), NEW_DISTRIBUTOR);
        assertEq(earnVault.pendingDistributor(), address(0));
        assertFalse(earnVault.pendingDistributorFeeUpdate().pending);

        (address recipient, uint16 rateBps) = earnVault.distributorFee();
        assertEq(recipient, DISTRIBUTOR_RECIPIENT);
        assertEq(rateBps, 4_000);

        vm.prank(DISTRIBUTOR);
        vm.expectRevert(EarnVault.NotDistributor.selector);
        earnVault.scheduleDistributorFeeUpdate(NEW_RECIPIENT, 5_000);

        vm.prank(NEW_DISTRIBUTOR);
        earnVault.scheduleDistributorFeeUpdate(NEW_RECIPIENT, 5_000);
    }

    function testDistributorCanDisableAndLaterRestoreItsReservedItem() public {
        vm.prank(DISTRIBUTOR);
        earnVault.scheduleDistributorFeeUpdate(address(0), 0);
        vm.warp(block.timestamp + UPDATE_DELAY);
        earnVault.executeDistributorFeeUpdate();

        (address recipient, uint16 rateBps) = earnVault.distributorFee();
        assertEq(recipient, address(0));
        assertEq(rateBps, 0);
        FeeConfig memory disabled = fees.feeConfig(fees.currentFeeConfigId());
        assertEq(disabled.fixedFeeCount, 1);
        assertEq(disabled.fixedFees[0].account, OPERATOR_RECIPIENT);

        FeeConfig memory tooManyOperatorFees;
        tooManyOperatorFees.fixedFeeCount = 4;
        for (uint8 i = 0; i < 4; i++) {
            tooManyOperatorFees.fixedFees[i] = FixedFeeRecipient(address(uint160(0x100 + i)), 100);
        }
        vm.expectRevert(EarnVault.InvalidDistributorFeeConfiguration.selector);
        earnVault.setFeeConfig(tooManyOperatorFees);

        vm.prank(DISTRIBUTOR);
        earnVault.scheduleDistributorFeeUpdate(NEW_RECIPIENT, 5_000);
        vm.warp(block.timestamp + UPDATE_DELAY);
        earnVault.executeDistributorFeeUpdate();

        FeeConfig memory restored = fees.feeConfig(fees.currentFeeConfigId());
        assertEq(restored.fixedFeeCount, 2);
        assertEq(restored.fixedFees[0].account, NEW_RECIPIENT);
        assertEq(restored.fixedFees[0].rateBps, 5_000);
        assertEq(restored.fixedFees[1].account, OPERATOR_RECIPIENT);
    }

    function _deploy(uint16 distributorRateBps, uint16 operatorRateBps) private {
        asset = new FaultyMockToken("Asset", "AST", 18);
        share = new FaultyMockToken("Earn Share", "EARN", 18);
        venue = new Simple4626Vault(address(asset), "Venue", "VEN", 18);
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        FeeConfig memory config =
            _config(DISTRIBUTOR_RECIPIENT, distributorRateBps, OPERATOR_RECIPIENT, operatorRateBps);
        earnVault = EarnVaultTestDeployer.deploy(
            address(engine),
            address(share),
            address(this),
            EarnVaultTestDeployer.defaultControls(address(this)),
            DistributorConfig(DISTRIBUTOR, UPDATE_DELAY),
            config
        );
        fees = IEarnFees(earnVault.earnFees());
        engine.initializeEarnVault(address(earnVault));
        asset.mint(USER, 1_000 ether);
    }

    function _deposit(uint256 amount) private {
        vm.startPrank(USER);
        asset.approve(address(earnVault), amount);
        earnVault.deposit(amount, USER, amount);
        vm.stopPrank();
    }

    function _config(
        address distributorRecipient,
        uint16 distributorRate,
        address operatorRecipient,
        uint16 operatorRate
    ) private pure returns (FeeConfig memory config) {
        config.fixedFeeCount = operatorRate == 0 ? 1 : 2;
        config.fixedFees[0] = FixedFeeRecipient(distributorRecipient, distributorRate);
        if (operatorRate != 0) config.fixedFees[1] = FixedFeeRecipient(operatorRecipient, operatorRate);
    }
}
