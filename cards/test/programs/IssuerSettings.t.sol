// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardLimits } from "../../src/programs/CardLimits.sol";
import { CardProgram } from "../../src/programs/CardProgram.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice The issuer's settings: changes that move money wait SETTINGS_DELAY once any owner has granted the program,
///         restrictive ones apply at once, and the issuer role moves in two steps.
contract IssuerSettingsTest is ProgramsEnv {
    address internal source = makeAddr("source");
    address internal next = makeAddr("next-issuer");

    function setUp() public {
        _deployPrograms();
    }

    function test_settings_applyAtOnceBeforeAnyGrant() public {
        assertEq(cards.grantedOwners(), 0);
        vm.prank(issuer);
        cards.setSource(source, true);
        assertTrue(cards.approvedSource(source));
        vm.prank(issuer);
        cards.setRate(address(otherUsd), 1.25e18);
        assertEq(cards.rateOf(address(otherUsd)), 1.25e18);
    }

    function test_settings_waitTheDelayAfterAGrant() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        assertEq(cards.grantedOwners(), 1);
        // A second grant by the same owner does not count again.
        vm.prank(alice);
        cards.revoke();
        vm.prank(alice);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        assertEq(cards.grantedOwners(), 1);

        bytes memory data = abi.encodeCall(cards.setSource, (source, true));
        bytes32 id = keccak256(data);
        uint64 eta = uint64(vm.getBlockTimestamp()) + cards.SETTINGS_DELAY();
        vm.expectEmit(address(cards));
        emit CardProgram.SettingProposed(id, data, eta);
        vm.prank(issuer);
        cards.setSource(source, true);
        assertFalse(cards.approvedSource(source));
        assertEq(cards.pendingSetting(id), eta);

        vm.warp(eta - 1);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettingPending.selector, eta));
        cards.setSource(source, true);
        // Only the issuer applies it.
        vm.warp(eta);
        vm.prank(alice);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.setSource(source, true);
        vm.prank(issuer);
        cards.setSource(source, true);
        assertTrue(cards.approvedSource(source));
        assertEq(cards.pendingSetting(id), 0);
    }

    function test_settings_restrictiveChangesApplyAtOnce() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        vm.prank(issuer);
        cards.setSource(address(facility), false);
        assertFalse(cards.approvedSource(address(facility)));
        _setting(abi.encodeCall(cards.setRate, (address(otherUsd), 1.25e18)));
        vm.prank(issuer);
        cards.setRate(address(otherUsd), 0);
        assertEq(cards.rateOf(address(otherUsd)), 0);
    }

    function test_settings_everyMoneySettingWaits() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        address[] memory guards = new address[](1);
        guards[0] = source;
        vm.startPrank(issuer);
        cards.setConversion(source);
        cards.setTokenGuards(guards);
        cards.setCompanions(source, source);
        cards.setLifecycle(source);
        cards.setCollateral(source);
        vm.stopPrank();
        assertEq(cards.conversion(), address(0));
        assertEq(cards.accountKeys(), address(0));
        assertEq(cards.lifecycle(), address(0));
        assertEq(cards.tokenGuards(0), source, "appending a guard applies at once");
        assertNotEq(cards.pendingSetting(keccak256(abi.encodeCall(cards.setCollateral, (source)))), 0);
    }

    function test_setTokenGuards_appendsAtOnceButReplacingWaits() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        address other = makeAddr("other-guard");
        address[] memory one = new address[](1);
        one[0] = source;
        address[] memory two = new address[](2);
        two[0] = source;
        two[1] = other;
        vm.startPrank(issuer);
        cards.setTokenGuards(one);
        cards.setTokenGuards(two);
        assertEq(cards.tokenGuards(1), other);
        // Dropping a guard, or putting another in its place, waits the delay.
        address[] memory replaced = new address[](1);
        replaced[0] = other;
        cards.setTokenGuards(replaced);
        assertEq(cards.tokenGuards(0), source);
        assertEq(cards.tokenGuards(1), other);
        assertNotEq(cards.pendingSetting(keccak256(abi.encodeCall(cards.setTokenGuards, (replaced)))), 0);
        address[] memory none = new address[](0);
        cards.setTokenGuards(none);
        assertNotEq(cards.pendingSetting(keccak256(abi.encodeCall(cards.setTokenGuards, (none)))), 0);
        vm.stopPrank();
        assertEq(cards.tokenGuards(1), other);
    }

    function test_cancelSetting_dropsTheProposal() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        bytes32 id = keccak256(abi.encodeCall(cards.setSource, (source, true)));
        vm.prank(issuer);
        cards.setSource(source, true);
        vm.prank(alice);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.cancelSetting(id);
        vm.expectEmit(address(cards));
        emit CardProgram.SettingCancelled(id);
        vm.prank(issuer);
        cards.cancelSetting(id);
        assertEq(cards.pendingSetting(id), 0);
        // After the delay the same call only proposes again.
        vm.warp(vm.getBlockTimestamp() + cards.SETTINGS_DELAY());
        vm.prank(issuer);
        cards.setSource(source, true);
        assertFalse(cards.approvedSource(source));
        assertNotEq(cards.pendingSetting(id), 0);
    }

    function test_setRate_stepsAtMostTenPercent() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        // From zero the rate is unbounded, but it waits.
        vm.prank(issuer);
        cards.setRate(address(otherUsd), 1.25e18);
        assertEq(cards.rateOf(address(otherUsd)), 0);
        vm.warp(vm.getBlockTimestamp() + cards.SETTINGS_DELAY());
        vm.prank(issuer);
        cards.setRate(address(otherUsd), 1.25e18);
        assertEq(cards.rateOf(address(otherUsd)), 1.25e18);
        vm.startPrank(issuer);
        vm.expectRevert(CardProgram.RateStep.selector);
        cards.setRate(address(otherUsd), 1.375e18 + 1);
        vm.expectRevert(CardProgram.RateStep.selector);
        cards.setRate(address(otherUsd), 1.125e18 - 1);
        vm.stopPrank();
        _setting(abi.encodeCall(cards.setRate, (address(otherUsd), 1.375e18)));
        assertEq(cards.rateOf(address(otherUsd)), 1.375e18);
        _setting(abi.encodeCall(cards.setRate, (address(otherUsd), 1.2375e18)));
        assertEq(cards.rateOf(address(otherUsd)), 1.2375e18);
    }

    function test_transferIssuer_takesTwoSteps() public {
        address key = makeAddr("key");
        vm.prank(alice);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.transferIssuer(next);
        vm.expectEmit(address(cards));
        emit CardProgram.IssuerOffered(issuer, next);
        vm.prank(issuer);
        cards.transferIssuer(next);
        assertEq(cards.pendingIssuer(), next);
        // Until it is accepted the issuer keeps its role, and only the offered address can accept.
        assertEq(cards.ISSUER(), issuer);
        vm.prank(alice);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.acceptIssuer();
        vm.expectEmit(address(cards));
        emit CardProgram.IssuerTransferred(issuer, next);
        vm.prank(next);
        cards.acceptIssuer();
        assertEq(cards.ISSUER(), next);
        assertEq(cards.pendingIssuer(), address(0));

        // The previous issuer loses every power; the new one has them.
        vm.startPrank(issuer);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.setOperator(key, 1, 100e6);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.issueCard(CARD, alice, uint40(block.timestamp + 365 days), _limits(500e6, 1000e6, 5000e6), 7);
        vm.expectRevert(CardProgram.NotIssuer.selector);
        cards.payOut(alice, 1, "");
        vm.stopPrank();
        vm.startPrank(next);
        cards.setOperator(key, 1, 100e6);
        cards.issueCard(CARD, alice, uint40(block.timestamp + 365 days), _limits(500e6, 1000e6, 5000e6), 7);
        vm.stopPrank();
        assertEq(cards.rolesOf(key), 1);
    }
}
