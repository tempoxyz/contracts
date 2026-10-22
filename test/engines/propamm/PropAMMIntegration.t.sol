// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { PropAMMEngine } from "../../../src/engines/propamm/PropAMMEngine.sol";
import { IPropAMMVenue } from "../../../src/interfaces/external/propamm/IPropAMMVenue.sol";
import { EarnVault } from "../../../src/core/EarnVault.sol";
import { FeeConfig, ExcessReturnFee } from "../../../src/interfaces/core/EarnFeeTypes.sol";
import { EarnVaultTestDeployer } from "../../helpers/EarnVaultTestDeployer.sol";
import { CoreMockToken } from "../../helpers/EarnVaultMocks.sol";
import { MemoMockToken, MockRecipientRegistry, PropAMMTestOracle } from "../../helpers/PropAMMEngineMocks.sol";

interface IPropAMMPoolAdmin is IPropAMMVenue {
    function roundingCredit(bytes32 routeKey) external view returns (uint256);
    function setTakerAllowed(address taker, bool allowed) external;
    function setRecipientAllowed(address recipient, bool allowed) external;
    function setMaxPriceDeviationBps(uint256 bps) external;
    function setMaxOracleAge(uint256 age) external;
    function pause() external;
    function unpause() external;
    function withdraw(address token, address recipient, uint256 amount, bytes32 memo) external;
}

