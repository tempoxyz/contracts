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

    function test_estate_freezesCards_andOnlyExecutorSettlesAfterHoldsEnd() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 10e6);
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotRegistrar.selector);
        life.setEstate(alice, executor);
        vm.prank(registrar);
        life.setEstate(alice, executor);
        assertEq(uint8(cards.cardOf(CARD).status), uint8(CardProgram.Status.Frozen));
        vm.prank(issuer);
        vm.expectRevert(CardProgram.CardsClosed.selector);
        cards.authorize(CARD, P2, 1e6, merchant, uint64(block.timestamp + 1 days), 0);

        // The owner can no longer close it, and nobody but the executor settles it.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Estate));
        life.closeAccount(alice, bob, noVaults);
        vm.prank(alice);
        vm.expectRevert(AccountLifecycle.NotExecutor.selector);
        life.settleEstate(alice, bob, noVaults);
        vm.prank(executor);
        vm.expectRevert(AccountLifecycle.HoldsOpen.selector);
        life.settleEstate(alice, heir, noVaults);

        _capture(P1, 10e6, true);
        vm.prank(executor);
        assertEq(life.settleEstate(alice, heir, noVaults), 90e6);
        assertEq(uint8(life.statusOf(alice)), uint8(AccountLifecycle.Status.Closed));
        assertEq(life.accountOf(alice).executor, executor);
    }

    // Unclaimed property.

    function test_escheat_onlyDormantPastPeriod_byRegistrar() public {
        usd.mint(alice, 100e6);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(AccountLifecycle.AccountState.selector, AccountLifecycle.Status.Active));
        life.escheat(alice, state, noVaults);

        vm.warp(vm.getBlockTimestamp() + DORMANCY);
        life.markDormant(alice);
        vm.prank(registrar);
        vm.expectRevert(AccountLifecycle.NotUnclaimed.selector);
        life.escheat(alice, state, noVaults);

        vm.warp(vm.getBlockTimestamp() + ESCHEAT);
        vm.prank(bob);
        vm.expectRevert(AccountLifecycle.NotRegistrar.selector);
        life.escheat(alice, bob, noVaults);
        vm.prank(registrar);
        assertEq(life.escheat(alice, state, noVaults), 100e6);
        assertEq(usd.balanceOf(state), 100e6);
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
