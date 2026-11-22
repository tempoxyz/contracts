// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuth } from "../../../src/spend/programs/CardAuth.sol";
import { CardAuthBase } from "../../../src/spend/programs/CardAuthBase.sol";
import { CardLimits } from "../../../src/spend/programs/CardLimits.sol";
import { CardRegistry } from "../../../src/spend/programs/CardRegistry.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

contract CardRegistryTest is AuthEnv {
    CardRegistry internal registry;
    bytes32 internal constant TOKEN = keccak256("network-token-ref");
    bytes32 internal constant NEXT = bytes32("card-2");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        registry = new CardRegistry(cards);
    }

    function test_bindToken_recordsBothWays() public {
        vm.expectEmit(address(registry));
        emit CardRegistry.TokenBound(CARD, TOKEN);
        vm.prank(issuer);
        registry.bindToken(CARD, TOKEN);
        assertEq(registry.cardOfToken(TOKEN), CARD);
        assertEq(registry.metadataOf(CARD).tokenHash, TOKEN);
    }

    function test_bindToken_once() public {
        vm.prank(issuer);
        registry.bindToken(CARD, TOKEN);
        vm.prank(issuer);
        cards.replaceCard(CARD, NEXT, uint40(block.timestamp + 30 days));
        // A replacement keeps the token through the program's record; the hash can't move to another card.
        vm.prank(issuer);
        vm.expectRevert(CardRegistry.TokenAlreadyBound.selector);
        registry.bindToken(NEXT, TOKEN);
        vm.prank(issuer);
        vm.expectRevert(CardRegistry.TokenAlreadyBound.selector);
        registry.bindToken(CARD, bytes32(0));
    }

    function test_unknownCard_refused() public {
        vm.startPrank(issuer);
        vm.expectRevert(CardRegistry.UnknownCard.selector);
        registry.bindToken(NEXT, TOKEN);
        vm.expectRevert(CardRegistry.UnknownCard.selector);
        registry.setProgramType(NEXT, 1);
        vm.expectRevert(CardRegistry.UnknownCard.selector);
        registry.setHolder(NEXT, "x");
        vm.stopPrank();
    }

    function test_onlyIssuerOrOperator_writes() public {
        vm.startPrank(alice);
        vm.expectRevert(CardRegistry.NotIssuer.selector);
        registry.bindToken(CARD, TOKEN);
        vm.expectRevert(CardRegistry.NotIssuer.selector);
        registry.setProgramType(CARD, 1);
        vm.expectRevert(CardRegistry.NotIssuer.selector);
        registry.setHolder(CARD, "Alice");
        vm.stopPrank();
        address operator = makeAddr("operator");
        vm.prank(issuer);
        cards.setOperator(operator, 7, 1e30);
        vm.prank(operator);
        registry.setHolder(CARD, "Alice");
        assertEq(registry.metadataOf(CARD).holder, "Alice");
    }

    function test_setProgramType_validatesRange() public {
        vm.startPrank(issuer);
        registry.setProgramType(CARD, registry.CORPORATE());
        assertEq(registry.metadataOf(CARD).programType, 4);
        vm.expectRevert(CardRegistry.InvalidProgramType.selector);
        registry.setProgramType(CARD, 0);
        vm.expectRevert(CardRegistry.InvalidProgramType.selector);
        registry.setProgramType(CARD, 6);
        vm.stopPrank();
    }

    function test_setExpiry_stopsAuthorizationPastIt() public {
        usd.mint(alice, 100e6);
        uint40 expiry = uint40(block.timestamp + 1 hours);
        vm.expectEmit(address(cards));
        emit CardLimits.CardExpirySet(CARD, expiry);
        vm.prank(issuer);
        cards.setCard(CARD, 1, expiry);
        assertEq(cards.cardOf(CARD).expiry, expiry);
        vm.prank(issuer);
        cards.authorize(CARD, bytes32("p1"), 10e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.warp(expiry);
        vm.prank(issuer);
        vm.expectRevert(CardLimits.CardExpired.selector);
        cards.authorize(CARD, bytes32("p2"), 10e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_setExpiry_onlyIssuer() public {
        vm.prank(alice);
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
        cards.setCard(CARD, 1, uint40(block.timestamp + 10 days));
    }
}
