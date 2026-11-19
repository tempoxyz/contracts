// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardAuthBase } from "../../src/programs/CardAuthBase.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";
import { StubSource } from "./harness/StubSource.sol";

/// @notice The issuer's settings on CardAuth: sources, companions and the companions it follows wait SETTINGS_DELAY
///         once any owner has granted the program, removals apply at once, and the issuer role moves in two steps.
contract CardAuthSettingsTest is AuthEnv {
    address internal source;
    address internal next = makeAddr("next-issuer");
    address internal companion = makeAddr("companion");

    function setUp() public {
        _deployPrograms();
        source = address(new StubSource(cards, address(usd)));
    }

    function test_settings_applyAtOnceBeforeAnyGrant() public {
        assertEq(cards.grantedOwners(), 0);
        vm.startPrank(issuer);
        cards.setSource(source, true);
        cards.setCompanion(companion, true);
        cards.setCompanions(companion, companion, companion, companion);
        vm.stopPrank();
        assertEq(cards.sourceKind(source), 4);
        assertTrue(cards.isCompanion(companion));
        assertEq(cards.conversion(), companion);
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
        emit CardAuthBase.SettingProposed(id, data, eta);
        vm.prank(issuer);
        cards.setSource(source, true);
        assertEq(cards.sourceKind(source), 0);
        assertEq(cards.pendingSetting(id), eta);

        vm.warp(eta - 1);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardAuthBase.SettingPending.selector, eta));
        cards.setSource(source, true);
        // Only the issuer applies it.
        vm.warp(eta);
        vm.prank(alice);
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
        cards.setSource(source, true);
        vm.prank(issuer);
        cards.setSource(source, true);
        assertEq(cards.sourceKind(source), 4);
        assertEq(cards.pendingSetting(id), 0);
    }

    function test_settings_restrictiveChangesApplyAtOnce() public {
        _setting(abi.encodeCall(cards.setCompanion, (companion, true)));
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        vm.startPrank(issuer);
        cards.setSource(address(savings), false);
        cards.setCompanion(companion, false);
        vm.stopPrank();
        assertEq(cards.sourceKind(address(savings)), 0);
        assertFalse(cards.isCompanion(companion));
        // A stopped source cannot be listed in a new order.
        vm.prank(alice);
        vm.expectRevert();
        _setFunding(true, true, false);
    }

    function test_settings_everyMoneySettingWaits() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        vm.startPrank(issuer);
        cards.setSource(source, true);
        cards.setCompanion(companion, true);
        cards.setCompanions(companion, companion, companion, companion);
        vm.stopPrank();
        assertEq(cards.sourceKind(source), 0);
        assertFalse(cards.isCompanion(companion));
        assertEq(cards.conversion(), address(0));
        assertEq(cards.accountKeys(), address(0));
        assertEq(cards.identityRules(), address(0));
        assertEq(cards.lifecycle(), address(0));
        bytes memory data = abi.encodeCall(cards.setCompanions, (companion, companion, companion, companion));
        assertNotEq(cards.pendingSetting(keccak256(data)), 0);
    }

    function test_setSource_refusesWhatIsNotASource() public {
        vm.prank(issuer);
        vm.expectRevert();
        cards.setSource(makeAddr("eoa"), true);
    }

    function test_companionOnly_operatorCapAndSettlementToken() public {
        vm.expectRevert(CardAuthBase.NotCompanion.selector);
        cards.useOperatorCap(issuer, 1);
        vm.expectRevert(CardAuthBase.NotCompanion.selector);
        cards.setSettlementToken(address(otherUsd), 1e18);
    }

    function test_cancelSetting_dropsTheProposal() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        bytes32 id = keccak256(abi.encodeCall(cards.setSource, (source, true)));
        vm.prank(issuer);
        cards.setSource(source, true);
        vm.prank(alice);
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
        cards.cancelSetting(id);
        vm.expectEmit(address(cards));
        emit CardAuthBase.SettingCancelled(id);
        vm.prank(issuer);
        cards.cancelSetting(id);
        assertEq(cards.pendingSetting(id), 0);
        // After the delay the same call only proposes again.
        vm.warp(vm.getBlockTimestamp() + cards.SETTINGS_DELAY());
        vm.prank(issuer);
        cards.setSource(source, true);
        assertEq(cards.sourceKind(source), 0);
        assertNotEq(cards.pendingSetting(id), 0);
    }

    function test_transferIssuer_takesTwoSteps() public {
        address key = makeAddr("key");
        vm.prank(alice);
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
        cards.transferIssuer(next);
        vm.expectEmit(address(cards));
        emit CardAuthBase.IssuerOffered(issuer, next);
        vm.prank(issuer);
        cards.transferIssuer(next);
        assertEq(cards.pendingIssuer(), next);
        // Until it is accepted the issuer keeps its role, and only the offered address can accept.
        assertEq(cards.ISSUER(), issuer);
        vm.prank(alice);
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
        cards.acceptIssuer();
        vm.expectEmit(address(cards));
        emit CardAuthBase.IssuerTransferred(issuer, next);
        vm.prank(next);
        cards.acceptIssuer();
        assertEq(cards.ISSUER(), next);
        assertEq(cards.pendingIssuer(), address(0));

        // The previous issuer loses every power; the new one has them.
        vm.startPrank(issuer);
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
        cards.setOperator(key, 1, 100e6);
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
        cards.issueCard(CARD, alice, uint40(block.timestamp + 365 days), _limits(500e6, 1000e6, 5000e6), 7);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.authorize(CARD, "p", 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();
        vm.startPrank(next);
        cards.setOperator(key, 1, 100e6);
        cards.issueCard(CARD, alice, uint40(block.timestamp + 365 days), _limits(500e6, 1000e6, 5000e6), 7);
        vm.stopPrank();
        assertTrue(cards.hasRoles(key, 1));
        assertFalse(cards.hasRoles(key, 2));
        assertTrue(cards.hasRoles(next, 7));
        assertFalse(cards.hasRoles(issuer, 1));
    }

    function test_operatorRoles_authorizerCannotRefundOrSettle() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 100e6);
        address key = makeAddr("key");
        uint8 authorizer = cards.ROLE_AUTHORIZE();
        uint8 treasury = cards.ROLE_TREASURY();
        vm.prank(issuer);
        cards.setOperator(key, authorizer, 1000e6);
        assertEq(cards.operatorOf(key).roles, authorizer);
        vm.startPrank(key);
        cards.authorize(CARD, "purchase-1", 10e6, merchant, uint64(block.timestamp + 1 days), 0);
        cards.capture("purchase-1", 10e6, true);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.refund("purchase-1", 1e6);
        vm.expectRevert(CardAuthBase.NotCompanion.selector);
        cards.creditBack("purchase-1", 1e6, 1e6);
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
        cards.setOperator(key, 7, 1e6);
        vm.stopPrank();
        // A key needs a cap, and zero roles remove it.
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.setOperator(key, treasury, 0);
        vm.prank(issuer);
        cards.setOperator(key, 0, 0);
        assertEq(cards.operatorOf(key).roles, 0);
        vm.prank(key);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.authorize(CARD, "purchase-2", 1e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_operatorCap_countsAuthorizeChargeAndCompanionUseTogether() public {
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 100e6);
        _setting(abi.encodeCall(cards.setCompanion, (companion, true)));
        address key = makeAddr("key");
        vm.prank(issuer);
        cards.setOperator(key, 7, 100e6);
        vm.prank(key);
        cards.authorize(CARD, "purchase-1", 40e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(key);
        cards.charge(CARD, "purchase-2", 30e6, merchant);
        // A companion (the treasury paying out) counts what the operator moved through it.
        vm.prank(companion);
        cards.useOperatorCap(key, 20e6);
        CardAuth.Operator memory op = cards.operatorOf(key);
        assertEq(op.cap, 100e6);
        assertEq(op.used, 90e6);
        vm.prank(companion);
        vm.expectRevert(CardAuthBase.OperatorCapExceeded.selector);
        cards.useOperatorCap(key, 10e6 + 1);
        vm.prank(key);
        vm.expectRevert(CardAuthBase.OperatorCapExceeded.selector);
        cards.charge(CARD, "purchase-3", 10e6 + 1, merchant);
        // An increment counts only what it adds.
        vm.prank(key);
        cards.adjust("purchase-1", 50e6);
        assertEq(cards.operatorOf(key).used, 100e6);
        // The issuer itself has no cap.
        vm.prank(companion);
        cards.useOperatorCap(issuer, 1000e6);
        vm.prank(issuer);
        cards.charge(CARD, "purchase-4", 1e6, merchant);
    }
}
