// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AccountKeys } from "../../src/programs/AccountKeys.sol";
import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

contract AccountKeysTest is AuthEnv {
    AccountKeys internal keys;
    address internal phone = makeAddr("phone");
    address internal laptop = makeAddr("laptop");
    address internal g1;
    uint256 internal g1Key;
    address internal g2;
    uint256 internal g2Key;
    address internal g3;
    uint256 internal g3Key;
    address internal stranger;
    uint256 internal strangerKey;

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        keys = new AccountKeys();
        (g1, g1Key) = makeAddrAndKey("g1");
        (g2, g2Key) = makeAddrAndKey("g2");
        (g3, g3Key) = makeAddrAndKey("g3");
        (stranger, strangerKey) = makeAddrAndKey("stranger");
        _setting(abi.encodeCall(cards.setCompanions, (address(keys), address(0), address(0), address(0))));
    }

    function _guardians() internal view returns (address[] memory list) {
        list = new address[](3);
        (list[0], list[1], list[2]) = (g1, g2, g3);
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _configure() internal {
        vm.prank(alice);
        keys.configure(alice, _one(phone), _guardians(), 2);
    }

    function _sign(uint256 key, address account, address next) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keys.recoveryDigest(account, next));
        return abi.encodePacked(r, s, v);
    }

    function _two(uint256 a, uint256 b, address next) internal view returns (bytes[] memory sigs) {
        sigs = new bytes[](2);
        sigs[0] = _sign(a, alice, next);
        sigs[1] = _sign(b, alice, next);
    }

    function test_noKeys_accountSignsAsItself() public view {
        assertTrue(keys.signsFor(alice, alice));
        assertFalse(keys.signsFor(alice, phone));
    }

    function test_configure_onlyListedKeysSign() public {
        _configure();
        assertTrue(keys.signsFor(alice, phone));
        assertFalse(keys.signsFor(alice, alice));
        // The card program follows the registry: the old key no longer freezes the card, the listed one does.
        vm.prank(alice);
        vm.expectRevert(CardAuth.NotCardOwner.selector);
        cards.setOwnStatus(CARD, 1);
        vm.prank(phone);
        cards.setOwnStatus(CARD, 1);
    }

    function test_configure_refusesStrangersAndBadLists() public {
        vm.prank(stranger);
        vm.expectRevert(AccountKeys.NotSigner.selector);
        keys.configure(alice, _one(stranger), _guardians(), 2);
        vm.startPrank(alice);
        vm.expectRevert(AccountKeys.InvalidKeys.selector);
        keys.configure(alice, new address[](0), _guardians(), 2);
        address[] memory dup = new address[](2);
        (dup[0], dup[1]) = (g1, g1);
        vm.expectRevert(AccountKeys.InvalidKeys.selector);
        keys.configure(alice, _one(phone), dup, 1);
        vm.expectRevert(AccountKeys.InvalidKeys.selector);
        keys.configure(alice, _one(address(0)), _guardians(), 1);
        vm.expectRevert(AccountKeys.ThresholdAboveGuardians.selector);
        keys.configure(alice, _one(phone), _guardians(), 4);
        // Zero means a majority.
        keys.configure(alice, _one(phone), _guardians(), 0);
        vm.stopPrank();
        (,, uint8 threshold,) = keys.accountOf(alice);
        assertEq(threshold, 2);
    }

    function test_recover_withThreshold_replacesKeys_moneyStays() public {
        usd.mint(alice, 100e6);
        _configure();
        vm.prank(stranger);
        keys.recover(alice, laptop, _two(g1Key, g3Key, laptop));
        assertTrue(keys.signsFor(alice, laptop));
        assertFalse(keys.signsFor(alice, phone));
        assertEq(usd.balanceOf(alice), 100e6);
        vm.prank(phone);
        vm.expectRevert(CardAuth.NotCardOwner.selector);
        cards.setOwnStatus(CARD, 1);
        vm.prank(laptop);
        cards.setOwnStatus(CARD, 1);
    }

    function test_recover_belowThreshold_reverts() public {
        _configure();
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(g1Key, alice, laptop);
        vm.expectRevert(abi.encodeWithSelector(AccountKeys.NotEnoughGuardians.selector, 1, 2));
        keys.recover(alice, laptop, sigs);
    }

    function test_recover_repeatsAndStrangersDontCount() public {
        _configure();
        bytes[] memory sigs = new bytes[](4);
        sigs[0] = _sign(g1Key, alice, laptop);
        sigs[1] = _sign(g1Key, alice, laptop);
        sigs[2] = _sign(strangerKey, alice, laptop);
        sigs[3] = hex"1234";
        vm.expectRevert(abi.encodeWithSelector(AccountKeys.NotEnoughGuardians.selector, 1, 2));
        keys.recover(alice, laptop, sigs);
    }

    function test_recover_approvalsDontMoveToAnotherKeyOrReplay() public {
        _configure();
        bytes[] memory sigs = _two(g1Key, g2Key, laptop);
        // Approvals for the laptop don't move the account to the stranger.
        vm.expectRevert(abi.encodeWithSelector(AccountKeys.NotEnoughGuardians.selector, 0, 2));
        keys.recover(alice, stranger, sigs);
        keys.recover(alice, laptop, sigs);
        // The nonce moved, so the same approvals can't run the recovery again after the owner changes keys.
        vm.prank(laptop);
        keys.configure(alice, _one(phone), _guardians(), 2);
        vm.expectRevert(abi.encodeWithSelector(AccountKeys.NotEnoughGuardians.selector, 0, 2));
        keys.recover(alice, laptop, sigs);
    }

    function test_recover_noGuardians_cannotRecover() public {
        vm.prank(alice);
        keys.configure(alice, _one(phone), new address[](0), 3);
        vm.expectRevert(abi.encodeWithSelector(AccountKeys.NotEnoughGuardians.selector, 0, 0));
        keys.recover(alice, laptop, new bytes[](0));
    }

    function test_recover_zeroKey_reverts() public {
        _configure();
        vm.expectRevert(AccountKeys.InvalidKeys.selector);
        keys.recover(alice, address(0), new bytes[](0));
    }

    function test_setCompanions_onlyIssuer() public {
        vm.prank(alice);
        vm.expectRevert(CardAuth.NotIssuer.selector);
        cards.setCompanions(address(0), address(0), address(0), address(0));
    }
}
