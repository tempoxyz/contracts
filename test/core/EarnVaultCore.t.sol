// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { EarnFees } from "../../src/core/EarnFees.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../src/engines/ERC4626Engine.sol";
import { Simple4626Vault } from "../../src/demo/Simple4626Vault.sol";
import { DistributorConfig } from "../../src/interfaces/core/EarnVaultTypes.sol";
import {
    CoreMockEngine,
    CoreMockToken,
    CoreReentrantDepositEngine,
    earnVaultTestNoFees
} from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract EarnVaultTest is Test {
    event Redeemed(address indexed caller, address indexed receiver, uint256 shares, uint256 assets);
    event EngineShareShortfallReconciled(
        address indexed engine,
        uint256 previousManagedEngineShares,
        uint256 observedRawEngineShares,
        uint256 shortfallEngineShares,
        uint256 totalEarnShares
    );

    CoreMockToken asset;
    CoreMockToken share;
    CoreMockEngine engine;
    EarnVault core;
    address user = address(0xA11CE);
    address receiver = address(0xB0B);
    address operator = address(0x0FF1CE);
    address attacker = address(0xBAD);
    address victim = address(0xF00D);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        share = new CoreMockToken("Share", "SH", 18);
        engine = new CoreMockEngine(asset, 18);
        core = EarnVaultTestDeployer.deploy(address(engine), address(share), operator, earnVaultTestNoFees());
        asset.mint(user, 100 ether);
    }

    function testDepositMinimumEarnSharesPreventsContributionInflationAttack() public {
        asset.mint(attacker, 51);
        asset.mint(victim, 100);

        vm.startPrank(attacker);
        asset.approve(address(core), type(uint256).max);
        core.deposit(1, attacker, 1);
        vm.stopPrank();

        // Before the contribution, the victim's 100 assets preview to 100 EarnShare units.
        assertEq(core.convertEngineSharesToEarnShares(100), 100);

        vm.prank(victim);
        asset.approve(address(core), type(uint256).max);

        vm.prank(attacker);
        core.contribute(50);

        // Without the bound, floor(100 * 1 / 51) would mint one unit and let the
        // attacker extract the victim's rounding loss. The complete deposit rolls back.
        vm.startPrank(victim);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.MinimumEarnSharesNotMet.selector, 99, 1));
        core.deposit(100, victim, 99);
        vm.stopPrank();

        assertEq(asset.balanceOf(victim), 100);
        assertEq(share.balanceOf(victim), 0);
        assertEq(share.balanceOf(attacker), 1);
        assertEq(core.engineShares(), 51);
    }

    function testContributionCapReproducesAndBlocksSixDecimalFinding() public {
        (CoreMockToken asset6, CoreMockToken share6,, EarnVault core6) = _deploySixDecimalVault();
        asset6.mint(attacker, 1_000_000_001);
        asset6.mint(victim, 1_000_000_000);

        vm.startPrank(attacker);
        asset6.approve(address(core6), type(uint256).max);
        core6.deposit(1, attacker, 1);
        vm.expectRevert(
            abi.encodeWithSelector(EarnVault.RewardRateLimitExceeded.selector, 1_000_000_001 * 1_000_000, 1_000_000)
        );
        core6.contribute(1_000_000_000);
        vm.stopPrank();

        vm.startPrank(victim);
        asset6.approve(address(core6), type(uint256).max);
        assertEq(core6.deposit(1_000_000_000, victim, 1_000_000_000), 1_000_000_000);
        vm.stopPrank();

        assertEq(asset6.balanceOf(attacker), 1_000_000_000);
        assertEq(share6.balanceOf(attacker), 1);
        assertEq(share6.balanceOf(victim), 1_000_000_000);
        assertEq(core6.normalizedRewardRate(), 1_000_000);
        assertTrue(core6.isAccountingAligned());
    }

    function testPrincipalEntryRemainderCannotBypassRewardRateLimit() public {
        (CoreMockToken asset6, CoreMockToken share6,, EarnVault core6) = _deploySixDecimalVault();
        asset6.mint(attacker, 1_000_099);

        vm.startPrank(attacker);
        asset6.approve(address(core6), type(uint256).max);
        share6.approve(address(core6), type(uint256).max);
        core6.deposit(1, attacker, 1);
        core6.contribute(99);

        assertEq(core6.normalizedRewardRate(), 100_000_000);
        assertEq(core6.deposit(999_999, attacker, 9_999), 9_999);
        assertEq(core6.normalizedRewardRate(), 100_000_000);
        assertEq(core6.engineShares(), 1_000_000);
        assertEq(core6.rawEngineShares(), 1_000_099);
        assertEq(core6.surplusEngineShares(), 99);

        assertEq(core6.redeem(9_999, attacker, 1), 999_900);
        vm.stopPrank();

        assertEq(share6.balanceOf(attacker), 1);
        assertEq(core6.engineShares(), 100);
        assertEq(core6.rawEngineShares(), 199);
        assertEq(core6.surplusEngineShares(), 99);
        assertEq(core6.normalizedRewardRate(), 100_000_000);
        assertTrue(core6.isAccountingAligned());
    }

    function testCoarseEngineExitPreservesRemainingBackingAndLiveness() public {
        CoreMockToken coarseAsset = new CoreMockToken("Coarse Asset", "CAST", 18);
        CoreMockToken coarseShare = new CoreMockToken("Coarse Share", "CSH", 18);
        Simple4626Vault coarseVenue = new Simple4626Vault(address(coarseAsset), "Coarse Venue", "CVEN", 15);
        ERC4626Engine coarseEngine = new ERC4626Engine(IERC4626Vault(address(coarseVenue)), address(this), "", "");
        EarnVault coarseCore = EarnVaultTestDeployer.deploy(
            address(coarseEngine), address(coarseShare), operator, earnVaultTestNoFees()
        );
        coarseEngine.initializeEarnVault(address(coarseCore));

        coarseAsset.mint(user, 10_002_000);
        vm.startPrank(user);
        coarseAsset.approve(address(coarseCore), type(uint256).max);
        coarseShare.approve(address(coarseCore), type(uint256).max);
        assertEq(coarseCore.deposit(10_001_000, user, 10_001_000), 10_001_000);

        assertEq(coarseCore.redeem(10_000_999, user, 1), 10_000_000);

        assertEq(coarseCore.totalEarnShares(), 1);
        assertEq(coarseCore.engineShares(), 1);
        assertEq(coarseCore.rawEngineShares(), 1);
        assertEq(coarseCore.surplusEngineShares(), 0);
        assertEq(coarseCore.convertToEngineShares(1), 1);
        assertGt(
            coarseCore.normalizedRewardRate(), coarseCore.rewardRateBaseline() * coarseCore.MAX_REWARD_RATE_MULTIPLIER()
        );
        assertTrue(coarseCore.isAccountingAligned());

        // The rate limit still gates additional rewards; principal entry and exit remain live.
        vm.expectRevert(abi.encodeWithSelector(EarnVault.RewardRateLimitExceeded.selector, 2 ether, uint256(1e15)));
        coarseCore.contribute(1_000);
        assertEq(coarseCore.deposit(1_000, user, 1), 1);
        assertEq(coarseCore.redeem(2, user, 2_000), 2_000);
        vm.stopPrank();

        assertEq(coarseCore.totalEarnShares(), 0);
        assertEq(coarseCore.engineShares(), 0);
        assertEq(coarseCore.rewardRateBaseline(), 1e15);
    }

    function testUnsolicitedEngineSharesAreQuarantinedUntilPermissionlesslyAbsorbed() public {
        asset.mint(victim, 100 ether);

        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        assertEq(core.deposit(100 ether, user, 100 ether), 100 ether);
        vm.stopPrank();

        // Model raw venue shares transferred directly to the engine, with matching redeemable liquidity.
        engine.mintShares(address(core), 100 ether);
        asset.mint(address(engine), 100 ether);
        assertEq(core.rawEngineShares(), 200 ether);
        assertEq(core.engineShares(), 100 ether);
        assertEq(core.surplusEngineShares(), 100 ether);
        assertEq(core.previewRedeem(100 ether), 100 ether);
        assertTrue(core.isAccountingAligned());

        vm.startPrank(victim);
        asset.approve(address(core), type(uint256).max);
        assertEq(core.deposit(100 ether, victim, 100 ether), 100 ether);
        share.approve(address(core), type(uint256).max);
        assertEq(core.redeem(100 ether, victim, 100 ether), 100 ether);
        vm.stopPrank();

        // Any account may explicitly turn the quarantined shares into a reward for current holders.
        vm.prank(attacker);
        core.absorbEngineShareSurplus(100 ether);

        assertEq(asset.balanceOf(victim), 100 ether);
        assertEq(share.balanceOf(user), 100 ether);
        assertEq(core.engineShares(), 200 ether);
        assertEq(core.rawEngineShares(), 200 ether);
        assertEq(core.surplusEngineShares(), 0);
        assertEq(core.anchorEngineShares(), 200 ether);
        assertEq(core.anchorEarnShares(), 100 ether);
        assertEq(core.previewRedeem(100 ether), 200 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testEngineShareShortfallEmitsAndPreservesProportionalAccounting() public {
        asset.mint(victim, 40 ether);
        asset.mint(attacker, 8 ether);

        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        core.deposit(60 ether, user, 60 ether);
        vm.stopPrank();

        vm.startPrank(victim);
        asset.approve(address(core), type(uint256).max);
        core.deposit(40 ether, victim, 40 ether);
        vm.stopPrank();

        // Model an exceptional loss of engine-share custody without a corresponding EarnVault exit.
        engine.burnShares(address(core), 20 ether);
        assertEq(core.engineShares(), 80 ether);
        assertEq(core.previewRedeem(60 ether), 48 ether);
        assertEq(core.previewRedeem(40 ether), 32 ether);

        vm.expectEmit(true, false, false, true, address(core));
        emit EngineShareShortfallReconciled(address(engine), 100 ether, 80 ether, 20 ether, 100 ether);
        core.accrueFees();

        assertEq(core.anchorEngineShares(), 80 ether);
        assertEq(core.anchorEarnShares(), 100 ether);
        assertEq(core.convertToEngineShares(100 ether), 80 ether);
        assertTrue(core.isAccountingAligned());

        // Later principal enters at the reconciled 80:100 rate instead of recapitalizing holders.
        vm.startPrank(attacker);
        asset.approve(address(core), type(uint256).max);
        assertEq(core.deposit(8 ether, attacker, 10 ether), 10 ether);
        vm.stopPrank();

        assertEq(core.anchorEngineShares(), 88 ether);
        assertEq(core.anchorEarnShares(), 110 ether);
        assertEq(core.previewRedeem(10 ether), 8 ether);
        assertTrue(core.isAccountingAligned());

        // The exceptional reconciliation remains fail-open for holder exits.
        vm.startPrank(user);
        share.approve(address(core), type(uint256).max);
        assertEq(core.redeem(10 ether, receiver, 8 ether), 8 ether);
        vm.stopPrank();
        assertEq(asset.balanceOf(receiver), 8 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testRewardRateAllowsExact100xAndRejectsAnyExcess() public {
        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        core.deposit(1 ether, user, 1 ether);
        core.contribute(99 ether);
        vm.stopPrank();

        assertEq(core.MAX_REWARD_RATE_MULTIPLIER(), 100);
        assertEq(core.normalizedRewardRate(), 100 ether);
        assertEq(core.rewardRateBaseline(), 1 ether);

        asset.mint(attacker, 1);
        vm.startPrank(attacker);
        asset.approve(address(core), 1);
        vm.expectRevert(abi.encodeWithSelector(EarnVault.RewardRateLimitExceeded.selector, 100 ether + 1, 1 ether));
        core.contribute(1);
        vm.stopPrank();

        assertEq(asset.balanceOf(attacker), 1);
        assertEq(core.engineShares(), 100 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testSurplusCannotBypassRewardRateLimit() public {
        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        core.deposit(1 ether, user, 1 ether);
        vm.stopPrank();

        engine.mintShares(address(core), 100 ether);
        asset.mint(address(engine), 100 ether);
        core.absorbEngineShareSurplus(99 ether);

        vm.expectRevert(abi.encodeWithSelector(EarnVault.RewardRateLimitExceeded.selector, 100 ether + 1, 1 ether));
        core.absorbEngineShareSurplus(1);

        assertEq(core.engineShares(), 100 ether);
        assertEq(core.surplusEngineShares(), 1 ether);
        assertEq(core.previewRedeem(1 ether), 100 ether);
    }

    function testDepositRejectsRecapitalizingUnbackedExistingSupply() public {
        asset.mint(attacker, 100 ether);
        asset.mint(victim, 100 ether);

        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        core.deposit(100 ether, user, 100 ether);
        vm.stopPrank();

        // Model complete venue-share loss while the original EarnShare remains outstanding.
        engine.burnShares(address(core), 100 ether);
        assertEq(core.engineShares(), 0);
        assertEq(core.totalEarnShares(), 100 ether);
        assertEq(core.previewRedeem(100 ether), 0);
        vm.expectRevert(EarnVault.ActiveSupplyWithoutBacking.selector);
        core.previewWithdraw(1 ether);

        vm.startPrank(victim);
        asset.approve(address(core), type(uint256).max);
        vm.expectRevert(EarnVault.ActiveSupplyWithoutBacking.selector);
        core.deposit(100 ether, victim, 1);
        vm.stopPrank();

        assertEq(asset.balanceOf(victim), 100 ether);
        assertEq(share.balanceOf(victim), 0);
        assertEq(core.engineShares(), 0);

        // A contribution is the explicit recapitalization path: it restores backing entirely for
        // the pre-existing supply and gives the funder no EarnShare.
        vm.startPrank(attacker);
        asset.approve(address(core), type(uint256).max);
        core.contribute(100 ether);
        vm.stopPrank();

        assertEq(share.balanceOf(attacker), 0);
        assertEq(core.previewRedeem(100 ether), 100 ether);
        assertTrue(core.isAccountingAligned());

        vm.startPrank(victim);
        assertEq(core.deposit(100 ether, victim, 100 ether), 100 ether);
        vm.stopPrank();
        assertEq(core.previewRedeem(share.balanceOf(victim)), 100 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testBoundedRedeemRevertsBelowMinimumAndRollsBack() public {
        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        core.deposit(10 ether, user, 10 ether);
        share.approve(address(core), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(EarnVault.MinimumAssetsNotMet.selector, 5 ether, 4 ether));
        core.redeem(4 ether, receiver, 5 ether);

        assertEq(asset.balanceOf(receiver), 0);
        assertEq(share.balanceOf(user), 10 ether);
        assertEq(core.totalEarnShares(), 10 ether);
        assertEq(core.engineShares(), 10 ether);
        _inv();
        vm.stopPrank();
    }

    function testInitialEarnShareSupplyNotZero() public {
        CoreMockToken s = new CoreMockToken("S", "S", 18);
        s.mint(address(1), 1);
        EarnVault vault = EarnVault(address(new ERC1967Proxy(address(new EarnVault()), bytes(""))));
        EarnFees fees = EarnFees(Clones.clone(address(new EarnFees())));
        fees.initialize(address(vault), address(s), earnVaultTestNoFees());
        vm.expectRevert(EarnVault.InitialEarnShareSupplyNotZero.selector);
        vault.initialize(
            address(engine),
            address(s),
            address(fees),
            operator,
            EarnVaultTestDeployer.defaultControls(operator),
            DistributorConfig(address(0), 0)
        );
    }

    function testExceedsMaxEarnSharesPreviewAndActual() public {
        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        core.deposit(10 ether, user, 10 ether);
        share.approve(address(core), type(uint256).max);
        vm.expectRevert(EarnVault.ExceedsMaxEarnShares.selector);
        core.withdrawExact(5 ether, receiver, 4 ether);
        engine.setWithdrawBurnOverride(6 ether);
        vm.expectRevert(EarnVault.ExceedsMaxEarnShares.selector);
        core.withdrawExact(5 ether, receiver, 5 ether);
        vm.stopPrank();
    }

    function testDepositRevertsWhenAssetTransferFromReturnsFalse() public {
        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        asset.setForceTransferFromFalse(true);
        vm.expectRevert(EarnVault.TokenCallFalse.selector);
        core.deposit(1 ether, user, 1 ether);
        vm.stopPrank();
    }

    function testDepositReentrantEngineReverts() public {
        CoreMockToken reentrantAsset = new CoreMockToken("Reentrant Asset", "RA", 18);
        CoreMockToken reentrantShare = new CoreMockToken("Reentrant Share", "RS", 18);
        CoreReentrantDepositEngine reentrantEngine = new CoreReentrantDepositEngine(reentrantAsset);
        EarnVault reentrantCore = EarnVaultTestDeployer.deploy(
            address(reentrantEngine), address(reentrantShare), operator, earnVaultTestNoFees()
        );
        reentrantEngine.setCore(reentrantCore);
        reentrantAsset.mint(user, 10 ether);

        vm.startPrank(user);
        reentrantAsset.approve(address(reentrantCore), type(uint256).max);
        vm.expectRevert(EarnVault.ReentrantCall.selector);
        reentrantCore.deposit(1 ether, user, 1 ether);
        vm.stopPrank();
    }

    function testWithdrawExactBurnsOnlyConsumedEarnSharesAndLeavesUnusedEarnShare() public {
        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        core.deposit(10 ether, user, 10 ether);
        share.approve(address(core), type(uint256).max);
        engine.setWithdrawBurnOverride(2 ether);

        uint256 burned = core.withdrawExact(5 ether, receiver, 5 ether);

        assertEq(burned, 2 ether);
        assertEq(asset.balanceOf(receiver), 5 ether);
        assertEq(share.balanceOf(user), 8 ether);
        _inv();
        vm.stopPrank();
    }

    function _inv() internal view {
        assertEq(core.totalEarnShares(), core.engineShares());
    }

    function _deploySixDecimalVault()
        internal
        returns (CoreMockToken asset6, CoreMockToken share6, CoreMockEngine engine6, EarnVault core6)
    {
        asset6 = new CoreMockToken("Six Decimal Asset", "AST6", 6);
        share6 = new CoreMockToken("Six Decimal Share", "SH6", 6);
        engine6 = new CoreMockEngine(asset6, 6);
        core6 = EarnVaultTestDeployer.deploy(address(engine6), address(share6), operator, earnVaultTestNoFees());
    }
}
