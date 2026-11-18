// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { IssuerTreasury } from "../../src/programs/IssuerTreasury.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice The exposure guard: once the issuer registers its treasury as CardAuth's guard, no authorization, increase
///         or charge may take the program's exposure (open holds plus unsettled captures) past the sponsor collateral.
contract ExposureGuardTest is AuthEnv {
    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");
    bytes32 internal constant P1 = bytes32("guard-1");
    bytes32 internal constant P2 = bytes32("guard-2");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 1000e6);
        treasury = new IssuerTreasury(cards);
        _postCash(100e6);
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
    }

    function test_exposure_overCollateral_refused() public {
        _authorize(P1, 80e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 110e6, 100e6));
        cards.authorize(CARD, P2, 30e6, merchant, uint64(block.timestamp + 1 days), 0);
        // An increment past the collateral is refused too.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 130e6, 100e6));
        cards.adjust(P1, 130e6);
        // Up to the collateral is fine.
        vm.prank(issuer);
        cards.adjust(P1, 100e6);
    }

    function test_exposure_forcePostOverCollateral_refused() public {
        _authorize(P1, 60e6);
        _capture(P1, 60e6, true);
        // Captured but unacknowledged counts as exposure, so a force post of 50 would reach 110.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 110e6, 100e6));
        cards.charge(CARD, P2, 50e6, merchant);
        // Once the issuer acknowledges settlement, the exposure drops and the post goes through.
        (uint64 seq,,,) = cards.ledger();
        vm.prank(issuer);
        cards.acknowledgeSettlement(seq);
        vm.prank(issuer);
        cards.charge(CARD, P2, 50e6, merchant);
    }

    function test_exposure_expiredCollateral_refusesNewExposure() public {
        _authorize(P1, 100e6);
        // The collateral expires, so the program is past it and nothing may add to the exposure.
        vm.warp(block.timestamp + 4 days);
        assertEq(treasury.valueOf(), 0);
        vm.startPrank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 101e6, 0));
        cards.authorize(CARD, P2, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();
    }

    function test_exposure_decreaseAndCaptureWhilePastCollateral() public {
        _authorize(P1, 100e6);
        // The collateral expires; the purchase can still shrink and capture.
        vm.warp(block.timestamp + 4 days);
        vm.startPrank(issuer);
        cards.adjust(P1, 50e6);
        cards.capture(P1, 50e6, true);
        vm.stopPrank();
        assertEq(cards.purchaseOf(P1).captured, 50e6);
    }

    function test_setExposureGuard_waitsTheDelayAndZeroTurnsItOff() public {
        bytes memory off = abi.encodeCall(cards.setExposureGuard, (address(0)));
        vm.prank(issuer);
        cards.setExposureGuard(address(0));
        assertEq(cards.exposureGuard(), address(treasury), "removal waits too");
        vm.prank(alice);
        vm.expectRevert(CardAuth.NotIssuer.selector);
        cards.setExposureGuard(address(0));
        vm.warp(cards.pendingSetting(keccak256(off)));
        vm.prank(issuer);
        cards.setExposureGuard(address(0));
        assertEq(cards.exposureGuard(), address(0));
        _authorize(P1, 500e6);
    }

    function test_noGuard_noCheck() public {
        _setting(abi.encodeCall(cards.setExposureGuard, (address(0))));
        _authorize(P1, 400e6);
        vm.prank(issuer);
        cards.charge(CARD, P2, 100e6, merchant);
    }

    /// @dev The settlement account pledges `amount` of usd to the treasury as the sponsor's collateral.
    function _postCash(uint128 amount) internal {
        usd.mint(settlement, amount);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), id, amount, uint64(block.timestamp + 3 days));
        treasury.post(sponsor, IEarnVault(address(0)));
        vm.stopPrank();
    }
}
