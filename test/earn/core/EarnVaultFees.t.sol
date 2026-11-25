// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

// EarnVault-to-EarnFees economic-equivalence coverage.
import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Simple4626Vault } from "../../../src/demo/Simple4626Vault.sol";
import { EarnVault } from "../../../src/earn/core/EarnVault.sol";
import { EarnFees } from "../../../src/earn/core/EarnFees.sol";
import { ERC4626Engine, IERC4626Vault } from "../../../src/earn/engines/erc4626/ERC4626Engine.sol";
import {
    ExcessReturnFee,
    FeeConfig,
    FeePreview,
    FixedFeeRecipient
} from "../../../src/interfaces/earn/EarnFeeTypes.sol";
import { IEarnFees } from "../../../src/interfaces/earn/IEarnFees.sol";
import { DistributorConfig, DistributorFeeUpdate } from "../../../src/interfaces/earn/EarnVaultTypes.sol";
import { CoreMockEngine, FaultyMockToken } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract EarnVaultFeesTest is Test {
    /// @dev EarnFees keeps values per EarnShare at the EarnShare scale times this factor.
    uint256 constant VALUE_PRECISION = 1e18;

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
        assertEq(fees.highWaterMark(), 1 ether * VALUE_PRECISION);

        _deposit(secondUser, 100 ether);
        assertEq(fees.claimableEarnShares(fixedRecipient), 0);
        assertEq(share.balanceOf(user), 100 ether);
        assertEq(share.balanceOf(secondUser), 100 ether);
        assertEq(fees.highWaterMark(), 1 ether * VALUE_PRECISION);
    }

    function testSteadyDepositSkipsBaselineRatchetThatWouldChangeNothing() public {
        _deposit(user, 100 ether);
        vm.recordLogs();
        _deposit(secondUser, 100 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EarnFees.FeeBaselinesInitialized.selector);
        }
        assertEq(fees.highWaterMark(), 1 ether * VALUE_PRECISION);

        // Value above the mark is charged by the next checkpoint, after which the deposit again leaves nothing
        // to raise; the mark is the post-fee value either way.
        asset.mint(address(venue), 10 ether);
        _deposit(user, 100 ether);
        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.totalFeeAssets, 0);
        assertGt(fees.highWaterMark(), 1 ether * VALUE_PRECISION);
        assertGt(fees.claimableEarnShares(fixedRecipient), 0);
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
        assertEq(fees.highWaterMark(), 1e6 * VALUE_PRECISION);

        asset.mint(address(venue), 20e6);
        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.preFeeValuePerEarnShare, 1.2e6 * VALUE_PRECISION);
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
        assertEq(fees.highWaterMark(), 1e6 * VALUE_PRECISION);
    }

    function testDustPoolCheckpointsChargeNoMoreThanOneCheckpoint() public {
        // Three EarnShare units: every asset unit of growth is a whole step above the mark, so each one charges.
        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        _deposit(user, 3);
        asset.mint(address(venue), 100);
        (uint256 singleFeeAssets,) = earnVault.accrueFees();
        assertEq(singleFeeAssets, 9);

        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        _deposit(user, 3);
        uint256 totalFeeAssets;
        for (uint256 i = 0; i < 100; i++) {
            asset.mint(address(venue), 1);
            (uint256 feeAssets,) = earnVault.accrueFees();
            totalFeeAssets += feeAssets;
        }

        // The mark moves only by the accrual each checkpoint charged, so no value is charged twice and none is
        // dropped: the hundred checkpoints charge what one does, less what still waits above the mark.
        assertLe(_waitingAccrual(6), 1);
        assertEq(totalFeeAssets, singleFeeAssets);
        // Each fee converts to less than one EarnShare unit here, so it is waived rather than minted.
        assertEq(fees.claimableEarnShares(fixedRecipient), 0);
    }

    function testExcessFeeChargesWaitingAccrualOnceItIsChargeable() public {
        FeeConfig memory config;
        config.excess = ExcessReturnFee(true, excessRecipient, 0, 10_000);
        _deployWithDecimals(config, 6);
        _deposit(user, 3_000_000);

        asset.mint(address(this), 3);
        asset.approve(address(earnVault), 3);
        // One asset unit on three whole EarnShare is a third of a step: it waits above the mark, and the target does
        // not restart above the mark, so the waiting unit stays chargeable.
        earnVault.contribute(1);
        assertEq(fees.highWaterMark(), 1e6 * VALUE_PRECISION);
        assertEq(fees.targetBase(), 1e6 * VALUE_PRECISION);
        assertEq(fees.claimableEarnShares(excessRecipient), 0);
        assertEq(fees.previewAccruedFees().totalFeeAssets, 0);

        // Three units make a whole step, and the excess fee takes all of them above the zero-rate target, once.
        // Holders keep exactly the target, which stays the mark.
        earnVault.contribute(2);
        assertEq(fees.claimableEarnShares(excessRecipient), 3);
        assertEq(fees.highWaterMark(), 1e6 * VALUE_PRECISION);
        assertEq(fees.targetBase(), 1e6 * VALUE_PRECISION);
        assertEq(fees.previewAccruedFees().totalFeeAssets, 0);
        (uint256 feeAssets,) = earnVault.accrueFees();
        assertEq(feeAssets, 0);
    }

    /// @dev 100M of six-decimal principal earning 5% a year for one day, checkpointed every ten minutes or once. Ten
    ///      minutes of yield is less than one step (one asset unit per whole EarnShare, 100 units here), so about every
    ///      other checkpoint charges, and the last accrual may still wait above the mark.
    function testCheckpointCadenceDoesNotChangeFees() public {
        uint256 principal = 100_000_000e6;
        uint256 checkpoints = 144;
        uint256 yieldPerCheckpoint = principal * 500 / 10_000 / 365 / checkpoints;

        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        asset.mint(user, principal);
        _deposit(user, principal);
        asset.mint(address(venue), yieldPerCheckpoint * checkpoints);
        (uint256 singleFeeAssets,) = earnVault.accrueFees();
        uint256 singleFeeValue = earnVault.previewRedeem(fees.claimableEarnShares(fixedRecipient));
        assertApproxEqAbs(singleFeeAssets, yieldPerCheckpoint * checkpoints / 10, 1);

        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        asset.mint(user, principal);
        _deposit(user, principal);
        uint256 cadenceFeeAssets;
        uint256 charges;
        for (uint256 i = 0; i < checkpoints; i++) {
            asset.mint(address(venue), yieldPerCheckpoint);
            (uint256 feeAssets,) = earnVault.accrueFees();
            cadenceFeeAssets += feeAssets;
            if (feeAssets != 0) charges++;
        }
        uint256 cadenceFeeValue = earnVault.previewRedeem(fees.claimableEarnShares(fixedRecipient));
        uint256 waiting = _waitingAccrual(6);

        assertLe(charges, checkpoints / 2 + 1);
        // Less than one step waits, uncharged but not dropped.
        assertLt(waiting, earnVault.totalEarnShares() / 1e6);
        // Charged plus waiting fees match one checkpoint's to within an asset unit's rounding.
        assertApproxEqAbs(cadenceFeeAssets + waiting / 10, singleFeeAssets, 2);
        // Each charge rounds its fee EarnShare down by less than one unit, worth about one asset unit here, while fee
        // EarnShare minted early also earns the later yield.
        assertGe(cadenceFeeValue + waiting / 10 + charges, singleFeeValue);
        assertLe(cadenceFeeValue + waiting / 10, singleFeeValue + singleFeeValue / 1_000);

        // A final step of yield charges what was waiting with it.
        asset.mint(address(venue), earnVault.totalEarnShares() / 1e6);
        (uint256 lastFeeAssets,) = earnVault.accrueFees();
        assertApproxEqAbs(lastFeeAssets, (waiting + earnVault.totalEarnShares() / 1e6) / 10, 2);
        assertLe(_waitingAccrual(6), 1);
    }

    /// @dev 400 checkpoints of one asset unit of growth each on a pool of about 100 whole EarnShare charge what one
    ///      checkpoint over the same growth charges: each checkpoint moves the mark only by the accrual it charged.
    function testUnitGrowthCheckpointsChargeAsOneCheckpoint() public {
        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        _deposit(user, 100_000_003);
        asset.mint(address(venue), 500);
        (uint256 singleFeeAssets, uint256 singleFeeEarnShares) = earnVault.accrueFees();
        assertEq(singleFeeAssets, 49);
        assertEq(singleFeeEarnShares, 48);

        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        _deposit(user, 100_000_003);
        uint256 cadenceFeeAssets;
        uint256 cadenceFeeEarnShares;
        uint256 charges;
        for (uint256 i = 0; i < 400; i++) {
            asset.mint(address(venue), 1);
            (uint256 feeAssets, uint256 feeEarnShares) = earnVault.accrueFees();
            cadenceFeeAssets += feeAssets;
            cadenceFeeEarnShares += feeEarnShares;
            if (feeAssets != 0) charges++;
        }
        // One step here is 100 asset units of growth, so the checkpoints charged three times and the rest waits.
        uint256 waiting = _waitingAccrual(6);
        assertEq(charges, 3);
        assertLt(waiting, 101);
        assertEq(cadenceFeeAssets + waiting / 10, 40);

        // A last step of growth charges the waiting accrual with it.
        asset.mint(address(venue), 100);
        (uint256 lastFeeAssets, uint256 lastFeeEarnShares) = earnVault.accrueFees();
        cadenceFeeAssets += lastFeeAssets;
        cadenceFeeEarnShares += lastFeeEarnShares;
        charges++;
        assertLe(_waitingAccrual(6), 1);
        assertEq(cadenceFeeAssets, singleFeeAssets);
        // Each charge rounds its fee EarnShare down by less than one unit.
        assertLe(cadenceFeeEarnShares, singleFeeEarnShares);
        assertGe(cadenceFeeEarnShares + charges, singleFeeEarnShares);
    }

    function testDepositOneSecondAfterYieldWritesNoFeeState() public {
        // A 100M pool one second after a charging checkpoint: one second of 5% yield is far below one step.
        uint256 principal = 100_000_000e6;
        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        asset.mint(user, principal);
        _deposit(user, principal);
        asset.mint(address(venue), principal / 100);
        earnVault.accrueFees();
        uint256 mark = fees.highWaterMark();
        uint256 claimable = fees.claimableEarnShares(fixedRecipient);
        asset.mint(address(venue), earnVault.totalAssets() * 500 / 10_000 / 365 days);
        vm.warp(block.timestamp + 1);
        uint256 waiting = _waitingAccrual(6);
        assertGt(waiting, 0);

        vm.recordLogs();
        vm.startStateDiffRecording();
        _deposit(secondUser, 1_000e6);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The checkpoint charges nothing and the entry raises no baseline, so EarnFees writes no slot.
        assertEq(_storageWrites(accesses, address(fees)), 0);
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != EarnFees.FeeBaselinesInitialized.selector);
        }
        assertEq(fees.highWaterMark(), mark);
        assertEq(fees.claimableEarnShares(fixedRecipient), claimable);
        // The waiting accrual stays above the mark for a later checkpoint: the entry carries the same value per
        // EarnShare above the mark.
        assertGe(_waitingAccrual(6), waiting);
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
        assertEq(fees.highWaterMark(), 1e6 * VALUE_PRECISION);

        _deposit(secondUser, 300e6);

        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.positiveAccrualAssets, 0);
        assertEq(preview.totalFeeAssets, 0);
        // The pooled value: the dust entry's backing was worth 1.5 asset units, which its value floored to 1.
        assertEq(fees.highWaterMark(), 1_499_999_997_500_000_012_500_000);
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

        assertEq(fees.highWaterMark(), 100_000_000 * VALUE_PRECISION);
        assertEq(fees.claimableEarnShares(fixedRecipient), 0);
        assertEq(fees.previewAccruedFees().totalFeeAssets, 0);

        _deposit(secondUser, 100_000_000);
        uint256 victimShares = share.balanceOf(secondUser);
        assertEq(victimShares, 1_000_000);
        assertEq(fees.previewAccruedFees().totalFeeAssets, 0);
        assertEq(earnVault.previewRedeem(victimShares), 100_000_000);
    }

    function testReopeningDepositRestartsBaselinesAnEmptiedPoolLeftHigh() public {
        FeeConfig memory config;
        config.excess = ExcessReturnFee(true, excessRecipient, 0, 5_000);
        _deployWithDecimals(config, 6);
        _pinBaselinesAndEmptyPool();
        assertEq(fees.targetBase(), 100e6 * VALUE_PRECISION);

        // The next deposit reopens the pool at par and restarts both baselines there.
        vm.warp(block.timestamp + 1 days);
        _deposit(secondUser, 100e6);
        assertEq(fees.highWaterMark(), 1e6 * VALUE_PRECISION);
        assertEq(fees.targetBase(), 1e6 * VALUE_PRECISION);
        assertEq(fees.targetStartedAt(), block.timestamp);
        assertFalse(fees.feeBaselinesPending());

        // Growth after the reopen is charged: half of the 10e6 above the target.
        asset.mint(address(venue), 10e6);
        (uint256 feeAssets, uint256 feeEarnShares) = earnVault.accrueFees();
        assertEq(feeAssets, 5e6);
        assertGt(feeEarnShares, 0);
        assertEq(fees.claimableEarnShares(excessRecipient), feeEarnShares);
    }

    function testReopeningVenueShareDepositRestartsBaselinesAnEmptiedPoolLeftHigh() public {
        _deployWithDecimals(_fixedConfig(fixedRecipient, 1_000), 6);
        _pinBaselinesAndEmptyPool();

        vm.startPrank(secondUser);
        asset.approve(address(venue), 100e6);
        uint256 venueShares = venue.deposit(100e6, secondUser);
        venue.approve(address(engine), venueShares);
        earnVault.depositVenueShares(venueShares, secondUser, 1);
        vm.stopPrank();
        assertEq(fees.highWaterMark(), 1e6 * VALUE_PRECISION);

        asset.mint(address(venue), 10e6);
        (uint256 feeAssets,) = earnVault.accrueFees();
        assertEq(feeAssets, 1e6);
        assertGt(fees.claimableEarnShares(fixedRecipient), 0);
    }

    function testReopeningDepositWithStaleValuationDefersBaselines() public {
        asset = new FaultyMockToken("Asset", "AST", 6);
        share = new FaultyMockToken("Earn Share", "EARN", 6);
        CoreMockEngine staleEngine = new CoreMockEngine(asset, 6);
        staleEngine.setFeeValuation(true, true);
        earnVault = EarnVaultTestDeployer.deploy(
            address(staleEngine), address(share), address(this), _fixedConfig(fixedRecipient, 1_000)
        );
        fees = IEarnFees(earnVault.earnFees());
        asset.mint(user, 1_000e6);
        asset.mint(secondUser, 1_000e6);
        _pinBaselinesAndEmptyPool();

        // The reopening deposit cannot value the pool, so the baselines wait for a fresh valuation.
        staleEngine.setFeeValuation(true, false);
        _deposit(secondUser, 100e6);
        assertTrue(fees.feeBaselinesPending());
        assertEq(fees.highWaterMark(), 100e6 * VALUE_PRECISION);

        // The next fresh checkpoint restarts them at the current value without charging it.
        staleEngine.setFeeValuation(true, true);
        (uint256 feeAssets, uint256 feeEarnShares) = earnVault.accrueFees();
        assertEq(feeAssets, 0);
        assertEq(feeEarnShares, 0);
        assertFalse(fees.feeBaselinesPending());
        assertEq(fees.highWaterMark(), 1e6 * VALUE_PRECISION);

        staleEngine.setNavGain(10e6);
        (feeAssets,) = earnVault.accrueFees();
        assertEq(feeAssets, 1e6);
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
        // EarnFees also keeps the one unit the vault minted it at initialization.
        assertEq(share.balanceOf(address(fees)), totalClaimable + 1);

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
        assertEq(share.balanceOf(address(fees)), claimable + 1);

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
        assertEq(preview.targetValuePerEarnShare, 1.03 ether * VALUE_PRECISION);
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
        uint256 expectedPositiveAccrualAssets = (preview.preFeeValuePerEarnShare - fees.highWaterMark())
            * earnVault.totalEarnShares() / (1 ether * VALUE_PRECISION);
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

        assertEq(fees.highWaterMark(), 1 ether * VALUE_PRECISION);
        assertEq(fees.targetBase(), 0.8 ether * VALUE_PRECISION);

        asset.mint(address(venue), 10 ether);
        (uint256 feeAssets, uint256 feeEarnShares) = earnVault.accrueFees();

        assertEq(feeAssets, 0);
        assertEq(feeEarnShares, 0);
        assertEq(fees.highWaterMark(), 1 ether * VALUE_PRECISION);
        assertEq(fees.targetBase(), 0.9 ether * VALUE_PRECISION);
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
        assertEq(fees.targetBase(), 1 ether * VALUE_PRECISION);

        vm.warp(targetStartedAt + 2 * 365 days);
        asset.mint(address(venue), 20 ether);
        FeePreview memory preview = fees.previewAccruedFees();
        assertEq(preview.targetValuePerEarnShare, 1.2 ether * VALUE_PRECISION);
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
        // Slots past the excess remainder read zero, as they did before the remainders were packed.
        assertEq(fees.feeRemainder(1, 3), 0);
        assertEq(fees.feeRemainder(1, 5), 0);
        assertEq(fees.feeRemainder(1, type(uint8).max), 0);

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
        assertEq(share.balanceOf(address(fees)), 2);
    }

    /// @dev Disabling waives every carried remainder, emitting each one, and a later checkpoint carries none.
    function testDisableWaivesPackedRemainders() public {
        FeeConfig memory config;
        config.fixedFeeCount = 3;
        config.fixedFees[0] = FixedFeeRecipient(fixedRecipient, 3_334);
        config.fixedFees[1] = FixedFeeRecipient(secondFixedRecipient, 3_333);
        config.fixedFees[2] = FixedFeeRecipient(thirdFixedRecipient, 3_333);
        _deploy(config);

        _deposit(user, 1 ether);
        asset.mint(address(venue), 9_999);
        earnVault.accrueFees();
        assertEq(fees.feeRemainder(1, 0), 6_666);
        assertNotEq(vm.load(address(fees), _remaindersSlot(1)), bytes32(0));

        vm.expectEmit(address(fees));
        emit EarnFees.FeeDustWaived(1, 0, 6_666);
        vm.expectEmit(address(fees));
        emit EarnFees.FeeDustWaived(1, 1, 6_667);
        vm.expectEmit(address(fees));
        emit EarnFees.FeeDustWaived(1, 2, 6_667);
        earnVault.disableFees();
        for (uint8 slot = 0; slot <= 4; slot++) {
            assertEq(fees.feeRemainder(1, slot), 0);
        }
        // The disabled configuration never accrues again, so waiving clears its slot, marker included.
        assertEq(vm.load(address(fees), _remaindersSlot(1)), bytes32(0));
        assertTrue(earnVault.isAccountingAligned());
    }

    /// @dev A slot holding only the marker, left after carried remainders are consumed to zero, is cleared without events.
    function testDisableClearsMarkerOnlyRemainderSlot() public {
        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(fixedRecipient, 10_000);
        _deploy(config);

        vm.store(address(fees), _remaindersSlot(1), bytes32(uint256(1) << 255));
        assertEq(fees.feeRemainder(1, 0), 0);

        vm.recordLogs();
        earnVault.disableFees();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertNotEq(logs[i].topics[0], EarnFees.FeeDustWaived.selector);
        }
        assertEq(vm.load(address(fees), _remaindersSlot(1)), bytes32(0));
    }

    function testEarnShareScaleIsZeroUntilInitialized() public {
        EarnFees implementation = new EarnFees();
        assertEq(implementation.earnShareScale(), 0);
        assertEq(EarnFees(Clones.clone(address(implementation))).earnShareScale(), 0);
        assertEq(EarnFees(address(fees)).earnShareScale(), 10 ** share.decimals());
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
        assertEq(fees.highWaterMark(), 1.2 ether * VALUE_PRECISION);

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
        fees.accrueFees(1 ether, 1 ether, true);

        vm.expectRevert(EarnFees.NotEarnVault.selector);
        fees.setFeeConfig(_fixedConfig(fixedRecipient, 100));

        vm.expectRevert(EarnFees.NotEarnVault.selector);
        fees.disableFees(address(this));

        vm.expectRevert(EarnFees.NotEarnVault.selector);
        fees.initializeBaselines(1 ether, 1 ether);

        vm.expectRevert(EarnFees.NotEarnVault.selector);
        fees.recordRedeemRequest(bytes32(uint256(1)), 1 ether);
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

    function testFeeClaimWritesOnlyClaimBalances() public {
        _deposit(user, 100 ether);
        asset.mint(address(venue), 10 ether);
        earnVault.accrueFees();
        uint256 claimable = fees.claimableEarnShares(fixedRecipient);
        assertGt(claimable, 0);

        vm.startStateDiffRecording();
        vm.prank(fixedRecipient);
        fees.claim(fixedRecipient, claimable);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        // The recipient's and the total claimable balance; the reentrancy lock is transient and writes no slot.
        assertEq(_storageWrites(accesses, address(fees)), 2);
        assertEq(fees.claimableEarnShares(fixedRecipient), 0);
        assertEq(fees.totalClaimableEarnShares(), 0);
    }

    function testLockedVaultCallRestoresNoStorageSlot() public {
        _deposit(user, 100 ether);

        vm.startStateDiffRecording();
        _deposit(user, 1 ether);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

        // A stored lock would be written and restored within the call; the transient lock leaves no such slot.
        assertGt(_storageWrites(accesses, address(earnVault)), 0);
        assertEq(_restoredSlots(accesses, address(earnVault)), 0);
        assertEq(share.balanceOf(user), 101 ether);
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

    /// @dev One unit of principal and a 99-unit contribution leave the baselines at 100 times par; the sole holder
    ///      then exits and empties the pool.
    function _pinBaselinesAndEmptyPool() internal {
        _deposit(user, 1);
        asset.mint(address(this), 99);
        asset.approve(address(earnVault), 99);
        earnVault.contribute(99);
        assertEq(fees.highWaterMark(), 100e6 * VALUE_PRECISION);
        vm.prank(user);
        assertEq(earnVault.redeem(1, user, 1), 100);
        assertEq(earnVault.totalEarnShares(), 0);
    }

    /// @dev Accrual above the high-water mark that no checkpoint has charged yet, in asset units.
    function _waitingAccrual(uint8 decimals) internal view returns (uint256) {
        uint256 marked =
            Math.mulDiv(fees.highWaterMark(), earnVault.totalEarnShares(), 10 ** decimals * VALUE_PRECISION);
        uint256 assets = earnVault.totalAssets();
        return assets > marked ? assets - marked : 0;
    }

    function _fixedConfig(address recipient, uint16 rateBps) internal pure returns (FeeConfig memory config) {
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(recipient, rateBps);
    }

    function _storageWrites(Vm.AccountAccess[] memory accesses, address account) internal pure returns (uint256 count) {
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                if (storageAccesses[j].account == account && storageAccesses[j].isWrite && !storageAccesses[j].reverted)
                {
                    ++count;
                }
            }
        }
    }

    /// @dev Counts slots of `account` written during the recording whose final value equals their value before it.
    function _restoredSlots(Vm.AccountAccess[] memory accesses, address account) internal pure returns (uint256 count) {
        uint256 total = _storageWrites(accesses, account);
        bytes32[] memory slots = new bytes32[](total);
        bytes32[] memory before = new bytes32[](total);
        bytes32[] memory last = new bytes32[](total);
        uint256 distinct;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j; j < storageAccesses.length; ++j) {
                Vm.StorageAccess memory access = storageAccesses[j];
                if (access.account != account || !access.isWrite || access.reverted) continue;
                uint256 k;
                while (k < distinct && slots[k] != access.slot) ++k;
                if (k == distinct) {
                    slots[k] = access.slot;
                    before[k] = access.previousValue;
                    ++distinct;
                }
                last[k] = access.newValue;
            }
        }
        for (uint256 k; k < distinct; ++k) {
            if (before[k] == last[k]) ++count;
        }
    }

    /// @dev EarnFees keeps `_feeRemainders` at storage slot 5 (`forge inspect EarnFees storageLayout`).
    function _remaindersSlot(uint64 configId) private pure returns (bytes32) {
        return keccak256(abi.encode(configId, uint256(4)));
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
        // The optimizer may reuse the block.timestamp read before the first warp; read the warped one.
        vm.warp(vm.getBlockTimestamp() + UPDATE_DELAY);
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

/// @notice Baselines too wide for their half of the shared slot keep their exact value in their wide slots.
contract EarnFeesWideBaselineTest is Test {
    EarnFees private fees;
    FaultyMockToken private share;
    uint256 private assetsNow;

    function setUp() public {
        share = new FaultyMockToken("Earn Share", "EARN", 18);
        fees = EarnFees(Clones.clone(address(new EarnFees())));
        fees.initialize(address(this), address(share), _config());
    }

    function testWideBaselinesKeepTheirValueAndNeverChargeTwice() public {
        // One EarnShare unit backed by 2 ** 100 asset units values each whole EarnShare far above 2 ** 128.
        uint256 assets = 1 << 100;
        fees.initializeBaselines(1, assets);
        uint256 expected = assets * 1e36;
        assertGt(expected, type(uint128).max);
        assertEq(fees.highWaterMark(), expected);
        assertEq(fees.targetBase(), expected);

        // No value above the wide mark charges nothing.
        (uint256 feeAssets, uint256 feeEarnShares,,) = fees.accrueFees(1, assets, true);
        assertEq(feeAssets, 0);
        assertEq(feeEarnShares, 0);

        // Doubled value charges once and moves the wide mark to the post-fee value.
        (feeAssets, feeEarnShares,,) = fees.accrueFees(1, 2 * assets, true);
        assertGt(feeAssets, 0);
        uint256 mark = fees.highWaterMark();
        assertGt(mark, expected);
        assertEq(mark, Math.mulDiv(2 * assets, 1e36, 1 + feeEarnShares, Math.Rounding.Ceil));
        assertEq(fees.targetBase(), mark);
        (feeAssets,,,) = fees.accrueFees(1 + feeEarnShares, 2 * assets, true);
        assertEq(feeAssets, 0);
        assertEq(fees.highWaterMark(), mark);
    }

    function testNarrowBaselinesReplaceWideOnes() public {
        fees.initializeBaselines(1, 1 << 100);
        assertGt(fees.highWaterMark(), type(uint128).max);

        // Re-enabling fees restarts both baselines at the pool's current value, which fits its half again.
        share.mint(address(this), 1e18 + 2);
        assetsNow = 3e18;
        fees.disableFees(address(this));
        fees.setFeeConfig(_config());
        assertEq(fees.highWaterMark(), 3e36);
        assertEq(fees.targetBase(), 3e36);
    }

    /// @dev EarnFees reads the paired vault's active assets and valuation freshness back from it.
    function totalAssets() external view returns (uint256) {
        return assetsNow;
    }

    function isFeeValuationFresh() external pure returns (bool) {
        return true;
    }

    function _config() private pure returns (FeeConfig memory config) {
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient(address(0xF1), 1_000);
        config.excess = ExcessReturnFee(true, address(0xE1), 300, 5_000);
    }
}

