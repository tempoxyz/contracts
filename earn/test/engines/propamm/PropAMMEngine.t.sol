// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import {
    PropAMMTestToken,
    PropAMMTestOracle,
    PropAMMTestVenue,
    PropAMMTestEarnVault
} from "../../helpers/PropAMMEngineMocks.sol";
import { PropAMMEngine } from "../../../src/engines/propamm/PropAMMEngine.sol";

contract PropAMMEngineTest is Test {
    PropAMMTestToken usdc;
    PropAMMTestToken baseToken;
    PropAMMTestOracle oracle;
    PropAMMTestVenue pool;
    PropAMMEngine engine;
    PropAMMTestEarnVault vault;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new PropAMMTestToken("USDC.e");
        baseToken = new PropAMMTestToken("BASE");
        oracle = new PropAMMTestOracle();
        pool = new PropAMMTestVenue(baseToken, usdc, oracle);
        engine = new PropAMMEngine(address(pool), address(this), 1 days, bytes32(uint256(1)));
        vault = new PropAMMTestEarnVault(engine, usdc);
        engine.initializeEarnVault(address(vault));
        usdc.mint(alice, 1000e6);
        usdc.mint(bob, 1000e6);
        baseToken.mint(address(pool), 10000e6);
        usdc.mint(address(pool), 10000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function buy(address who, uint256 assets) internal returns (uint256) {
        vm.prank(who);
        return vault.deposit(assets);
    }

    function testFutureAndZeroPricesFail() public {
        oracle.set(105_000_000, block.timestamp + 1);
        vm.expectRevert();
        engine.totalAssets();
        oracle.set(0, block.timestamp);
        vm.expectRevert();
        engine.totalAssets();
    }

    function testOnlyBoundVaultCanMoveFunds() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.deposit(1e6);
        vm.prank(alice);
        vm.expectRevert();
        engine.redeem(1, alice, 0);
        vm.prank(alice);
        vm.expectRevert();
        engine.withdraw(1, alice);
    }

    function testOracleReplacementFailsClosed() public {
        buy(alice, 105e6);
        pool.replaceOracle(new PropAMMTestOracle());
        vm.expectRevert();
        engine.totalAssets();
        assertFalse(engine.isFeeValuationFresh());
    }

    function testFeeOnInputTokenRevertsAtomically() public {
        usdc.setChargeFee(true);
        uint256 balance = usdc.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(105e6);
        assertEq(usdc.balanceOf(alice), balance);
        assertEq(engine.totalShares(), 0);
    }

    function testFeeOnBaseTokenRevertsAtomically() public {
        baseToken.setChargeFee(true);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(105e6);
        assertEq(usdc.balanceOf(alice), 1000e6);
        assertEq(baseToken.balanceOf(address(engine)), 0);
    }

    function testReentrancyAndTransientValuationAreRejected() public {
        buy(alice, 105e6);
        pool.setCallback(address(vault));
        buy(bob, 105e6);
        assertTrue(pool.callbackAttempted());
        assertFalse(pool.reentrySucceeded());
        assertFalse(pool.readSucceeded());
        assertEq(engine.totalAssets(), 210e6);
    }

    function testExactWithdrawalRoundsSharesUp() public {
        uint256 shares = buy(alice, 105e6);
        oracle.set(110_000_000, block.timestamp);
        uint256 expected = engine.previewWithdraw(1);
        assertEq(vault.withdraw(1, alice), expected);
        assertEq(engine.totalShares(), shares - expected);
    }

    function testBindingIsOwnerOnlyOnceAndAssetChecked() public {
        vm.expectRevert();
        engine.initializeEarnVault(address(vault));

        PropAMMEngine candidate = new PropAMMEngine(address(pool), address(this), 1 days, bytes32(uint256(2)));
        vm.prank(alice);
        vm.expectRevert();
        candidate.initializeEarnVault(address(vault));
        PropAMMTestEarnVault wrongAssetVault = new PropAMMTestEarnVault(candidate, baseToken);
        vm.expectRevert(PropAMMEngine.InvalidConfiguration.selector);
        candidate.initializeEarnVault(address(wrongAssetVault));
        assertEq(candidate.earnVault(), address(0));
    }

    function testFeeOnPayoutRevertsWithoutConsumingBase() public {
        uint256 shares = buy(alice, 105e6);
        usdc.setChargeFee(true);
        vm.expectRevert();
        vault.redeem(shares, alice, 1);
        assertEq(engine.totalShares(), shares);
        assertEq(usdc.balanceOf(alice), 895e6);
    }
}
