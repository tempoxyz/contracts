// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";
import { EarnVault } from "../../src/core/EarnVault.sol";
import { EarnVaultControls, EngineMigrationMode } from "../../src/interfaces/core/EarnVaultTypes.sol";
import { CoreMockEngine, CoreMockToken, earnVaultTestNoFees } from "../helpers/EarnVaultMocks.sol";
import { EarnVaultTestDeployer } from "../helpers/EarnVaultTestDeployer.sol";

contract EarnVaultDepositorsTest is Test {
    event DepositorChanged(address indexed depositor, bool allowed);

    CoreMockToken asset;
    CoreMockToken share;
    CoreMockEngine engine;
    EarnVault restricted;
    EarnVault open;

    address router = address(0x7007E5);
    address holder = address(0xA11CE);
    address receiver = address(0xB0B);
    address operator = address(0x0FF1CE);
    address stranger = address(0xDEAD);

    function setUp() public {
        asset = new CoreMockToken("Asset", "AST", 18);
        share = new CoreMockToken("Share", "SH", 18);
        engine = new CoreMockEngine(asset, 18);
        restricted = EarnVaultTestDeployer.deploy(
            address(engine), address(share), operator, _controls(true), earnVaultTestNoFees()
        );

        CoreMockToken openShare = new CoreMockToken("Open Share", "OSH", 18);
        CoreMockEngine openEngine = new CoreMockEngine(asset, 18);
        open = EarnVaultTestDeployer.deploy(
            address(openEngine), address(openShare), operator, _controls(false), earnVaultTestNoFees()
        );

        address[3] memory callers = [router, holder, stranger];
        for (uint256 i; i < callers.length; ++i) {
            asset.mint(callers[i], 100 ether);
            vm.startPrank(callers[i]);
            asset.approve(address(restricted), type(uint256).max);
            asset.approve(address(open), type(uint256).max);
            share.approve(address(restricted), type(uint256).max);
            vm.stopPrank();
        }
    }

    function testRestrictionIsFixedAtInitialization() public view {
        assertTrue(restricted.restrictDeposits());
        assertFalse(open.restrictDeposits());
    }

    function testOpenVaultAcceptsAnyDepositorAndRejectsTheList() public {
        vm.prank(stranger);
        assertEq(open.deposit(1 ether, stranger, 1), 1 ether);

        vm.prank(operator);
        vm.expectRevert(EarnVault.DepositsUnrestricted.selector);
        open.setDepositor(router, true);
        assertFalse(open.isDepositor(router));
    }

    function testRestrictedVaultRejectsUnapprovedEntry() public {
        vm.startPrank(stranger);
        vm.expectRevert(EarnVault.NotDepositor.selector);
        restricted.deposit(1 ether, stranger, 1);
        vm.expectRevert(EarnVault.NotDepositor.selector);
        restricted.deposit(1 ether, 1);
        vm.expectRevert(EarnVault.NotDepositor.selector);
        restricted.depositVenueShares(1 ether, stranger, 1);
        vm.expectRevert(EarnVault.NotDepositor.selector);
        restricted.depositVenueShares(1 ether, 1);
        vm.stopPrank();

        assertEq(share.totalSupply(), 0);
        assertEq(asset.balanceOf(stranger), 100 ether);
    }

    function testApprovedDepositorMintsToReceiver() public {
        vm.expectEmit(true, false, false, true, address(restricted));
        emit DepositorChanged(router, true);
        vm.prank(operator);
        restricted.setDepositor(router, true);
        assertTrue(restricted.isDepositor(router));

        vm.prank(router);
        assertEq(restricted.deposit(10 ether, holder, 10 ether), 10 ether);
        assertEq(share.balanceOf(holder), 10 ether);
        assertEq(asset.balanceOf(router), 90 ether);

        // The receiver is not a depositor, so it cannot enter on its own.
        vm.prank(holder);
        vm.expectRevert(EarnVault.NotDepositor.selector);
        restricted.deposit(1 ether, holder, 1);
    }

    function testOnlyOperatorManagesDepositors() public {
        vm.prank(stranger);
        vm.expectRevert(EarnVault.NotOperator.selector);
        restricted.setDepositor(stranger, true);

        vm.prank(router);
        vm.expectRevert(EarnVault.NotOperator.selector);
        restricted.setDepositor(router, true);

        vm.prank(operator);
        vm.expectRevert(EarnVault.ZeroAddress.selector);
        restricted.setDepositor(address(0), true);
    }

    function testUnchangedDepositorEmitsNothing() public {
        vm.recordLogs();
        vm.prank(operator);
        restricted.setDepositor(router, false);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testRemovedDepositorLosesEntryWhileHoldersKeepEveryExit() public {
        vm.prank(operator);
        restricted.setDepositor(router, true);
        vm.prank(router);
        restricted.deposit(10 ether, holder, 10 ether);

        vm.expectEmit(true, false, false, true, address(restricted));
        emit DepositorChanged(router, false);
        vm.prank(operator);
        restricted.setDepositor(router, false);

        vm.prank(router);
        vm.expectRevert(EarnVault.NotDepositor.selector);
        restricted.deposit(1 ether, holder, 1);

        // Exits never depend on the depositor list.
        vm.startPrank(holder);
        assertEq(restricted.redeem(4 ether, receiver, 4 ether), 4 ether);
        assertEq(restricted.withdrawExact(3 ether, receiver, 3 ether), 3 ether);
        vm.stopPrank();
        assertEq(asset.balanceOf(receiver), 7 ether);
        assertEq(share.balanceOf(holder), 3 ether);
    }

    function testContributionsStayPermissionless() public {
        vm.prank(operator);
        restricted.setDepositor(router, true);
        vm.prank(router);
        restricted.deposit(10 ether, holder, 10 ether);

        vm.prank(stranger);
        restricted.contribute(1 ether);
        assertEq(restricted.totalAssets(), 11 ether);
        assertEq(share.totalSupply(), 10 ether);
    }

    function _controls(bool restrictDeposits) private pure returns (EarnVaultControls memory) {
        return EarnVaultControls({
            emergencyGuardian: address(0),
            asyncJanitor: address(0),
            maxManagedAssets: 0,
            migrationMode: EngineMigrationMode.UserOnly,
            restrictDeposits: restrictDeposits
        });
    }
}
