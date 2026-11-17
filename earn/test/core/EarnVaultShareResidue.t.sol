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
}
