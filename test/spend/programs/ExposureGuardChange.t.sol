// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";

import { CardAuthBase } from "../../../src/spend/programs/CardAuthBase.sol";
import { IssuerTreasury } from "../../../src/spend/programs/IssuerTreasury.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice Once the issuer sets an exposure guard, only that guard replaces or clears it, so the issuer can never take
///         back acknowledging the settlement the guard's party is owed.
contract ExposureGuardChangeTest is AuthEnv {
    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");

    function setUp() public {
        _deployPrograms();
        usd.mint(alice, 1000e6);
        _issue(alice, _limits(5000e6, 50_000e6, 500_000e6));
        treasury = new IssuerTreasury(cards);
        _postCash(100e6);
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
    }

    function test_issuerCannotClearOrReplaceTheGuard_evenAfterTheDelay() public {
        _authorize(bytes32("p1"), 90e6);
        _capture(bytes32("p1"), 90e6, true);
        assertEq(treasury.exposure(), 90e6);
        // Neither clearing nor replacing records a proposal the delay could ripen.
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.setExposureGuard(address(0));
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.setExposureGuard(issuer);
        vm.warp(block.timestamp + cards.SETTINGS_DELAY() + 1);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.setExposureGuard(address(0));
        assertEq(cards.exposureGuard(), address(treasury));
        // The issuer still cannot acknowledge, and the sponsor's exposure and seize bound stand.
        (uint64 seq,,,) = cards.ledger();
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.acknowledgeSettlement(seq);
        assertEq(treasury.exposure(), 90e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 990e6, 100e6));
        cards.authorize(CARD, bytes32("p2"), 900e6, merchant, uint64(block.timestamp + 1 days), 0);
    }

    function test_guardReplacesOrClearsItselfAtOnce() public {
        address next = makeAddr("next-guard");
        vm.prank(address(treasury));
        cards.setExposureGuard(next);
        assertEq(cards.exposureGuard(), next);
        // The previous guard has no say any more.
        vm.prank(address(treasury));
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.setExposureGuard(address(0));
        vm.prank(next);
        cards.setExposureGuard(address(0));
        assertEq(cards.exposureGuard(), address(0));
        // With none set, the issuer sets one again behind the settings delay.
        bytes memory data = abi.encodeCall(cards.setExposureGuard, (address(treasury)));
        vm.prank(issuer);
        cards.setExposureGuard(address(treasury));
        assertEq(cards.exposureGuard(), address(0), "waits the delay");
        vm.warp(cards.pendingSetting(keccak256(data)));
        vm.prank(issuer);
        cards.setExposureGuard(address(treasury));
        assertEq(cards.exposureGuard(), address(treasury));
    }

    function _postCash(uint128 amount) internal {
        usd.mint(settlement, amount);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(
            address(treasury), address(usd), id, amount, uint64(block.timestamp + treasury.COVER_TERM() + 3 days)
        );
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
    }
}
