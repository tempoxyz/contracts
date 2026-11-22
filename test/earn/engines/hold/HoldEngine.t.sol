// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { HoldEngine } from "../../../../src/earn/engines/hold/HoldEngine.sol";
import { EarnVault } from "../../../../src/earn/core/EarnVault.sol";
import { FeeConfig } from "../../../../src/interfaces/earn/EarnFeeTypes.sol";
import { IEarnEngine } from "../../../../src/interfaces/earn/engines/IEarnEngine.sol";
import { IEarnEngineRedeem } from "../../../../src/interfaces/earn/engines/IEarnEngineRedeem.sol";
import { IEarnEngineExactWithdraw } from "../../../../src/interfaces/earn/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineFeeValuation } from "../../../../src/interfaces/earn/engines/IEarnEngineFeeValuation.sol";
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

    function testConstructorRejectsCodelessAsset() public {
        vm.expectRevert(HoldEngine.InvalidConfiguration.selector);
        new HoldEngine(address(0xdead), address(this), "Hold", "h");
    }

    function testConstructorRejectsEmptyName() public {
        vm.expectRevert(HoldEngine.InvalidConfiguration.selector);
        new HoldEngine(address(asset), address(this), "", "h");
    }

    function testConstructorRejectsEmptySymbol() public {
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

    function testOnlyOwnerBindsAndHandsOff() public {
        HoldEngine fresh = new HoldEngine(address(asset), address(this), "Hold", "h");
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.initializeEarnVault(address(vault));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.initializeEarnVault(address(vault), alice);
        vm.stopPrank();

        vm.expectRevert(HoldEngine.InvalidConfiguration.selector);
        fresh.initializeEarnVault(address(vault), address(0));
        assertEq(fresh.earnVault(), address(0));

        fresh.initializeEarnVault(address(vault), bob);
        assertEq(fresh.earnVault(), address(vault));
        assertEq(fresh.owner(), bob);
        assertEq(fresh.pendingOwner(), address(0));
    }

    function testOneArgumentBindKeepsOwner() public {
        HoldEngine fresh = new HoldEngine(address(asset), address(this), "Hold", "h");
        fresh.initializeEarnVault(address(vault));
        assertEq(fresh.owner(), address(this));
    }

    function testBindRejectsCodelessVault() public {
        HoldEngine fresh = new HoldEngine(address(asset), address(this), "Hold", "h");
        vm.expectRevert(HoldEngine.InvalidConfiguration.selector);
        fresh.initializeEarnVault(address(0xbeef));
    }

    function testUnboundEngineRejectsFundFlows() public {
        HoldEngine fresh = new HoldEngine(address(asset), address(this), "Hold", "h");
        vm.startPrank(address(0));
        vm.expectRevert(HoldEngine.NotEarnVault.selector);
        fresh.deposit(1);
        vm.expectRevert(HoldEngine.NotEarnVault.selector);
        fresh.redeem(1, alice, 0);
        vm.expectRevert(HoldEngine.NotEarnVault.selector);
        fresh.withdraw(1, alice);
        vm.stopPrank();
    }

    function testFundFlowGuards() public {
        _deposit(alice, 100e6);
        vm.startPrank(address(vault));
        vm.expectRevert(HoldEngine.InvalidAmount.selector);
        engine.deposit(0);
        vm.expectRevert(HoldEngine.InvalidAmount.selector);
        engine.redeem(0, alice, 0);
        vm.expectRevert(HoldEngine.InvalidAmount.selector);
        engine.redeem(100e6 + 1, alice, 0);
        vm.expectRevert(HoldEngine.InvalidAmount.selector);
        engine.withdraw(0, alice);
        vm.expectRevert(HoldEngine.InvalidAmount.selector);
        engine.withdraw(100e6 + 1, alice);
        vm.expectRevert(HoldEngine.InvalidReceiver.selector);
        engine.redeem(1e6, address(0), 0);
        vm.expectRevert(HoldEngine.InvalidReceiver.selector);
        engine.redeem(1e6, address(engine), 0);
        vm.expectRevert(HoldEngine.InvalidReceiver.selector);
        engine.withdraw(1e6, address(0));
        vm.expectRevert(HoldEngine.InvalidReceiver.selector);
        engine.withdraw(1e6, address(engine));
        vm.expectRevert(HoldEngine.InsufficientAssetsReceived.selector);
        engine.redeem(1e6, alice, 1e6 + 1);
        vm.stopPrank();
        vm.expectRevert(HoldEngine.InvalidAmount.selector);
        engine.previewWithdraw(0);
        assertEq(engine.previewWithdraw(7), 7);
        assertEq(engine.previewRedeem(7), 7);
        assertEq(engine.valueOf(7), 7);
    }

    /// Transfers that deliver less than the requested amount revert instead of desyncing the ledger.
    function testSkimmingTokenIsRejected() public {
        SkimToken skim = new SkimToken();
        HoldEngine skimEngine = new HoldEngine(address(skim), address(this), "Hold", "h");
        address boundVault = address(new AssetOnlyVault(address(skim)));
        skimEngine.initializeEarnVault(boundVault);
        skim.mint(boundVault, 100e6);
        vm.startPrank(boundVault);
        skim.approve(address(skimEngine), type(uint256).max);
        assertEq(skimEngine.deposit(50e6), 50e6);

        skim.setSkim(true);
        vm.expectRevert(HoldEngine.InexactTransfer.selector);
        skimEngine.deposit(10e6);
        vm.expectRevert(HoldEngine.InexactTransfer.selector);
        skimEngine.withdraw(10e6, alice);
        vm.expectRevert(HoldEngine.InsufficientAssetsReceived.selector);
        skimEngine.redeem(10e6, alice, 10e6);
        assertEq(skimEngine.redeem(10e6, alice, 0), 10e6 - 1);
        vm.stopPrank();
        assertEq(skimEngine.totalShares(), 40e6);
    }

    /// Engine surplus is absorbable by any account, not only an operator.
    function testAnyoneCanAbsorbEngineSurplus() public {
        _deposit(alice, 100e6);
        vm.prank(funder);
        asset.transfer(address(engine), 5e6);
        vm.prank(bob);
        vault.absorbEngineShareSurplus(5e6);
        assertEq(vault.totalAssets(), 105e6);
    }

    /// Base asset sent to the EarnVault is not engine surplus and cannot be absorbed.
    function testBaseAssetSentToVaultIsNotAbsorbable() public {
        _deposit(alice, 100e6);
        vm.prank(funder);
        asset.transfer(address(vault), 5e6);
        assertEq(vault.totalAssets(), 100e6);
        vm.expectRevert();
        vault.absorbEngineShareSurplus(1);
        assertEq(asset.balanceOf(address(vault)), 5e6);
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
        assertGe(out + 2, b);
        uint256 aliceShares = share.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, 1);
        assertGe(asset.balanceOf(alice), 1_000_000e6 + reward - 2);
    }
}

/// @dev Delivers one raw unit less than requested on every transfer once skimming is on.
contract SkimToken is CoreMockToken {
    bool public skimOn;

    constructor() CoreMockToken("Skim", "SKM", 6) { }

    function setSkim(bool on) external {
        skimOn = on;
    }

    function _transfer(address from, address to, uint256 value) internal override {
        super._transfer(from, to, value);
        if (skimOn && value > 0) {
            balanceOf[to] -= 1;
            totalSupply -= 1;
        }
    }
}

/// @dev Minimal vault stand-in exposing only the asset, for binding an engine in isolation.
contract AssetOnlyVault {
    address public immutable asset;

    constructor(address asset_) {
        asset = asset_;
    }
}
