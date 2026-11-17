// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { HoldEngine } from "../../../src/engines/hold/HoldEngine.sol";
import { EarnVault } from "../../../src/core/EarnVault.sol";
import { FeeConfig } from "../../../src/interfaces/core/EarnFeeTypes.sol";
import { IEarnEngine } from "../../../src/interfaces/engines/IEarnEngine.sol";
import { IEarnEngineRedeem } from "../../../src/interfaces/engines/IEarnEngineRedeem.sol";
import { IEarnEngineExactWithdraw } from "../../../src/interfaces/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineFeeValuation } from "../../../src/interfaces/engines/IEarnEngineFeeValuation.sol";
import { EarnVaultTestDeployer } from "../../helpers/EarnVaultTestDeployer.sol";
import { CoreMockToken } from "../../helpers/EarnVaultMocks.sol";

contract HoldEngineTest is Test {
    CoreMockToken asset;
    CoreMockToken share;
    HoldEngine engine;
    EarnVault vault;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address funder = makeAddr("funder");

    function setUp() public {
        asset = new CoreMockToken("USD", "USD", 6);
        share = new CoreMockToken("Earn USD", "eUSD", 6);
        engine = new HoldEngine(address(asset), address(this), "Hold USD", "hUSD");
        FeeConfig memory noFees;
        vault = EarnVaultTestDeployer.deploy(address(engine), address(share), address(this), noFees);
        engine.initializeEarnVault(address(vault));
        _fund(alice);
        _fund(bob);
        _fund(funder);
    }

    function _fund(address account) internal {
        asset.mint(account, 1_000_000e6);
        vm.startPrank(account);
        asset.approve(address(vault), type(uint256).max);
        share.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(address account, uint256 assets) internal returns (uint256 shares) {
        vm.prank(account);
        shares = vault.deposit(assets, account, 1);
    }

    function testMetadataAndCapabilities() public view {
        assertEq(engine.asset(), address(asset));
        assertEq(engine.shareScale(), 1e6);
        assertEq(engine.earnVault(), address(vault));
        assertEq(engine.name(), "Hold USD");
        assertEq(engine.symbol(), "hUSD");
        assertTrue(engine.supportsInterface(type(IEarnEngine).interfaceId));
        assertTrue(engine.supportsInterface(type(IEarnEngineRedeem).interfaceId));
        assertTrue(engine.supportsInterface(type(IEarnEngineExactWithdraw).interfaceId));
        assertFalse(engine.supportsInterface(type(IEarnEngineFeeValuation).interfaceId));
    }

    function testConstructorRejectsBadConfiguration() public {
        vm.expectRevert(HoldEngine.InvalidConfiguration.selector);
        new HoldEngine(address(0xdead), address(this), "Hold", "h");
        vm.expectRevert(HoldEngine.InvalidConfiguration.selector);
        new HoldEngine(address(asset), address(this), "", "h");
        vm.expectRevert(HoldEngine.InvalidConfiguration.selector);
        new HoldEngine(address(asset), address(this), "Hold", "");
    }

    function testBindsOnceToMatchingVault() public {
        vm.expectRevert(HoldEngine.AlreadyBound.selector);
        engine.initializeEarnVault(address(vault));
        HoldEngine other = new HoldEngine(address(share), address(this), "Hold", "h");
        vm.expectRevert(HoldEngine.InvalidConfiguration.selector);
        other.initializeEarnVault(address(vault));
    }

    function testOnlyBoundVaultMovesFunds() public {
        _deposit(alice, 100e6);
        vm.startPrank(alice);
        vm.expectRevert(HoldEngine.NotEarnVault.selector);
        engine.deposit(1e6);
        vm.expectRevert(HoldEngine.NotEarnVault.selector);
        engine.redeem(1e6, alice, 0);
        vm.expectRevert(HoldEngine.NotEarnVault.selector);
        engine.withdraw(1e6, alice);
        vm.stopPrank();
    }

    /// Without contributions, EarnShare tracks the stablecoin 1:1 through entries and exits.
    function testShareEqualsBalanceWithoutRewards() public {
        assertEq(_deposit(alice, 100e6), 100e6);
        assertEq(_deposit(bob, 250e6), 250e6);
        assertEq(engine.totalShares(), 350e6);
        assertEq(vault.totalAssets(), 350e6);
        assertEq(vault.previewRedeem(1e6), 1e6);

        vm.prank(alice);
        assertEq(vault.redeem(40e6, alice, 40e6), 40e6);
        vm.prank(bob);
        assertEq(vault.withdrawExact(50e6, bob, 50e6), 50e6);
        assertEq(share.balanceOf(alice), 60e6);
        assertEq(share.balanceOf(bob), 200e6);
        assertEq(vault.totalAssets(), 260e6);
        assertEq(vault.previewRedeem(1e6), 1e6);
    }

    /// A contribution is the only thing that raises the share price, pro rata to current holders.
    function testContributionRaisesSharePriceProRata() public {
        _deposit(alice, 100e6);
        _deposit(bob, 300e6);
        vm.prank(funder);
        vault.contribute(4e6);
        assertEq(vault.totalAssets(), 404e6);
        assertEq(vault.totalEarnShares(), 400e6);
        assertEq(vault.previewRedeem(100e6), 101e6);

        vm.prank(alice);
        assertEq(vault.redeem(100e6, alice, 101e6), 101e6);
        vm.prank(bob);
        assertEq(vault.redeem(300e6, bob, 303e6), 303e6);
        assertEq(engine.totalShares(), 0);
    }

    /// Later entrants buy in at the raised price and do not share earlier contributions.
    function testLateEntrantPaysCurrentPrice() public {
        _deposit(alice, 100e6);
        vm.prank(funder);
        vault.contribute(10e6);
        uint256 bobShares = _deposit(bob, 110e6);
        assertEq(bobShares, 100e6);
        assertEq(vault.previewRedeem(bobShares), 110e6);
    }

    /// Base asset sent straight to the engine does not move the price until absorbed.
    function testDirectTransferIsQuarantinedUntilAbsorbed() public {
        _deposit(alice, 100e6);
        vm.prank(funder);
        asset.transfer(address(engine), 5e6);
        assertEq(engine.totalShares(), 105e6);
        assertEq(vault.totalAssets(), 100e6);
        assertEq(vault.previewRedeem(100e6), 100e6);
        vault.absorbEngineShareSurplus(5e6);
        assertEq(vault.totalAssets(), 105e6);
        assertEq(vault.previewRedeem(100e6), 105e6);
    }

    function testFuzzRoundTripIsLossless(uint256 a, uint256 b, uint256 reward) public {
        a = bound(a, 1e6, 1_000_000e6);
        b = bound(b, 1e6, 1_000_000e6);
        reward = bound(reward, 0, a / 10);
        _deposit(alice, a);
        if (reward > 0) {
            vm.prank(funder);
            vault.contribute(reward);
        }
        uint256 bobShares = _deposit(bob, b);
        vm.prank(bob);
        uint256 out = vault.redeem(bobShares, bob, 1);
        assertLe(out, b);
        uint256 aliceShares = share.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, 1);
        assertGe(asset.balanceOf(alice), 1_000_000e6 + reward - 2);
    }
}
