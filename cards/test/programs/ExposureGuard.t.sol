// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardAuthBase } from "../../src/programs/CardAuthBase.sol";
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
        // Once the sponsor, which is owed it, acknowledges settlement through the treasury, the exposure drops and the
        // post goes through.
        (uint64 seq,,,) = cards.ledger();
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(seq, 0);
        vm.prank(issuer);
        cards.charge(CARD, P2, 50e6, merchant);
    }

    /// @dev The sponsor checkpoints at the network's cut-off and acknowledges through it once the network paid, while
    ///      captures continue: exactly the net through the cut-off stops counting, and the later net still counts.
    function test_exposure_acknowledgedThroughACheckpoint_clearsOnlyTheNetThrough() public {
        _authorize(P1, 60e6);
        _capture(P1, 60e6, true);
        // Only the sponsor records, through the treasury; neither the issuer nor its settle operator can.
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.checkpointSettlement();
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.checkpointSettlement();
        vm.prank(sponsor);
        uint64 cutoff = treasury.checkpointSettlement();
        _authorize(P2, 30e6);
        _capture(P2, 30e6, true);
        assertEq(treasury.exposure(), 90e6);
        // The issuer still cannot clear exposure alone.
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.acknowledgeSettlement(cutoff, 0);
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(cutoff, 0);
        assertEq(treasury.exposure(), 30e6, "the capture after the cut-off still counts");
        // So 70 more fits under the collateral, and 71 does not.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 101e6, 100e6));
        cards.charge(CARD, bytes32("guard-3"), 71e6, merchant);
        vm.prank(issuer);
        cards.charge(CARD, bytes32("guard-3"), 70e6, merchant);
    }

    /// @dev What the sponsor seized applies to a partial acknowledgement only up to the net it clears.
    function test_exposure_partialAcknowledgement_appliesAtMostWhatItClears() public {
        _authorize(P1, 60e6);
        _capture(P1, 60e6, true);
        vm.prank(sponsor);
        uint64 cutoff = treasury.checkpointSettlement();
        _authorize(P2, 30e6);
        _capture(P2, 30e6, true);
        vm.prank(sponsor);
        treasury.seize(90e6);
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.AboveExposure.selector, uint256(61e6), uint256(60e6)));
        treasury.acknowledgeSettlement(cutoff, 61e6);
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(cutoff, 60e6);
        assertEq(treasury.seized(), 30e6);
    }

    function test_exposure_expiredCollateral_refusesNewExposure() public {
        _authorize(P1, 100e6);
        // The collateral stops covering, so the program is past it and nothing may add to the exposure.
        vm.warp(block.timestamp + 4 days);
        assertEq(treasury.valueOf(), 0);
        vm.startPrank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 101e6, 0));
        cards.authorize(CARD, P2, 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.stopPrank();
    }

    function test_exposure_decreaseAndCaptureWhilePastCollateral() public {
        _authorize(P1, 100e6);
        // The collateral stops covering; the purchase can still shrink and capture.
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
        vm.expectRevert(CardAuthBase.NotIssuer.selector);
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
        // It covers exposure for 3 days: until COVER_TERM before it expires.
        core.pledge(
            address(treasury), address(usd), id, amount, uint64(block.timestamp + treasury.COVER_TERM() + 3 days)
        );
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
    }
}
