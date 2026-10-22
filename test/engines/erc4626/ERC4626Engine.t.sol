// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../../src/core/EarnVault.sol";
import { ERC4626Engine, IERC4626Vault } from "../../../src/engines/ERC4626Engine.sol";
import { AdversarialERC4626Vault } from "../../helpers/AdversarialERC4626Vault.sol";
import { CoreMockToken, earnVaultTestNoFees } from "../../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../../helpers/EarnVaultTestDeployer.sol";

/// @dev Drives a production EarnVault over an ERC-4626 venue whose return values can disagree with its
///      custody effects, so every exit is checked against measured balance deltas.
contract ERC4626EngineTest is Test {
    CoreMockToken private asset;
    CoreMockToken private earnShare;
    AdversarialERC4626Vault private venue;
    ERC4626Engine private engine;
    EarnVault private vault;

    address private constant OPERATOR = address(0x0A11CE);
    address private constant USER_A = address(0xA11CE);
    address private constant USER_B = address(0xB0B);
    address private constant RECEIVER = address(0xCAFE);
    address private constant STRANGER = address(0xDEAD);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        earnShare = new CoreMockToken("Earn Share", "ESH", 18);
        venue = new AdversarialERC4626Vault(address(asset));
        engine = new ERC4626Engine(IERC4626Vault(address(venue)), address(this), "", "");
        vault = EarnVaultTestDeployer.deploy(address(engine), address(earnShare), OPERATOR, earnVaultTestNoFees());
        engine.initializeEarnVault(address(vault));

        _deposit(USER_A, 50 ether);
        _deposit(USER_B, 50 ether);
    }

    function testRedeemPaysMeasuredAssetsInsteadOfVenueReport() public {
        venue.setRedeemBehavior(10 ether, 40 ether, 40 ether);

        vm.prank(USER_A);
        assertEq(vault.redeem(40 ether, RECEIVER, 40 ether), 40 ether);

        assertEq(asset.balanceOf(RECEIVER), 40 ether);
        assertEq(venue.balanceOf(address(engine)), 60 ether);
        assertTrue(vault.isAccountingAligned());
    }

    function testRedeemRollsBackWhenVenueOverreportsReceiverDelivery() public {
        venue.setRedeemBehavior(40 ether, 20 ether, 40 ether);

        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Engine.InsufficientAssetsReceived.selector, 40 ether, 20 ether));
        vault.redeem(40 ether, RECEIVER, 40 ether);

        _assertUntouched();
    }

    function testRedeemRejectsUnexpectedVenueShareBurn() public {
        venue.setRedeemBehavior(40 ether, 40 ether, 50 ether);

        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Engine.UnexpectedVenueSharesBurned.selector, 40 ether, 50 ether));
        vault.redeem(40 ether, RECEIVER, 40 ether);

        _assertUntouched();
    }

    function testWithdrawRejectsUnexpectedReceiverDelivery() public {
        venue.setWithdrawBehavior(30 ether, 30 ether, 20 ether);

        vm.prank(USER_A);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Engine.UnexpectedAssetsReceived.selector, 30 ether, 20 ether));
        vault.withdrawExact(30 ether, RECEIVER, 30 ether);

        _assertUntouched();
    }

    function testWithdrawChargesMeasuredVenueShareConsumption() public {
        venue.setWithdrawBehavior(10 ether, 30 ether, 30 ether);

        vm.prank(USER_A);
        uint256 earnSharesBurned = vault.withdrawExact(30 ether, RECEIVER, 30 ether);

        assertEq(earnSharesBurned, 30 ether);
        assertEq(asset.balanceOf(RECEIVER), 30 ether);
        assertEq(earnShare.balanceOf(USER_A), 20 ether);
        assertEq(earnShare.balanceOf(USER_B), 50 ether);
        assertEq(earnShare.totalSupply(), 70 ether);
        assertEq(venue.balanceOf(address(engine)), 70 ether);
        assertEq(vault.previewRedeem(earnShare.balanceOf(USER_B)), 50 ether);
        assertTrue(vault.isAccountingAligned());
    }

    function testMutatingCallsAreOnlyEarnVault() public {
        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Engine.NotEarnVault.selector, STRANGER));
        engine.deposit(1 ether);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Engine.NotEarnVault.selector, STRANGER));
        engine.depositInKind(1 ether, STRANGER);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Engine.NotEarnVault.selector, STRANGER));
        engine.redeem(1 ether, STRANGER, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Engine.NotEarnVault.selector, STRANGER));
        engine.withdraw(1 ether, STRANGER);
        vm.stopPrank();
    }

    function _assertUntouched() private view {
        assertEq(asset.balanceOf(RECEIVER), 0);
        assertEq(earnShare.balanceOf(USER_A), 50 ether);
        assertEq(earnShare.totalSupply(), 100 ether);
        assertEq(venue.balanceOf(address(engine)), 100 ether);
        assertEq(asset.balanceOf(address(venue)), 100 ether);
        assertTrue(vault.isAccountingAligned());
    }

    function _deposit(address user, uint256 assets) private {
        asset.mint(user, assets);
        vm.startPrank(user);
        asset.approve(address(vault), assets);
        earnShare.approve(address(vault), type(uint256).max);
        vault.deposit(assets, user, assets);
        vm.stopPrank();
    }
}