contract PropAMMIntegrationTest is Test {
    MemoMockToken asset;
    MemoMockToken baseToken;
    CoreMockToken share;
    PropAMMTestOracle oracle;
    IPropAMMPoolAdmin pool;
    PropAMMEngine engine;
    EarnVault vault;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address customer = makeAddr("customer");

    function setUp() public {
        _setUp(6, 6, 8);
    }

    function _setUp(uint8 baseDecimals, uint8 quoteDecimals, uint8 oracleDecimals) internal {
        vm.warp(1_800_000_000);
        asset = new MemoMockToken("Quote", "Quote", quoteDecimals);
        baseToken = new MemoMockToken("Base", "Base", baseDecimals);
        share = new CoreMockToken("Earn Base", "eBASE", 6);
        oracle = new PropAMMTestOracle();
        vm.mockCall(address(oracle), abi.encodeWithSignature("decimals()"), abi.encode(oracleDecimals));
        oracle.set(105 * 10 ** uint256(oracleDecimals) / 100, vm.getBlockTimestamp());
        // PropAMM pins solc 0.8.30; deploy its unmodified artifact alongside Earn's 0.8.36 code.
        pool = IPropAMMPoolAdmin(
            deployCode(
                "test/fixtures/propamm/DirectPropAMM.json",
                abi.encode(
                    address(baseToken),
                    address(asset),
                    address(oracle),
                    address(new MockRecipientRegistry()),
                    address(this),
                    address(this),
                    1 days,
                    50
                )
            )
        );
        engine = _newEngine();
        FeeConfig memory noFees;
        vault = EarnVaultTestDeployer.deploy(address(engine), address(share), address(this), noFees);
        engine.initializeEarnVault(address(vault));
        baseToken.mint(address(pool), 10_000 * 10 ** uint256(baseDecimals));
        asset.mint(address(pool), 10_000 * 10 ** uint256(quoteDecimals));
        pool.unpause();
        _fund(alice);
        _fund(bob);
    }

    function testDecimalConfigurations() public {
        uint8[3] memory baseDecimals = [18, 6, 6];
        uint8[3] memory quoteDecimals = [6, 18, 6];
        uint8[3] memory oracleDecimals = [8, 18, 12];
        for (uint256 i; i < baseDecimals.length; ++i) {
            _setUp(baseDecimals[i], quoteDecimals[i], oracleDecimals[i]);
            uint256 baseUnit = 10 ** uint256(baseDecimals[i]);
            uint256 quoteUnit = 10 ** uint256(quoteDecimals[i]);
            uint256 principal = 100 * quoteUnit + 1;
            uint256 startingCash = asset.balanceOf(alice);
            _deposit(alice, principal);
            uint256 backing = baseToken.balanceOf(address(engine));
            assertEq(engine.shareScale(), baseUnit);
            assertEq(backing, principal * baseUnit * 20 / (21 * quoteUnit));
            assertEq(engine.totalShares(), backing);
            assertEq(engine.totalAssets(), backing * 21 * quoteUnit / (20 * baseUnit));
            assertEq(engine.valueOf(baseUnit), 21 * quoteUnit / 20);

            uint256 withdrawal = 7 * quoteUnit + 1;
            uint256 maximumShares = share.balanceOf(alice);
            vm.prank(alice);
            vault.withdrawExact(withdrawal, alice, maximumShares);
            assertEq(asset.balanceOf(alice), startingCash - principal + withdrawal);
            assertLt(baseToken.balanceOf(address(engine)), backing);
            _redeem(alice, share.balanceOf(alice), 1);
            assertEq(engine.totalShares(), vault.surplusEngineShares());
            // EarnShare has six decimals; finer venue units can remain as quarantined rounding surplus.
            assertLt(engine.totalShares(), 2 * baseUnit / 1e6);
            assertEq(share.balanceOf(alice), 0);
            uint256 endingCash = asset.balanceOf(alice);
            assertLe(endingCash, startingCash);
            assertLe(startingCash - endingCash, 3 * quoteUnit / 1e6);
        }
    }

    function _newEngine() internal returns (PropAMMEngine result) {
        result = new PropAMMEngine(address(pool), address(this), 1 days, bytes32(uint256(1)));
        pool.setTakerAllowed(address(result), true);
        pool.setRecipientAllowed(address(result), true);
    }

    function _fund(address account) internal {
        asset.mint(account, 1_000 * 10 ** uint256(asset.decimals()));
        vm.startPrank(account);
        asset.approve(address(vault), type(uint256).max);
        share.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address account, uint256 assets) internal returns (uint256) {
        vm.prank(account);
        return vault.deposit(assets, account, 1);
    }

    function _redeem(address account, uint256 shares, uint256 minAssets) internal returns (uint256) {
        vm.prank(account);
        return vault.redeem(shares, account, minAssets);
    }

    function testLongerPoolFreshnessWindowCannotChargeNewPrincipalForOldYield() public {
        FeeConfig memory config;
        config.excess = ExcessReturnFee(true, customer, 0, 2_000);
        vault.setFeeConfig(config);
        _deposit(alice, 105e6);
        oracle.set(105_100_000, vm.getBlockTimestamp());
        pool.pause();
        pool.setMaxOracleAge(2 days);
        pool.unpause();
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        assertFalse(vault.isFeeValuationFresh());
        vm.expectRevert(PropAMMEngine.InvalidOracle.selector);
        _deposit(bob, 105_100_000);
        vm.prank(bob);
        vm.expectRevert(PropAMMEngine.InvalidOracle.selector);
        vault.contribute(105_100_000);
        assertEq(asset.balanceOf(bob), 1_000e6);
        assertEq(share.balanceOf(bob), 0);
        assertEq(engine.totalShares(), 100e6);
        assertEq(asset.allowance(address(engine), address(pool)), 0);
        oracle.set(105_100_000, vm.getBlockTimestamp());
        (uint256 feeAssets,) = vault.accrueFees();
        assertEq(feeAssets, 20_000);
        _deposit(bob, 105_100_000);
        (feeAssets,) = vault.accrueFees();
        assertEq(feeAssets, 0);
        assertApproxEqAbs(vault.previewRedeem(share.balanceOf(bob)), 105_100_000, 2);
    }

    function testFreshnessBoundaryAndStaleExitsWithLongerPoolWindow() public {
        pool.pause();
        pool.setMaxOracleAge(2 days);
        pool.unpause();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertTrue(vault.isFeeValuationFresh());
        assertEq(_deposit(alice, 105e6), 100e6);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(vault.isFeeValuationFresh());
        vm.expectRevert(PropAMMEngine.InvalidOracle.selector);
        _deposit(bob, 105e6);
        vm.prank(alice);
        assertEq(vault.withdrawExact(52_500_000, alice, 50e6), 50e6);
        assertEq(_redeem(alice, 50e6, 52_500_000), 52_500_000);
    }

    function testCreditCannotFundAWithdrawalWithoutBurningBase() public {
        _deposit(alice, 1e6);
        uint256 shares = share.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(PropAMMEngine.InvalidAmount.selector);
        vault.withdrawExact(1, alice, shares);
        assertEq(share.balanceOf(alice), shares);
        assertEq(engine.totalShares(), 952380);
    }

    function testStalePriceIsDiscoveredByEarnVault() public {
        _deposit(alice, 105e6);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        assertFalse(vault.isFeeValuationFresh());
        FeeConfig memory config;
        vm.expectRevert(EarnVault.FeeValuationStale.selector);
        vault.setFeeConfig(config);
        uint256 aliceShares = share.balanceOf(alice);
        vm.expectRevert();
        _redeem(alice, aliceShares, 1);
        assertEq(share.balanceOf(alice), 100e6);
        oracle.set(105_000_000, vm.getBlockTimestamp());
        assertTrue(vault.isFeeValuationFresh());
        assertEq(_redeem(alice, share.balanceOf(alice), 105e6), 105e6);
    }

    function testBaseDonationIsQuarantinedAndCashIsExcluded() public {
        _deposit(alice, 105e6);
        baseToken.mint(address(engine), 1e6);
        asset.mint(address(engine), 1e6);
        assertEq(vault.surplusEngineShares(), 1e6);
        assertEq(vault.totalAssets(), 105e6);
        vault.absorbEngineShareSurplus(1e6);
        assertEq(vault.totalAssets(), 106_050_000);
        assertEq(_redeem(alice, share.balanceOf(alice), 106_050_000), 106_050_000);
        assertEq(asset.balanceOf(address(engine)), 1e6);
    }

    function testMigrationPreservesSharesAndDrainsOldEngine() public {
        _deposit(alice, 105e6);
        PropAMMEngine replacement = _newEngine();
        replacement.initializeEarnVault(address(vault));
        assertEq(vault.migrateEngine(address(replacement), 100e6, 105e6), 100e6);
        assertEq(vault.engine(), address(replacement));
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(engine.totalShares(), 0);
        assertEq(baseToken.balanceOf(address(engine)), 0);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(pool.roundingCredit(keccak256(abi.encode(address(engine), address(engine), bytes32(uint256(1))))), 0);
        assertEq(_redeem(alice, share.balanceOf(alice), 105e6), 105e6);
    }

    function testIlliquidPoolRollsBackBurnAndMigration() public {
        _deposit(alice, 105e6);
        pool.pause();
        pool.withdraw(address(asset), address(this), asset.balanceOf(address(pool)), bytes32(0));
        pool.unpause();
        vm.expectRevert();
        _redeem(alice, 100e6, 105e6);
        PropAMMEngine replacement = _newEngine();
        replacement.initializeEarnVault(address(vault));
        vm.expectRevert();
        vault.migrateEngine(address(replacement), 100e6, 105e6);
        assertEq(vault.engine(), address(engine));
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(engine.totalShares(), 100e6);
        assertEq(baseToken.balanceOf(address(engine)), 100e6);
    }

    function testRevokedPermissionRollsBackDeposit() public {
        pool.setTakerAllowed(address(engine), false);
        vm.expectRevert(PropAMMEngine.InvalidConfiguration.selector);
        _deposit(alice, 105e6);
        assertEq(asset.balanceOf(alice), 1_000e6);
        assertEq(share.balanceOf(alice), 0);
    }

    function testPoolPauseRollsBackRedemption() public {
        _deposit(alice, 105e6);
        pool.pause();
        vm.expectRevert(PropAMMEngine.InvalidConfiguration.selector);
        _redeem(alice, 100e6, 105e6);
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(engine.totalShares(), 100e6);
    }

    function testBlockedPoolRecipientRollsBackDeposit() public {
        baseToken.blockReceiver(address(engine));
        vm.expectRevert(bytes("BLOCKED"));
        _deposit(alice, 105e6);
        assertEq(asset.balanceOf(alice), 1_000e6);
        assertEq(share.totalSupply(), 0);
        assertEq(engine.totalShares(), 0);
    }

    function testPriceAnchorRejectsDiscontinuousExecution() public {
        _deposit(alice, 105e6);
        oracle.set(110_000_000, vm.getBlockTimestamp());
        assertEq(vault.totalAssets(), 110e6);
        vm.expectRevert();
        _redeem(alice, 100e6, 110e6);
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(baseToken.balanceOf(address(engine)), 100e6);
    }

    function testRevokedRecipientRollsBackRedemption() public {
        _deposit(alice, 105e6);
        pool.setRecipientAllowed(address(engine), false);
        vm.expectRevert(PropAMMEngine.InvalidConfiguration.selector);
        _redeem(alice, 100e6, 105e6);
        assertEq(share.balanceOf(alice), 100e6);
        assertEq(engine.totalShares(), 100e6);
    }

    function testFuzzUnchangedPriceConservesCash(uint64 first, uint64 second, uint32 fraction) public {
        uint256 aliceAssets = bound(first, 100, 500e6);
        uint256 bobAssets = bound(second, 100, 500e6);
        uint256 aliceShares = _deposit(alice, aliceAssets);
        uint256 partialShares = bound(fraction, 1, aliceShares - 1);
        uint256 alicePayout = _redeem(alice, partialShares, 1);
        uint256 bobShares = _deposit(bob, bobAssets);
        uint256 bobPayout = _redeem(bob, bobShares, 1);
        alicePayout += _redeem(alice, share.balanceOf(alice), 1);
        assertEq(alicePayout + bobPayout, aliceAssets + bobAssets);
        assertEq(share.totalSupply(), 0);
        assertEq(engine.totalShares(), 0);
        assertEq(engine.totalAssets(), 0);
        assertEq(asset.allowance(address(engine), address(pool)), 0);
        assertEq(baseToken.allowance(address(engine), address(pool)), 0);
    }

    function testNewDepositAfterLossTracksBaseWithoutDilution() public {
        uint256 first = _deposit(alice, 105e6);
        oracle.set(104_900_000, vm.getBlockTimestamp());
        uint256 second = _deposit(bob, 104_900_000);
        assertEq(first, second);
        assertEq(_redeem(alice, first, 104_900_000), 104_900_000);
        assertEq(_redeem(bob, second, 104_900_000), 104_900_000);
    }

    function testExactWithdrawalChargesConsumedBase() public {
        _deposit(alice, 105e6);
        uint256 beforeShares = engine.totalShares();
        uint256 expected = engine.previewWithdraw(21e6);
        vm.prank(alice);
        uint256 burned = vault.withdrawExact(21e6, alice, expected);
        assertEq(burned, 20e6);
        assertEq(beforeShares - engine.totalShares(), burned);
        assertEq(_redeem(alice, share.balanceOf(alice), 84e6), 84e6);
    }

    function testRepeatedTinyRoundTripsCannotDrainPool() public {
        uint256 cashBefore = asset.balanceOf(address(pool));
        for (uint256 i; i < 20; ++i) {
            uint256 amount = i + 2;
            uint256 minted = _deposit(alice, amount);
            assertEq(_redeem(alice, minted, 1), amount);
            assertEq(engine.totalShares(), 0);
        }
        assertEq(asset.balanceOf(address(pool)), cashBefore);
        assertEq(asset.balanceOf(alice), 1_000e6);
    }
}
