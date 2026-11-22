// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { CardAuth } from "../../../src/spend/programs/CardAuth.sol";
import { CardAuthAdmin } from "../../../src/spend/programs/CardAuthAdmin.sol";
import { CardAuthBase } from "../../../src/spend/programs/CardAuthBase.sol";
import { CardLegs } from "../../../src/spend/programs/CardLegs.sol";
import { CardLimits } from "../../../src/spend/programs/CardLimits.sol";
import { CashSource } from "../../../src/spend/programs/CashSource.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice CardAuthAdmin is deployed once and named by each CardAuth: a program accepts only exactly its code, and one
///         instance serves programs with different issuers and settlement accounts without mixing them.
contract CardAuthAdminTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");

    address internal issuer2 = makeAddr("issuer2");
    address internal settlement2 = makeAddr("issuer2.settlement");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
    }

    function test_constructor_refusesAdminWithOtherCode() public {
        address[5] memory others = [address(0), makeAddr("eoa"), address(cash), address(cards), address(usd)];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(CardAuth.InvalidAdmin.selector);
            new CardAuth(issuer, settlement, address(usd), others[i]);
        }
    }

    function test_constructor_refusesAdminWithAnyChangedByte() public {
        bytes memory code = address(admin).code;
        code[code.length / 2] ^= 0x01;
        address altered = makeAddr("altered-admin");
        vm.etch(altered, code);
        vm.expectRevert(CardAuth.InvalidAdmin.selector);
        new CardAuth(issuer, settlement, address(usd), altered);
    }

    function test_constructor_acceptsAnyCardAuthAdminDeployment() public {
        CardAuthAdmin another = new CardAuthAdmin();
        assertEq(address(another).codehash, address(admin).codehash);
        CardAuth program = new CardAuth(issuer, settlement, address(usd), address(another));
        assertEq(program.ADMIN(), address(another));
    }

    function test_oneAdmin_servesTwoPrograms_settlementAccountsStayApart() public {
        CardAuth cards2 = new CardAuth(issuer2, settlement2, address(usd), address(admin));
        CashSource cash2 = new CashSource(cards2);
        assertEq(cards2.ADMIN(), cards.ADMIN());
        assertEq(cards.SETTLEMENT_ACCOUNT(), settlement);
        assertEq(cards2.SETTLEMENT_ACCOUNT(), settlement2);
        assertEq(cash.SETTLEMENT_ACCOUNT(), settlement);
        assertEq(cash2.SETTLEMENT_ACCOUNT(), settlement2);

        // Each program's issuer runs the shared settings code over its own program only.
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
        cards2.setSource(address(cash2), true);
        vm.startPrank(issuer2);
        cards2.setSource(address(cash2), true);
        cards2.issueCard(CARD, bob, uint40(block.timestamp + 365 days), _limits(500e6, 1000e6, 5000e6), 7);
        vm.stopPrank();
        assertEq(cards2.sourceKind(address(cash)), 0);
        assertEq(cards.sourceKind(address(cash2)), 0);
        assertEq(cards.cardOf(CARD).owner, alice);
        assertEq(cards2.cardOf(CARD).owner, bob);

        vm.startPrank(bob);
        core.approveHolder(address(cash2), address(usd), type(uint128).max, 0);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = CardLegs.Funding(cash2, _position(address(usd), 0));
        cards2.setFunding(order);
        cards2.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        vm.stopPrank();
        assertEq(cards.grantedOwners(), 1);
        assertEq(cards2.grantedOwners(), 1);

        usd.mint(alice, 1000e6);
        usd.mint(bob, 1000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        vm.startPrank(issuer2);
        cards2.authorize(CARD, P2, 30e6, merchant, uint64(block.timestamp + 7 days), 0);
        cards2.capture(P2, 30e6, true);
        vm.stopPrank();

        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(usd.balanceOf(settlement2), 30e6);
        assertEq(usd.balanceOf(alice), 900e6);
        assertEq(usd.balanceOf(bob), 970e6);
        assertEq(cards.purchaseOf(P2).owner, address(0));
        assertEq(cards2.purchaseOf(P1).owner, address(0));
        // The shared code keeps nothing of its own: its storage stays empty.
        assertEq(vm.load(address(admin), bytes32(uint256(0))), bytes32(0));
        _assertCoreBalanced();
    }
}
