// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { EarnVaultControls, EngineMigrationMode } from "../../src/interfaces/core/EarnVaultTypes.sol";
import { CoreMockAsyncEngine, CoreMockEngine, CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract EarnVaultControlsTest is Test {
    event DepositPauseChanged(address indexed caller, bool paused);
    event EmergencyRolesChanged(address indexed emergencyGuardian, address indexed asyncJanitor);
    event OperatorTransferStarted(address indexed operator, address indexed pendingOperator);
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);

    CoreMockToken asset;
    CoreMockToken share;
    CoreMockEngine engine;
    EarnVault core;

    address user = address(0xA11CE);
    address receiver = address(0xB0B);
    address operator = address(0x0FF1CE);
    address guardian = address(0x600D);
    address janitor = address(0xCA11CE1);
    address stranger = address(0xDEAD);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        share = new CoreMockToken("Share", "SH", 18);
        engine = new CoreMockEngine(asset, 18);
        core = EarnVaultTestDeployer.deploy(
            address(engine),
            address(share),
            operator,
            _controls(guardian, janitor, EngineMigrationMode.OperatorEnabled),
            earnVaultTestNoFees()
        );
        asset.mint(user, 100 ether);
        vm.startPrank(user);
        asset.approve(address(core), type(uint256).max);
        share.approve(address(core), type(uint256).max);
        vm.stopPrank();
    }

    function testGuardianPausesNewExposureWhileRedeemRemainsAvailable() public {
        vm.prank(user);
        core.deposit(10 ether, user, 10 ether);

        vm.expectEmit(true, false, false, true, address(core));
        emit DepositPauseChanged(guardian, true);
        vm.prank(guardian);
        core.setDepositsPaused(true);
        assertTrue(core.depositsPaused());

        vm.startPrank(user);
        vm.expectRevert(EarnVault.DepositsPaused.selector);
        core.deposit(1 ether, user, 1);
        vm.expectRevert(EarnVault.DepositsPaused.selector);
        core.depositVenueShares(1 ether, user, 1);
        vm.expectRevert(EarnVault.DepositsPaused.selector);
        core.contribute(1 ether);
        assertEq(core.redeem(1 ether, receiver, 1 ether), 1 ether);
        vm.stopPrank();

        assertEq(asset.balanceOf(receiver), 1 ether);

        vm.prank(guardian);
        vm.expectRevert(EarnVault.NotOperator.selector);
        core.setDepositsPaused(false);

        vm.expectEmit(true, false, false, true, address(core));
        emit DepositPauseChanged(operator, false);
        vm.prank(operator);
        core.setDepositsPaused(false);
        assertFalse(core.depositsPaused());
    }

    function testExactWithdrawalRemainsAvailableWhileDepositsPaused() public {
        vm.prank(user);
        core.deposit(10 ether, user, 10 ether);
        vm.prank(guardian);
        core.setDepositsPaused(true);

        vm.prank(user);
        assertEq(core.withdrawExact(3 ether, receiver, 3 ether), 3 ether);

        assertTrue(core.depositsPaused());
        assertEq(asset.balanceOf(receiver), 3 ether);
        assertEq(share.balanceOf(user), 7 ether);
        assertEq(core.engineShares(), 7 ether);
        assertTrue(core.isAccountingAligned());
    }

    function testOperatorTransfersThroughTwoStepHandoff() public {
        address nextOperator = address(0x0FF1CE2);

        vm.expectEmit(true, true, false, true, address(core));
        emit OperatorTransferStarted(operator, nextOperator);
        vm.prank(operator);
        core.transferOperator(nextOperator);
        assertEq(core.operator(), operator);
        assertEq(core.pendingOperator(), nextOperator);

        vm.prank(stranger);
        vm.expectRevert(EarnVault.NotPendingOperator.selector);
        core.acceptOperator();

        vm.expectEmit(true, true, false, true, address(core));
        emit OperatorTransferred(operator, nextOperator);
        vm.prank(nextOperator);
        core.acceptOperator();
        assertEq(core.operator(), nextOperator);
        assertEq(core.pendingOperator(), address(0));

        vm.prank(operator);
        vm.expectRevert(EarnVault.NotOperator.selector);
        core.setMaxManagedAssets(1);

        vm.prank(nextOperator);
        core.setMaxManagedAssets(1);
        assertEq(core.maxManagedAssets(), 1);
    }

    function testOnlyGuardianOrOperatorCanPauseAndOnlyOperatorCanRotateRoles() public {
        vm.prank(stranger);
        vm.expectRevert(EarnVault.NotEmergencyGuardianOrOperator.selector);
        core.setDepositsPaused(true);

        vm.prank(stranger);
        vm.expectRevert(EarnVault.NotOperator.selector);
        core.setEmergencyRoles(stranger, janitor);

        address nextGuardian = address(0x600D2);
        address nextJanitor = address(0xCA11CE2);
        vm.expectEmit(true, true, false, true, address(core));
        emit EmergencyRolesChanged(nextGuardian, nextJanitor);
        vm.prank(operator);
        core.setEmergencyRoles(nextGuardian, nextJanitor);
        assertEq(core.emergencyGuardian(), nextGuardian);
        assertEq(core.asyncJanitor(), nextJanitor);

        vm.prank(guardian);
        vm.expectRevert(EarnVault.NotEmergencyGuardianOrOperator.selector);
        core.setDepositsPaused(true);

        vm.prank(nextGuardian);
        core.setDepositsPaused(true);
        assertTrue(core.depositsPaused());
    }

    function testDepositPauseLeavesAsyncRequestsAvailableAndJanitorIsSeparateFromGovernance() public {
        CoreMockToken asyncShare = new CoreMockToken("Async Share", "ASH", 18);
        CoreMockAsyncEngine asyncEngine = new CoreMockAsyncEngine(asset);
        EarnVault asyncCore = EarnVaultTestDeployer.deploy(
            address(asyncEngine),
            address(asyncShare),
            operator,
            _controls(guardian, janitor, EngineMigrationMode.OperatorEnabled),
            earnVaultTestNoFees()
        );
        asyncEngine.setCore(asyncCore);

        vm.startPrank(user);
        asset.approve(address(asyncCore), type(uint256).max);
        asyncShare.approve(address(asyncCore), type(uint256).max);
        asyncCore.deposit(10 ether, user, 10 ether);
        vm.stopPrank();

        vm.prank(guardian);
        asyncCore.setDepositsPaused(true);

        vm.startPrank(user);
        bytes32 finalizeId = asyncCore.requestRedeem(2 ether, "", receiver);
        bytes32 cancelId = asyncCore.requestRedeem(2 ether, "", receiver);
        vm.stopPrank();

        asyncEngine.solve(finalizeId, 2 ether);
        assertEq(asset.balanceOf(receiver), 2 ether);

        vm.prank(operator);
        vm.expectRevert(EarnVault.NotRequesterOrJanitor.selector);
        asyncCore.cancelRedeem(cancelId, 2 ether);

        vm.prank(janitor);
        asyncCore.cancelRedeem(cancelId, 2 ether);
        assertEq(asyncCore.openRedeemRequestCount(), 0);
        assertEq(asyncShare.balanceOf(receiver), 2 ether);

        vm.prank(guardian);
        vm.expectRevert(EarnVault.NotOperator.selector);
        asyncCore.setDepositsPaused(false);

        vm.prank(operator);
        asyncCore.setDepositsPaused(false);
        assertFalse(asyncCore.depositsPaused());
    }

    function testUserOnlyModePermanentlyRejectsOperatorMigration() public {
        CoreMockToken userOnlyShare = new CoreMockToken("User-only Share", "USH", 18);
        CoreMockEngine userOnlyEngine = new CoreMockEngine(asset, 18);
        EarnVault userOnlyCore = EarnVaultTestDeployer.deploy(
            address(userOnlyEngine),
            address(userOnlyShare),
            operator,
            _controls(guardian, janitor, EngineMigrationMode.UserOnly),
            earnVaultTestNoFees()
        );
        CoreMockEngine replacement = new CoreMockEngine(asset, 18);

        assertEq(uint8(userOnlyCore.engineMigrationMode()), uint8(EngineMigrationMode.UserOnly));
        vm.prank(operator);
        vm.expectRevert(EarnVault.OperatorMigrationDisabled.selector);
        userOnlyCore.migrateEngine(address(replacement), 1, 1);
        assertEq(userOnlyCore.engine(), address(userOnlyEngine));
    }

    function _controls(address emergencyGuardian, address asyncJanitor, EngineMigrationMode migrationMode)
        internal
        pure
        returns (EarnVaultControls memory)
    {
        return EarnVaultControls({
            emergencyGuardian: emergencyGuardian,
            asyncJanitor: asyncJanitor,
            maxManagedAssets: 0,
            migrationMode: migrationMode
        });
    }
}
