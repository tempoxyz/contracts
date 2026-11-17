// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { CoreMockEngine, CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

/// @notice EarnShare the vault holds counts as burned, so a standing residue never blocks a full exit or re-entry.
contract EarnVaultShareResidueTest is Test {
    CoreMockToken asset;
    CoreMockToken share;
    CoreMockEngine engine;
    EarnVault core;
    address user = address(0xA11CE);
    address other = address(0xB0B);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        share = new CoreMockToken("Share", "SH", 18);
        engine = new CoreMockEngine(asset, 18);
        core = EarnVaultTestDeployer.deploy(address(engine), address(share), address(0x0FF1CE), earnVaultTestNoFees());
        asset.mint(user, 100 ether);
        asset.mint(other, 100 ether);
        vm.prank(user);
        asset.approve(address(core), type(uint256).max);
        vm.prank(other);
        asset.approve(address(core), type(uint256).max);
        vm.prank(user);
        share.approve(address(core), type(uint256).max);
        vm.prank(other);
        share.approve(address(core), type(uint256).max);
    }

    function testResidueAllowsFullExitAndEmptyPoolReentry() public {
        vm.prank(user);
        core.deposit(100 ether, user, 1);
        vm.prank(user);
        share.transfer(address(core), 1);
        assertEq(core.totalEarnShares(), 100 ether - 1);
        // Aligned at once, before any call restates the anchor.
        assertTrue(core.isAccountingAligned());

        uint256 held = share.balanceOf(user);
        vm.prank(user);
        uint256 assets = core.redeem(held, user, 1);
        emit log_named_uint("redeemed assets", assets);
        emit log_named_uint("engine shares left", core.engineShares());
        assertEq(core.totalEarnShares(), 0);
        assertEq(share.balanceOf(address(core)), 1);
        assertTrue(core.isAccountingAligned());

        // The pool is empty again: the next entry is priced at the empty-pool rate and is not blocked.
        vm.prank(other);
        uint256 minted = core.deposit(10 ether, other, 1);
        emit log_named_uint("minted", minted);
        assertGt(minted, 0);
        assertEq(core.totalEarnShares(), minted);
        assertEq(share.balanceOf(address(core)), 1);
        assertTrue(core.isAccountingAligned());
    }

    function testTransfersBeyondTheResidueStillCountAsSupply() public {
        vm.prank(user);
        uint256 minted = core.deposit(1 ether, user, 1);
        vm.prank(user);
        share.transfer(address(core), minted - 1);
        assertEq(core.totalEarnShares(), minted - 1);

        // The next deposit is priced at the original rate, not one inflated by the transfer.
        vm.prank(other);
        uint256 minted2 = core.deposit(1 ether, other, 1);
        assertApproxEqAbs(minted2, minted, 1);
        assertTrue(core.isAccountingAligned());
    }

    function testDonatingTheLastShareLeavesAnEnterablePool() public {
        vm.prank(user);
        uint256 minted = core.deposit(1 ether, user, 1);
        vm.prank(user);
        share.transfer(address(other), minted - 1);
        vm.prank(user);
        share.transfer(address(core), 1);
        vm.prank(other);
        share.transfer(address(core), minted - 1);
        // Only one unit counts as burned; the rest remains supply nobody can redeem, as on any transfer to the vault.
        assertEq(core.totalEarnShares(), minted - 1);
        vm.prank(user);
        assertGt(core.deposit(1 ether, user, 1), 0);
        assertTrue(core.isAccountingAligned());
    }

    function testResidueSurvivesRedeemsAndDeposits() public {
        vm.prank(user);
        core.deposit(100 ether, user, 1);
        vm.prank(user);
        share.transfer(address(core), 1);
        vm.prank(other);
        core.deposit(50 ether, other, 1);
        vm.prank(user);
        core.redeem(10 ether, user, 1);
        vm.prank(other);
        core.redeem(5 ether, other, 1);
        assertEq(share.balanceOf(address(core)), 1);
        assertEq(core.totalEarnShares(), share.totalSupply() - 1);
        assertTrue(core.isAccountingAligned());
    }

    function testTransferringTheOnlyShareToTheVaultEmptiesBacking() public {
        vm.prank(user);
        uint256 minted = core.deposit(1 ether, user, 1);
        vm.prank(user);
        core.redeem(minted - 1, user, 1);
        assertEq(core.totalEarnShares(), 1);
        vm.prank(user);
        share.transfer(address(core), 1);
        assertEq(core.totalEarnShares(), 0);
        // Aligned before any call restates the anchor.
        assertTrue(core.isAccountingAligned());

        // The next call restates the anchor and leaves the empty pool with no managed backing.
        vm.prank(other);
        uint256 minted2 = core.deposit(1 ether, other, 1);
        assertGt(minted2, 0);
        assertEq(core.totalEarnShares(), minted2);
        assertTrue(core.isAccountingAligned());
        vm.prank(other);
        core.redeem(minted2, other, 1);
        assertEq(core.totalEarnShares(), 0);
        assertEq(core.engineShares(), 0);
        assertTrue(core.isAccountingAligned());
    }
}
