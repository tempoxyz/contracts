// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { VedaEngine } from "../../../src/engines/veda/VedaEngine.sol";
import { MockCore } from "../../helpers/VedaEngineMocks.sol";
import { VedaEngineTestBase } from "../../helpers/VedaEngineTestBase.sol";

contract VedaEngineAccountingTest is VedaEngineTestBase {
    function testExactWithdrawCeilsSharesLeavesDustAndForwardsExactAssets() public {
        accountant.setRate(3e6); // 1 share == 3 assets
        asset.mint(address(core), 30);
        assertEq(core.deposit(30), 10); // 30 assets -> 10 shares

        // Exact-asset synthesis ceils the share cost.
        assertEq(engine.previewWithdraw(10), 4); // ceil(10 * 1e6 / 3e6) == 4

        uint256 burned = core.withdraw(10, receiver);
        assertEq(burned, 4);
        assertEq(asset.balanceOf(receiver), 10); // receiver gets EXACTLY the requested assets
        assertEq(asset.balanceOf(address(engine)), 2); // 12 delivered - 10 forwarded == 2 dust stays here
        assertEq(vault.balanceOf(address(engine)), 6); // 10 - 4 burned
        assertEq(teller.bulkWithdrawCalls(), 1);
        assertEq(teller.publicWithdrawCalls(), 0);
    }

    function testValuationUsesSafeAccountantQuoteForActiveAndExactShares() public {
        accountant.setRate(3e6);
        asset.mint(address(core), 30);
        core.deposit(30);

        assertEq(engine.previewRedeem(4), 12);
        assertEq(engine.totalAssets(), 30);

        accountant.setUnsafeRate(9e6);
        assertEq(engine.rate(), 3e6);
        assertEq(engine.previewRedeem(4), 12);
    }

    function testRedeemRejectsTellerReturnWithoutReceiverDelivery() public {
        address redirectedReceiver = address(0xBAD);
        asset.mint(address(core), 30);
        core.deposit(30);
        teller.setWithdrawalReceiverOverride(redirectedReceiver);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.InsufficientAssetsReceived.selector, 10, 0));
        core.redeem(10, receiver, 10);

        assertEq(asset.balanceOf(receiver), 0);
        assertEq(asset.balanceOf(redirectedReceiver), 0);
        assertEq(vault.balanceOf(address(engine)), 30);
    }

    function testRedeemRejectsFeeOnTransferUnderDelivery() public {
        asset.mint(address(core), 100);
        core.deposit(100);
        asset.setFeeBps(100);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.InsufficientAssetsReceived.selector, 100, 99));
        core.redeem(100, receiver, 100);

        assertEq(asset.balanceOf(receiver), 0);
        assertEq(vault.balanceOf(address(engine)), 100);
    }

    function testRedeemRejectsUnexpectedVenueShareBurn() public {
        asset.mint(address(core), 30);
        core.deposit(30);
        teller.setShareBurnOverride(20);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.UnexpectedVenueSharesBurned.selector, 10, 20));
        core.redeem(10, receiver, 10);

        assertEq(asset.balanceOf(receiver), 0);
        assertEq(vault.balanceOf(address(engine)), 30);
    }

    function testExactWithdrawRejectsFeeOnTransferDelivery() public {
        asset.mint(address(core), 100);
        core.deposit(100);
        asset.setFeeBps(100);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.InsufficientAssetsReceived.selector, 100, 99));
        core.withdraw(100, receiver);

        assertEq(asset.balanceOf(receiver), 0);
        assertEq(vault.balanceOf(address(engine)), 100);
    }

    function testAtomicDepositRateUpdateRedeemReverts() public {
        asset.mint(address(core), 10);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.RateChangedWithinTransaction.selector, 1e6, 2e6));
        core.depositUpdateRateAndRedeem(10, accountant, 2e6, receiver);

        assertEq(vault.balanceOf(address(engine)), 0);
        assertEq(asset.balanceOf(receiver), 0);
        assertEq(accountant.getRate(), 1e6);
    }

    function testAtomicDepositRateUpdateAsyncRequestReverts() public {
        asset.mint(address(core), 10);

        vm.expectRevert(abi.encodeWithSelector(VedaEngine.RateChangedWithinTransaction.selector, 1e6, 2e6));
        core.depositUpdateRateAndRequest(10, accountant, 2e6, address(asset), 0, 3600);

        assertEq(vault.balanceOf(address(engine)), 0);
        assertEq(vault.balanceOf(address(queue)), 0);
        assertEq(queue.nonce(), 1);
        assertEq(accountant.getRate(), 1e6);
    }

    function testRedeemAllowsStreamingRateToRepriceAfterSupplyChange() public {
        accountant.setSupplyRateDivisor(1e6);
        vault.mint(address(engine), 1e6);
        asset.mint(address(vault), 1_000_001);

        assertEq(accountant.getRate(), 1_000_001);
        assertEq(core.redeem(1e6, receiver, 1_000_001), 1_000_001);
        assertEq(accountant.getRate(), 1e6);
        assertEq(vault.balanceOf(address(engine)), 0);
        assertEq(asset.balanceOf(receiver), 1_000_001);
    }

    function testStaleAccountantRateBlocksDepositBeforeAssetsMove() public {
        uint64 updatedAt = accountant.lastStrategistUpdateTimestamp();
        vm.warp(uint256(updatedAt) + MAX_RATE_AGE + 1);
        asset.mint(address(core), 10);

        vm.expectRevert(
            abi.encodeWithSelector(VedaEngine.StaleAccountantRate.selector, updatedAt, block.timestamp, MAX_RATE_AGE)
        );
        core.deposit(10);

        assertEq(asset.balanceOf(address(core)), 10);
        assertEq(asset.balanceOf(address(engine)), 0);
        assertEq(vault.balanceOf(address(engine)), 0);
    }

    function testFutureAccountantTimestampBlocksDeposit() public {
        uint64 futureTimestamp = uint64(block.timestamp + 1);
        accountant.setLastStrategistUpdateTimestamp(futureTimestamp);
        asset.mint(address(core), 10);

        vm.expectRevert(
            abi.encodeWithSelector(VedaEngine.InvalidRateTimestamp.selector, futureTimestamp, block.timestamp)
        );
        core.deposit(10);
    }

    function testMaxRateAgeChangesOnlyWhileDepositsArePaused() public {
        core.setDepositsPaused(false);
        vm.expectRevert(VedaEngine.DepositsNotPaused.selector);
        engine.setMaxRateAge(2 days);

        core.setDepositsPaused(true);
        engine.setMaxRateAge(2 days);
        assertEq(engine.maxRateAge(), 2 days);
    }

    function testEighteenDecimalVaultUsesItsActualShareScale() public {
        _deployVedaStack(18);
        core = new MockCore(asset);
        core.setEngine(engine);
        engine.initializeEarnVault(address(core));
        assertEq(engine.shareScale(), 1e18);

        asset.mint(address(core), 100e6);
        assertEq(core.deposit(100e6), 100e18);
        assertEq(engine.previewRedeem(25e18), 25e6);
        assertEq(engine.valueOf(25e18), 25e6);
        assertEq(engine.totalAssets(), 100e6);
        assertEq(engine.previewWithdraw(10e6), 10e18);

        assertEq(core.withdraw(10e6, receiver), 10e18);
        assertEq(asset.balanceOf(receiver), 10e6);
        assertEq(vault.balanceOf(address(engine)), 90e18);
    }
}

/// @dev Starts from a deposit made in setUp, which Foundry runs as a separate transaction.
contract VedaEngineTransactionBoundaryTest is VedaEngineTestBase {
    function setUp() public override {
        super.setUp();
        asset.mint(address(core), 30);
        assertEq(core.deposit(10), 10);
    }

    function testSeparateTransactionInSameBlockAdoptsNewRate() public {
        accountant.setRate(2e6);

        assertEq(core.deposit(20), 10);
        assertEq(vault.balanceOf(address(engine)), 20);
    }
}
