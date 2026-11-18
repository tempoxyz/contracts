// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AccountLifecycle } from "../../src/programs/AccountLifecycle.sol";
import { CardProgram } from "../../src/programs/CardProgram.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

contract AccountLifecycleTest is ProgramsEnv {
    AccountLifecycle internal life;
    address internal registrar = makeAddr("registrar");
    address internal executor = makeAddr("executor");
    address internal heir = makeAddr("heir");
    address internal state = makeAddr("state");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    uint64 internal constant DORMANCY = 180 days;
    uint64 internal constant ESCHEAT = 3 * 365 days;

    address[] internal noVaults;
    address[] internal vaults;

    function setUp() public {
        _deployPrograms();
        life = new AccountLifecycle(address(usd), registrar, address(0), DORMANCY, ESCHEAT);
        vm.prank(issuer);
        cards.setLifecycle(address(life));
        vm.prank(registrar);
        life.setProgram(address(cards), true);
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        vm.startPrank(alice);
        life.enroll();
        usd.approve(address(life), type(uint256).max);
        earnShare.approve(address(life), type(uint256).max);
        vm.stopPrank();
        vaults.push(address(earnVault));
    }

    // Status.

    function test_enroll_once() public {
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Active));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Active));
        life.enroll();
    }

    function test_markDormant_onlyAfterDormancy_andCardActivityResetsIt() public {
        vm.warp(vm.getBlockTimestamp() + DORMANCY - 1);
        vm.expectRevert(AccountLifecycle.TooEarly.selector);
        life.markDormant(alice);

        usd.mint(alice, 100e6);
        _authorize(P1, 10e6);
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.expectRevert(AccountLifecycle.TooEarly.selector);
        life.markDormant(alice);

        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        vm.prank(bob);
        life.markDormant(alice);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Dormant));
    }

    function test_noteActivity_onlyFromRegisteredProgram() public {
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotRegistrar.selector);
        life.setProgram(bob, true);
        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        // A contract the registrar never registered cannot keep the account active.
        vm.prank(bob);
        life.noteActivity(alice);
        life.markDormant(alice);
    }

    function test_dormant_declinesNewHolds_untilOwnerReactivates() public {
        usd.mint(alice, 100e6);
        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        life.markDormant(alice);
        vm.prank(issuer);
        vm.expectRevert(CardProgram.AccountInactive.selector);
        cards.authorize(CARD, P1, 1e6, merchant, uint64(block.timestamp + 1 days), 0);

        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotOwner.selector);
        life.reactivate(alice);
        vm.prank(alice);
        life.reactivate(alice);
        _authorize(P1, 1e6);
    }

    // Closure.

    function test_closeAccount_paysOutCashAndShares_andClosesCards() public {
        usd.mint(alice, 100e6);
        vm.prank(alice);
        usd.approve(address(earnVault), type(uint256).max);
        vm.prank(alice);
        earnVault.deposit(40e6, alice, 1);
        _authorize(P1, 10e6);

        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotOwner.selector);
        life.closeAccount(alice, bob, vaults);

        vm.prank(alice);
        uint256 paid = life.closeAccount(alice, heir, vaults);
        // The open hold stays reserved; available cash and redeemed shares go out.
        assertApproxEqAbs(paid, 90e6, 1);
        assertApproxEqAbs(usd.balanceOf(heir), 90e6, 1);
        assertEq(earnShare.balanceOf(alice), 0);
        assertEq(core.reserved(alice, address(usd)), 10e6);
        assertEq(uint8(cards.cardOf(CARD).status), uint8(CardProgram.Status.Closed));

        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardsClosed.selector);
        cards.authorize(CARD, P2, 1e6, merchant, uint64(block.timestamp + 1 days), 0);

        // The hold's release is paid out by a later close.
        vm.prank(issuer);
        cards.release(P1);
        vm.prank(alice);
        assertEq(life.closeAccount(alice, heir, noVaults), 10e6);
        _assertCoreBalanced();
    }

    function test_closeAccount_refusesSelfOrZeroPayee() public {
        vm.startPrank(alice);
        vm.expectRevert(AccountLifecycle.InvalidPayee.selector);
        life.closeAccount(alice, alice, noVaults);
        vm.expectRevert(AccountLifecycle.InvalidPayee.selector);
        life.closeAccount(alice, address(0), noVaults);
        vm.stopPrank();
    }

    function test_payout_refusesVaultOfAnotherAsset() public {
        address[] memory bad = new address[](1);
        bad[0] = address(new FakeVault(address(0xBEEF)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.InvalidVault.selector, bad[0]));
        life.closeAccount(alice, heir, bad);
    }

    function test_payout_leavesLienedFunds() public {
        usd.mint(alice, 100e6);
        core.grantLienRole(state, true);
        vm.prank(state);
        core.lien(alice, address(usd), bytes32("levy"), 30e6, 0);
        vm.prank(alice);
        assertEq(life.closeAccount(alice, heir, noVaults), 70e6);
        assertEq(core.liened(alice, address(usd)), 30e6);
    }

    // Estates.

    function test_setEstate_activeAccount_needsTheExecutorTheOwnerNamed() public {
        usd.mint(alice, 100e6);
        // The registrar alone cannot put an active account in anyone's hands.
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NotNamedExecutor.selector);
        life.setEstate(alice, stranger);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Active));
        life.settleEstate(alice, noVaults);

        vm.prank(alice);
        life.nameExecutor(alice, executor);
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NotNamedExecutor.selector);
        life.setEstate(alice, stranger);
        vm.prank(registrar);
        life.setEstate(alice, executor);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Estate));

        // Withdrawn consent stops a later estate.
        vm.prank(alice);
        life.reactivate(alice);
        vm.prank(alice);
        life.nameExecutor(alice, address(0));
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NotNamedExecutor.selector);
        life.setEstate(alice, executor);
    }

    function test_setEstate_refusesClosedEstateOrUnenrolled_andSelfOrZeroExecutor() public {
        vm.startPrank(registrar);
        vm.expectRevert(AccountLifecycle.ZeroAddress.selector);
        life.setEstate(alice, address(0));
        vm.expectRevert(AccountLifecycle.InvalidPayee.selector);
        life.setEstate(alice, alice);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.None));
        life.setEstate(bob, executor);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(AccountLifecycle.InvalidPayee.selector);
        life.nameExecutor(alice, alice);
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotOwner.selector);
        life.nameExecutor(alice, bob);

        vm.prank(alice);
        life.nameExecutor(alice, executor);
        vm.prank(registrar);
        life.setEstate(alice, executor);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Estate));
        life.setEstate(alice, executor);

        vm.prank(alice);
        life.reactivate(alice);
        vm.prank(alice);
        life.closeAccount(alice, heir, noVaults);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Closed));
        life.setEstate(alice, executor);
    }

    function test_estate_freezesCards_andOnlyExecutorSettles_toItself_afterNoticeAndHolds() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 10e6);
        _authorize(P2, 5e6);
        vm.prank(alice);
        life.nameExecutor(alice, executor);
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotRegistrar.selector);
        life.setEstate(alice, executor);
        vm.prank(registrar);
        life.setEstate(alice, executor);
        uint256 start = vm.getBlockTimestamp();
        assertEq(uint8(cards.cardOf(CARD).status), uint8(CardProgram.Status.Frozen));
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardsClosed.selector);
        cards.authorize(CARD, bytes32("purchase-3"), 1e6, merchant, uint64(block.timestamp + 1 days), 0);

        // Nobody but the executor settles it, and the executor only once holds end and the notice period passed.
        vm.prank(alice);
        vm.expectRevert(AccountLifecycle.NotExecutor.selector);
        life.settleEstate(alice, noVaults);
        vm.prank(executor);
        vm.expectRevert(AccountLifecycle.HoldsOpen.selector);
        life.settleEstate(alice, noVaults);
        // Open holds still capture or release.
        _capture(P1, 10e6, true);
        vm.prank(issuer);
        cards.release(P2);
        vm.prank(executor);
        vm.expectRevert(AccountLifecycle.TooEarly.selector);
        life.settleEstate(alice, noVaults);
        vm.warp(start + life.ESTATE_NOTICE() - 1);
        vm.prank(executor);
        vm.expectRevert(AccountLifecycle.TooEarly.selector);
        life.settleEstate(alice, noVaults);
        vm.warp(start + life.ESTATE_NOTICE());

        // After the notice the owner's key can neither close nor cancel it.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Estate));
        life.closeAccount(alice, bob, noVaults);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Estate));
        life.reactivate(alice);

        vm.prank(executor);
        assertEq(life.settleEstate(alice, noVaults), 90e6);
        // The estate pays only its recorded executor.
        assertEq(usd.balanceOf(executor), 90e6);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Closed));
        assertEq(life.accountOf(alice).executor, executor);
        vm.prank(executor);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Closed));
        life.settleEstate(alice, noVaults);
    }

    function test_estate_dormantAccount_registrarNamesExecutor_ownerCancelsDuringNotice() public {
        usd.mint(alice, 100e6);
        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        life.markDormant(alice);
        vm.prank(registrar);
        life.setEstate(alice, stranger);

        // Card activity is not the owner's own act, so it leaves the estate pending.
        vm.prank(address(cards));
        life.noteActivity(alice);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Estate));

        vm.warp(vm.getBlockTimestamp() + life.ESTATE_NOTICE() - 1);
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotOwner.selector);
        life.reactivate(alice);
        vm.prank(alice);
        life.reactivate(alice);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Active));
        assertEq(life.accountOf(alice).executor, address(0));
        assertEq(life.accountOf(alice).noticeAt, 0);

        vm.warp(vm.getBlockTimestamp() + life.ESTATE_NOTICE());
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Active));
        life.settleEstate(alice, noVaults);
        assertEq(usd.balanceOf(alice), 100e6);
        _authorize(P1, 1e6);
    }

    function test_estate_ownerCallsDuringNoticeCancelIt() public {
        usd.mint(alice, 100e6);
        vm.prank(alice);
        life.nameExecutor(alice, executor);

        // Naming another executor cancels the pending estate.
        vm.prank(registrar);
        life.setEstate(alice, executor);
        vm.prank(alice);
        life.nameExecutor(alice, heir);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Active));
        assertEq(life.accountOf(alice).executor, address(0));

        // Closing is refused while it is an estate; the owner cancels it first, then closes and pays where it says.
        vm.prank(registrar);
        life.setEstate(alice, heir);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Estate));
        life.closeAccount(alice, bob, noVaults);
        vm.prank(alice);
        life.reactivate(alice);
        vm.prank(alice);
        assertEq(life.closeAccount(alice, bob, noVaults), 100e6);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Closed));
        vm.warp(vm.getBlockTimestamp() + life.ESTATE_NOTICE());
        vm.prank(heir);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Closed));
        life.settleEstate(alice, noVaults);
    }

    // Unclaimed property.

    function test_escheat_onlyDormantPastPeriodAndNotice_byRegistrar_toNoticedAuthority() public {
        usd.mint(alice, 100e6);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Active));
        life.escheat(alice, noVaults);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Active));
        life.noticeEscheat(alice, state);

        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        life.markDormant(alice);
        // No default authority: the dormancy mark names none, so the registrar gives the notice.
        vm.warp(vm.getBlockTimestamp() + ESCHEAT);
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NoNotice.selector);
        life.escheat(alice, noVaults);
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotRegistrar.selector);
        life.noticeEscheat(alice, bob);
        vm.startPrank(registrar);
        vm.expectRevert(AccountLifecycle.InvalidPayee.selector);
        life.noticeEscheat(alice, alice);
        life.noticeEscheat(alice, state);
        assertEq(life.accountOf(alice).authority, state);
        vm.expectRevert(AccountLifecycle.TooEarly.selector);
        life.escheat(alice, noVaults);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + life.ESCHEAT_NOTICE());
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotRegistrar.selector);
        life.escheat(alice, noVaults);
        vm.prank(registrar);
        assertEq(life.escheat(alice, noVaults), 100e6);
        assertEq(usd.balanceOf(state), 100e6);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Dormant));
    }

    function test_markDormant_noticesDefaultAuthority_andEscheatKeepsItsTiming() public {
        usd.mint(alice, 100e6);
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotRegistrar.selector);
        life.setEscheatAuthority(bob);
        vm.prank(registrar);
        life.setEscheatAuthority(state);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + DORMANCY);
        life.markDormant(alice);
        assertEq(life.accountOf(alice).authority, state);
        assertEq(life.accountOf(alice).noticeAt, start + DORMANCY);

        // A later default does not change the authority this notice named.
        vm.prank(registrar);
        life.setEscheatAuthority(bob);
        vm.warp(start + ESCHEAT - 1);
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NotUnclaimed.selector);
        life.escheat(alice, noVaults);
        vm.warp(start + ESCHEAT);
        vm.prank(registrar);
        assertEq(life.escheat(alice, noVaults), 100e6);
        assertEq(usd.balanceOf(state), 100e6);
        assertEq(usd.balanceOf(bob), 0);
    }

    function test_escheat_sweepsOncePerNotice() public {
        usd.mint(alice, 100e6);
        vm.prank(registrar);
        life.setEscheatAuthority(state);
        vm.warp(vm.getBlockTimestamp() + ESCHEAT);
        life.markDormant(alice);
        vm.warp(vm.getBlockTimestamp() + life.ESCHEAT_NOTICE());
        vm.prank(registrar);
        assertEq(life.escheat(alice, noVaults), 100e6);

        // Money that arrives later needs a new notice and its full period.
        usd.mint(alice, 5e6);
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NoNotice.selector);
        life.escheat(alice, noVaults);
        vm.prank(registrar);
        life.noticeEscheat(alice, state);
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.TooEarly.selector);
        life.escheat(alice, noVaults);
        vm.warp(vm.getBlockTimestamp() + life.ESCHEAT_NOTICE());
        vm.prank(registrar);
        assertEq(life.escheat(alice, noVaults), 5e6);
        assertEq(usd.balanceOf(state), 105e6);
    }

    function test_escheat_ownerActivityEndsTheNotice() public {
        usd.mint(alice, 100e6);
        vm.prank(registrar);
        life.setEscheatAuthority(state);
        vm.warp(vm.getBlockTimestamp() + ESCHEAT);
        life.markDormant(alice);
        vm.warp(vm.getBlockTimestamp() + life.ESCHEAT_NOTICE() - 1);
        vm.prank(alice);
        life.reactivate(alice);
        assertEq(life.accountOf(alice).noticeAt, 0);
        assertEq(life.accountOf(alice).authority, address(0));
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Active));
        life.escheat(alice, noVaults);

        // Dormant again, the owner's naming an executor counts the same way.
        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        life.markDormant(alice);
        vm.prank(alice);
        life.nameExecutor(alice, executor);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Active));
        assertEq(life.accountOf(alice).noticeAt, 0);
        assertEq(usd.balanceOf(state), 0);
    }

    function test_escheat_cardActivityAfterNoticeVoidsIt() public {
        usd.mint(alice, 100e6);
        vm.prank(registrar);
        life.setEscheatAuthority(state);
        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        life.markDormant(alice);
        vm.warp(vm.getBlockTimestamp() + 1);
        // A counted program reports activity, as a force post on the dormant account does.
        vm.prank(address(cards));
        life.noteActivity(alice);
        vm.warp(vm.getBlockTimestamp() + ESCHEAT);
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NoNotice.selector);
        life.escheat(alice, noVaults);
    }

    // Replacement.

    function test_openPurchase_followsCardReplacement() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        bytes32 next = bytes32("card-2");
        vm.prank(issuer);
        cards.replaceCard(CARD, next, uint40(block.timestamp + 700 days));
        vm.prank(issuer);
        cards.adjust(P1, 300e6);
        assertEq(cards.purchaseOf(P1).card, next);
        // The new card's per-purchase limit still applies to the increment.
        vm.prank(issuer);
        vm.expectRevert();
        cards.adjust(P1, 600e6);
        _capture(P1, 300e6, true);
        assertEq(usd.balanceOf(settlement), 300e6);
    }

    function test_openPurchase_followsChainOfReplacements_andFrozenReplacementBlocksGrowth() public {
        usd.mint(alice, 1000e6);
        _authorize(P1, 100e6);
        vm.startPrank(issuer);
        cards.replaceCard(CARD, bytes32("card-2"), uint40(block.timestamp + 700 days));
        cards.replaceCard(bytes32("card-2"), bytes32("card-3"), uint40(block.timestamp + 700 days));
        vm.stopPrank();
        vm.prank(alice);
        cards.freeze(bytes32("card-3"));
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardNotActive.selector);
        cards.adjust(P1, 200e6);
        vm.prank(alice);
        cards.unfreeze(bytes32("card-3"));
        vm.prank(issuer);
        cards.adjust(P1, 200e6);
        assertEq(cards.purchaseOf(P1).card, bytes32("card-3"));
    }

    function test_lifecycle_onlyIssuerSetsIt() public {
        vm.prank(bob);
        vm.expectRevert();
        cards.setLifecycle(address(0));
    }
}

contract FakeVault {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }
}
