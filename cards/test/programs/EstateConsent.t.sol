// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AccountLifecycle } from "../../src/programs/AccountLifecycle.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice An estate pays only the executor the owner named, whatever the account's status; dormancy alone leaves the
///         money for escheat and its longer rules. The owner's check-in counts as activity for a wallet used without its
///         card. A settled estate's executor alone pays out what reaches the account later.
contract EstateConsentTest is AuthEnv {
    AccountLifecycle internal life;
    address internal registrar = makeAddr("registrar");
    address internal executor = makeAddr("executor");
    address internal other = makeAddr("other");
    address internal state = makeAddr("state");
    address[] internal noVaults;
    uint64 internal constant DORMANCY = 180 days;
    uint64 internal constant ESCHEAT = 3 * 365 days;

    function setUp() public {
        _deployPrograms();
        life = new AccountLifecycle(address(usd), registrar, address(0), DORMANCY, ESCHEAT);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(0), address(life), address(0))));
        vm.prank(registrar);
        life.setProgram(address(cards), true);
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        vm.startPrank(alice);
        life.enroll();
        usd.approve(address(life), type(uint256).max);
        vm.stopPrank();
        usd.mint(alice, 1000e6);
    }

    function test_setEstate_dormantAccount_refusesAnExecutorTheOwnerNeverNamed() public {
        // The owner keeps using its wallet without its card, so card dormancy alone marks it dormant.
        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        vm.prank(alice);
        usd.transfer(bob, 1e6);
        life.markDormant(alice);
        vm.prank(registrar);
        life.noticeEscheat(alice, state);
        vm.warp(vm.getBlockTimestamp() + life.ESCHEAT_NOTICE());
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NotUnclaimed.selector);
        life.escheat(alice, noVaults);

        // The registrar cannot route the dormant account to an executor of its own choosing.
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NotNamedExecutor.selector);
        life.setEstate(alice, other);
        vm.warp(vm.getBlockTimestamp() + life.ESTATE_NOTICE());
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Dormant));
        life.settleEstate(alice, noVaults);
        assertEq(usd.balanceOf(other), 0);
        assertEq(usd.balanceOf(alice), 999e6);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Dormant));
    }

    function test_setEstate_dormantAccount_paysTheExecutorTheOwnerNamed_afterTheNotice() public {
        vm.prank(alice);
        life.nameExecutor(alice, executor);
        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        life.markDormant(alice);
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NotNamedExecutor.selector);
        life.setEstate(alice, other);
        vm.prank(registrar);
        life.setEstate(alice, executor);
        vm.warp(vm.getBlockTimestamp() + life.ESTATE_NOTICE());
        vm.prank(executor);
        assertEq(life.settleEstate(alice, noVaults), 1000e6);
        assertEq(usd.balanceOf(executor), 1000e6);
    }

    function test_checkIn_keepsAWalletUserActive_andCountsLikeAnyOwnerCall() public {
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + DORMANCY - 1);
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotOwner.selector);
        life.checkIn(alice);
        vm.prank(alice);
        life.checkIn(alice);
        assertEq(life.accountOf(alice).lastActive, start + DORMANCY - 1);
        vm.warp(start + DORMANCY);
        vm.expectRevert(AccountLifecycle.TooEarly.selector);
        life.markDormant(alice);

        // On a dormant account it ends the escheat notice and brings the account back.
        vm.prank(registrar);
        life.setEscheatAuthority(state);
        vm.warp(start + 2 * DORMANCY);
        life.markDormant(alice);
        assertEq(life.accountOf(alice).authority, state);
        vm.prank(alice);
        life.checkIn(alice);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Active));
        assertEq(life.accountOf(alice).noticeAt, 0);
        assertEq(life.accountOf(alice).authority, address(0));
    }

    function test_checkIn_cancelsAnEstateDuringItsNotice_butNotAfter() public {
        vm.prank(alice);
        life.nameExecutor(alice, executor);
        vm.prank(registrar);
        life.setEstate(alice, executor);
        vm.warp(vm.getBlockTimestamp() + life.ESTATE_NOTICE() - 1);
        vm.prank(alice);
        life.checkIn(alice);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Active));
        assertEq(life.accountOf(alice).executor, address(0));

        vm.prank(registrar);
        life.setEstate(alice, executor);
        vm.warp(vm.getBlockTimestamp() + life.ESTATE_NOTICE());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Estate));
        life.checkIn(alice);
    }

    function test_checkIn_refusesUnenrolledAndClosedAccounts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.None));
        life.checkIn(bob);
        vm.prank(alice);
        life.closeAccount(alice, bob, noVaults);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Closed));
        life.checkIn(alice);
    }

    function test_settledEstate_executorPaysOutLaterArrivals_andTheOwnerKeyCannot() public {
        vm.prank(alice);
        life.nameExecutor(alice, executor);
        vm.prank(registrar);
        life.setEstate(alice, executor);
        vm.warp(vm.getBlockTimestamp() + life.ESTATE_NOTICE());
        vm.prank(executor);
        assertEq(life.settleEstate(alice, noVaults), 1000e6);

        // Money that reaches the closed estate later, such as a refund, goes to its executor alone.
        usd.mint(alice, 25e6);
        vm.prank(alice);
        vm.expectRevert(AccountLifecycle.NotExecutor.selector);
        life.closeAccount(alice, bob, noVaults);
        vm.prank(other);
        vm.expectRevert(AccountLifecycle.NotExecutor.selector);
        life.settleEstate(alice, noVaults);
        vm.prank(executor);
        assertEq(life.settleEstate(alice, noVaults), 25e6);
        assertEq(usd.balanceOf(executor), 1025e6);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Closed));
    }

    function test_settleEstate_refusesAnAccountTheOwnerClosed() public {
        vm.prank(alice);
        life.closeAccount(alice, bob, noVaults);
        usd.mint(alice, 5e6);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Closed));
        life.settleEstate(alice, noVaults);
        vm.prank(alice);
        assertEq(life.closeAccount(alice, bob, noVaults), 5e6);
    }

    function test_noteActivity_storesNothingForAnUnenrolledAccount() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(address(cards));
        assertEq(uint8(life.noteActivity(bob)), uint8(AccountLifecycle.Status.None));
        assertEq(life.accountOf(bob).lastActive, 0);
        vm.prank(address(cards));
        life.noteActivity(alice);
        assertEq(life.accountOf(alice).lastActive, vm.getBlockTimestamp());
    }
}
