// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AccountKeys } from "../../../src/spend/programs/AccountKeys.sol";
import { AccountLifecycle } from "../../../src/spend/programs/AccountLifecycle.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice A guardian recovery waits RECOVERY_DELAY before its key signs, and the account or any of its keys cancels it
///         meanwhile, so a guardian quorum cannot take over the account and its lifecycle payouts at once.
contract RecoveryDelayTest is AuthEnv {
    AccountKeys internal keys;
    AccountLifecycle internal life;
    address internal registrar = makeAddr("registrar");
    address internal phone = makeAddr("phone");
    address internal newKey = makeAddr("newKey");
    address internal guardian;
    uint256 internal guardianKey;
    address[] internal noVaults;

    function setUp() public {
        _deployPrograms();
        keys = new AccountKeys();
        life = new AccountLifecycle(address(usd), registrar, address(keys), 180 days, 3 * 365 days);
        (guardian, guardianKey) = makeAddrAndKey("guardian");
        vm.startPrank(alice);
        life.enroll();
        usd.approve(address(life), type(uint256).max);
        keys.configure(alice, _one(phone), _one(guardian), 0);
        vm.stopPrank();
        usd.mint(alice, 1000e6);
    }

    function test_recover_newKeyWaitsTheDelay_soItCannotCloseTheAccountAtOnce() public {
        _recover(newKey);
        (address key, uint64 readyAt) = keys.recoveryOf(alice);
        assertEq(key, newKey);
        assertEq(readyAt, vm.getBlockTimestamp() + keys.RECOVERY_DELAY());
        // The current key still signs; the recovered one does not yet.
        assertTrue(keys.signsFor(alice, phone));
        assertFalse(keys.signsFor(alice, newKey));
        vm.prank(newKey);
        vm.expectRevert(AccountLifecycle.NotOwner.selector);
        life.closeAccount(alice, newKey, noVaults);

        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(AccountKeys.RecoveryNotReady.selector, readyAt));
        keys.completeRecovery(alice);
        vm.prank(newKey);
        vm.expectRevert(AccountLifecycle.NotOwner.selector);
        life.closeAccount(alice, newKey, noVaults);
        assertEq(usd.balanceOf(alice), 1000e6);
    }

    function test_recover_completesAfterTheDelay_byAnyone() public {
        _recover(newKey);
        vm.warp(vm.getBlockTimestamp() + keys.RECOVERY_DELAY());
        vm.prank(bob);
        keys.completeRecovery(alice);
        assertTrue(keys.signsFor(alice, newKey));
        assertFalse(keys.signsFor(alice, phone));
        (address key, uint64 readyAt) = keys.recoveryOf(alice);
        assertEq(key, address(0));
        assertEq(readyAt, 0);
        vm.expectRevert(AccountKeys.NoRecovery.selector);
        keys.completeRecovery(alice);
        // A lost device's owner gets its account back.
        vm.prank(newKey);
        assertEq(life.closeAccount(alice, newKey, noVaults), 1000e6);
    }

    function test_cancelRecovery_byACurrentKey_andTheSameApprovalsCannotRestartIt() public {
        bytes[] memory sigs = _recover(newKey);
        vm.prank(phone);
        keys.cancelRecovery(alice);
        (address key,) = keys.recoveryOf(alice);
        assertEq(key, address(0));
        vm.warp(vm.getBlockTimestamp() + keys.RECOVERY_DELAY());
        vm.expectRevert(AccountKeys.NoRecovery.selector);
        keys.completeRecovery(alice);
        assertFalse(keys.signsFor(alice, newKey));
        // The approvals were used up when the recovery started.
        vm.expectRevert(abi.encodeWithSelector(AccountKeys.NotEnoughGuardians.selector, 0, 1));
        keys.recover(alice, newKey, sigs);
    }

    function test_cancelRecovery_byTheAccountItself_evenWhenNotAListedKey() public {
        _recover(newKey);
        assertFalse(keys.signsFor(alice, alice));
        vm.prank(alice);
        keys.cancelRecovery(alice);
        (address key,) = keys.recoveryOf(alice);
        assertEq(key, address(0));
    }

    function test_cancelRecovery_refusesGuardiansStrangersAndTheRecoveryKey() public {
        _recover(newKey);
        address[3] memory callers = [guardian, bob, newKey];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(AccountKeys.NotSigner.selector);
            keys.cancelRecovery(alice);
        }
        vm.prank(phone);
        keys.cancelRecovery(alice);
        vm.prank(phone);
        vm.expectRevert(AccountKeys.NoRecovery.selector);
        keys.cancelRecovery(alice);
    }

    function test_configure_cancelsAPendingRecovery() public {
        _recover(newKey);
        vm.prank(phone);
        keys.configure(alice, _one(phone), _one(guardian), 0);
        vm.warp(vm.getBlockTimestamp() + keys.RECOVERY_DELAY());
        vm.expectRevert(AccountKeys.NoRecovery.selector);
        keys.completeRecovery(alice);
        assertFalse(keys.signsFor(alice, newKey));
    }

    function test_recover_newApprovalsReplaceThePendingRecovery_andRestartTheDelay() public {
        _recover(newKey);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 days);
        address other = makeAddr("other");
        _recover(other);
        (address key, uint64 readyAt) = keys.recoveryOf(alice);
        assertEq(key, other);
        assertEq(readyAt, start + 1 days + keys.RECOVERY_DELAY());
        vm.warp(start + keys.RECOVERY_DELAY());
        vm.expectRevert(abi.encodeWithSelector(AccountKeys.RecoveryNotReady.selector, readyAt));
        keys.completeRecovery(alice);
    }

    /// @dev Has the guardian approve replacing alice's keys with `key` and submits it; returns the approvals.
    function _recover(address key) internal returns (bytes[] memory sigs) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(guardianKey, keys.recoveryDigest(alice, key));
        sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);
        keys.recover(alice, key, sigs);
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }
}
