// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { EarnFees } from "../../../src/core/EarnFees.sol";
import { EarnVault } from "../../../src/core/EarnVault.sol";
import { FixedFeeRecipient, FeeConfig, FeePreview } from "../../../src/interfaces/core/EarnFeeTypes.sol";
import { VedaRedeemRequest } from "../../../src/interfaces/external/veda/VedaTypes.sol";
import { CoreMockToken } from "../../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../../helpers/EarnVaultTestDeployer.sol";
import { VedaEngineTestBase } from "../../helpers/VedaEngineTestBase.sol";

contract VedaEngineFeeFreshnessTest is VedaEngineTestBase {
    uint256 private constant ONE = 1_000_000;

    address private constant USER = address(0xA11CE);
    address private constant FEE_RECIPIENT = address(0xFEE);

    CoreMockToken private earnShare;
    EarnVault private earnVault;
    EarnFees private earnFees;

    function setUp() public override {
        vm.warp(30 days);
        _deployVedaStack(6);

        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient({ account: FEE_RECIPIENT, rateBps: 1_000 });
        earnShare = new CoreMockToken("Earn Share", "EARN", 6);
        earnVault = EarnVaultTestDeployer.deploy(address(engine), address(earnShare), address(this), config);
        earnFees = EarnFees(earnVault.earnFees());
        engine.initializeEarnVault(address(earnVault));

        asset.mint(USER, 1_000 * ONE);
        vm.startPrank(USER);
        asset.approve(address(earnVault), type(uint256).max);
        earnShare.approve(address(earnVault), type(uint256).max);
        vm.stopPrank();
        _deposit(100 * ONE);
    }

    function testStaleRateCannotCrystallizeFeesAndFreshLowerReportDoesNotCharge() public {
        uint256 highWaterMarkBefore = earnFees.highWaterMark();
        uint256 supplyBefore = earnShare.totalSupply();

        accountant.setRate(1_100_000);
        vm.warp(block.timestamp + MAX_RATE_AGE + 1);
        assertFalse(earnVault.isFeeValuationFresh());
        assertEq(earnVault.totalAssets(), 110 * ONE);

        FeePreview memory preview = earnFees.previewAccruedFees();
        assertEq(preview.totalFeeAssets, 0);
        assertEq(preview.totalFeeEarnShares, 0);
        (uint256 feeAssets, uint256 feeEarnShares) = earnVault.accrueFees();
        assertEq(feeAssets, 0);
        assertEq(feeEarnShares, 0);
        assertEq(earnFees.claimableEarnShares(FEE_RECIPIENT), 0);
        assertEq(earnFees.highWaterMark(), highWaterMarkBefore);
        assertEq(earnShare.totalSupply(), supplyBefore);

        accountant.setRate(ONE);
        assertTrue(earnVault.isFeeValuationFresh());
        (feeAssets, feeEarnShares) = earnVault.accrueFees();
        assertEq(feeAssets, 0);
        assertEq(feeEarnShares, 0);
        assertEq(earnFees.claimableEarnShares(FEE_RECIPIENT), 0);
        assertEq(earnFees.highWaterMark(), highWaterMarkBefore);
    }

    function testStaleRateDoesNotBlockInstantOrQueuedExit() public {
        accountant.setRate(1_100_000);
        vm.warp(block.timestamp + MAX_RATE_AGE + 1);

        vm.prank(USER);
        uint256 assetsOut = earnVault.redeem(20 * ONE, USER, 1);
        assertEq(assetsOut, 22 * ONE);
        assertEq(earnFees.claimableEarnShares(FEE_RECIPIENT), 0);

        vm.prank(USER);
        bytes32 requestId = earnVault.requestRedeem(20 * ONE, _requestData(), receiver);
        assertFalse(earnFees.pendingFeeSnapshot(requestId).open);

        vm.prank(USER);
        earnVault.cancelRedeem(requestId, 20 * ONE);
        assertEq(earnShare.balanceOf(receiver), 20 * ONE);
        assertEq(earnFees.claimableEarnShares(FEE_RECIPIENT), 0);
        assertEq(earnVault.openRedeemRequestCount(), 0);
        assertTrue(earnVault.isAccountingAligned());
    }

    function testEmptyPoolStaleCancellationDefersBaselineInsteadOfChargingPrincipal() public {
        accountant.setRate(1_100_000);
        vm.warp(block.timestamp + MAX_RATE_AGE + 1);

        vm.prank(USER);
        bytes32 requestId = earnVault.requestRedeem(100 * ONE, _requestData(), receiver);
        assertFalse(earnFees.pendingFeeSnapshot(requestId).open);
        assertEq(earnShare.totalSupply(), 0);

        vm.prank(USER);
        earnVault.cancelRedeem(requestId, 100 * ONE);

        assertEq(earnShare.balanceOf(receiver), 100 * ONE);
        assertEq(earnFees.claimableEarnShares(FEE_RECIPIENT), 0);
        assertTrue(earnFees.feeBaselinesPending());
        assertTrue(earnVault.isAccountingAligned());

        accountant.setRate(1_100_000);
        (uint256 feeAssets, uint256 feeEarnShares) = earnVault.accrueFees();
        assertEq(feeAssets, 0);
        assertEq(feeEarnShares, 0);
        assertFalse(earnFees.feeBaselinesPending());
        assertEq(earnFees.highWaterMark(), 1_100_000);
        assertEq(earnFees.claimableEarnShares(FEE_RECIPIENT), 0);

        accountant.setRate(1_210_000);
        (feeAssets, feeEarnShares) = earnVault.accrueFees();
        assertEq(feeAssets, 1_100_000);
        assertGt(feeEarnShares, 0);
        assertEq(earnFees.claimableEarnShares(FEE_RECIPIENT), feeEarnShares);
    }

    function testFeeConfigurationCannotChangeAgainstStaleValuation() public {
        vm.warp(block.timestamp + MAX_RATE_AGE + 1);

        FeeConfig memory noFees;
        vm.expectRevert(EarnVault.FeeValuationStale.selector);
        earnVault.setFeeConfig(noFees);

        earnVault.disableFees();
        assertTrue(earnFees.feesDisabled());
    }

    function _deposit(uint256 assets) private {
        vm.prank(USER);
        assertEq(earnVault.deposit(assets, USER, assets), assets);
    }

    function _requestData() private view returns (bytes memory) {
        return abi.encode(
            VedaRedeemRequest({
                assetOut: address(asset), discountBps: 0, secondsToDeadline: 3_600, minQueuedAssets: 1
            })
        );
    }
}
