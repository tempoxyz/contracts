// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";

import { CardAuthBase } from "../../../src/spend/programs/CardAuthBase.sol";
import { IssuerTreasury } from "../../../src/spend/programs/IssuerTreasury.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice The issuer treasury, as the program's exposure guard, hands the guard on: the sponsor at any time, the
///         issuer only once the sponsor holds no live collateral or seizure and is owed nothing or has not acted for
///         SPONSOR_SILENCE.
contract IssuerTreasuryGuardHandOffTest is AuthEnv {
    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");
    address internal next = makeAddr("next-guard");
    bytes32 internal constant P1 = bytes32("guard-1");

    function setUp() public {
        _deployPrograms();
        usd.mint(alice, 1000e6);
        _issue(alice, _limits(5000e6, 50_000e6, 500_000e6));
        treasury = new IssuerTreasury(cards);
        usd.mint(settlement, 100e6);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(
            address(treasury), address(usd), id, 100e6, uint64(block.timestamp + treasury.COVER_TERM() + 3 days)
        );
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
    }

    function test_handOffGuard_sponsorHandsOffWhileExposedAndTheNextGuardControls() public {
        _authorize(P1, 90e6);
        _capture(P1, 90e6, true);
        assertEq(treasury.exposure(), 90e6);
        vm.prank(sponsor);
        treasury.handOffGuard(next);
        assertEq(cards.exposureGuard(), next);
        // The treasury no longer has a say, and the issuer still has none.
        vm.prank(sponsor);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        treasury.handOffGuard(address(0));
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.setExposureGuard(address(0));
        // The next guard acknowledges the settlement and clears itself.
        (uint64 seq,,,) = cards.ledger();
        vm.startPrank(next);
        cards.acknowledgeSettlement(seq);
        cards.setExposureGuard(address(0));
        vm.stopPrank();
        assertEq(cards.exposureGuard(), address(0));
    }

    function test_handOffGuard_issuerRefusedWhileCollateralIsLive() public {
        assertGt(treasury.unitsOf(), 0);
        assertEq(treasury.stressedExposure(), 0);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.GuardInUse.selector);
        treasury.handOffGuard(address(0));
        assertEq(cards.exposureGuard(), address(treasury));
    }

    function test_handOffGuard_issuerRefusedWhileExposed() public {
        _authorize(P1, 90e6);
        _capture(P1, 90e6, true);
        _lapse();
        assertEq(treasury.exposure(), 90e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.GuardInUse.selector);
        treasury.handOffGuard(address(0));
        assertEq(cards.exposureGuard(), address(treasury));
    }

    function test_handOffGuard_issuerRefusedWhileASeizureIsOutstanding() public {
        _authorize(P1, 80e6);
        vm.prank(sponsor);
        treasury.seize(80e6);
        vm.prank(issuer);
        cards.release(P1);
        _lapse();
        assertEq(treasury.stressedExposure(), 0);
        assertEq(treasury.seized(), 80e6);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.GuardInUse.selector);
        treasury.handOffGuard(address(0));
        assertEq(cards.exposureGuard(), address(treasury));
    }

    function test_handOffGuard_issuerHandsOffOnceNothingIsOwedOrLive() public {
        _authorize(P1, 90e6);
        _capture(P1, 90e6, true);
        (uint64 seq,,,) = cards.ledger();
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(seq, 0);
        _lapse();
        assertEq(treasury.stressedExposure(), 0);
        assertEq(treasury.seized(), 0);
        vm.prank(issuer);
        treasury.handOffGuard(next);
        assertEq(cards.exposureGuard(), next);
        // Only the next guard changes it now.
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.setExposureGuard(address(0));
        vm.prank(next);
        cards.setExposureGuard(address(0));
        assertEq(cards.exposureGuard(), address(0));
    }

    function test_handOffGuard_issuerHandsOffBeforeASponsorIsNamed() public {
        _authorize(P1, 10e6);
        IssuerTreasury fresh = new IssuerTreasury(cards);
        vm.prank(sponsor);
        treasury.handOffGuard(address(fresh));
        // No sponsor is owed through the fresh treasury, so the issuer, which acknowledges for it, may hand off.
        assertEq(fresh.exposure(), 10e6);
        vm.prank(issuer);
        fresh.handOffGuard(address(0));
        assertEq(cards.exposureGuard(), address(0));
    }

    function test_handOffGuard_refusesAnyoneElse() public {
        vm.prank(makeAddr("anyone"));
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.handOffGuard(address(0));
        vm.prank(settlement);
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.handOffGuard(address(0));
    }

    // A sponsor that stops acting.

    /// @dev A sponsor silent for SPONSOR_SILENCE, with no collateral live and nothing seized, no longer holds the
    ///      program: the issuer hands the guard off, acknowledges the settlement itself and frees its own funds.
    function test_handOffGuard_issuerHandsOffOnceTheSponsorFellSilent() public {
        _authorize(P1, 60e6);
        _capture(P1, 60e6, true);
        vm.prank(settlement);
        usd.transfer(makeAddr("network"), 60e6);
        usd.mint(issuer, 100e6);
        vm.startPrank(issuer);
        usd.approve(address(treasury), 100e6);
        treasury.fundIssuerDebt(address(usd), 100e6);
        vm.stopPrank();
        assertEq(treasury.committedIssuerFunds(address(usd)), 60e6);
        (,,,, uint64 seenAt) = treasury.collateral();
        uint256 silentFrom = seenAt + treasury.SPONSOR_SILENCE();
        vm.warp(silentFrom - 1);
        assertEq(treasury.unitsOf(), 0);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.GuardInUse.selector);
        treasury.handOffGuard(address(0));
        vm.warp(silentFrom);
        vm.prank(issuer);
        treasury.handOffGuard(address(0));
        assertEq(cards.exposureGuard(), address(0));
        (uint64 seq,,,) = cards.ledger();
        vm.prank(issuer);
        cards.acknowledgeSettlement(seq);
        assertEq(treasury.exposure(), 0);
        assertEq(treasury.committedIssuerFunds(address(usd)), 0);
        vm.prank(issuer);
        treasury.withdrawIssuerFunds(address(usd), 100e6);
        _authorize(bytes32("guard-2"), 1e6);
    }

    function test_handOffGuard_aSponsorThatActsKeepsTheGuard() public {
        _authorize(P1, 60e6);
        _capture(P1, 60e6, true);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 170 days);
        vm.prank(sponsor);
        treasury.checkpointSettlement();
        vm.warp(start + treasury.SPONSOR_SILENCE() + 1 days);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.GuardInUse.selector);
        treasury.handOffGuard(address(0));
        vm.warp(start + 170 days + treasury.SPONSOR_SILENCE());
        vm.prank(issuer);
        treasury.handOffGuard(address(0));
        assertEq(cards.exposureGuard(), address(0));
    }

    function test_handOffGuard_silenceLeavesLiveCollateralAndSeizuresWithTheSponsor() public {
        _authorize(P1, 80e6);
        vm.prank(sponsor);
        treasury.seize(50e6);
        vm.warp(block.timestamp + treasury.SPONSOR_SILENCE());
        assertEq(treasury.unitsOf(), 0);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.GuardInUse.selector);
        treasury.handOffGuard(address(0));
        // Collateral the settlement account pledges again keeps it with the sponsor too.
        IssuerTreasury other = new IssuerTreasury(cards);
        vm.prank(sponsor);
        treasury.handOffGuard(address(other));
        usd.mint(settlement, 100e6);
        bytes32 id = other.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(other), address(usd), id, 100e6, uint64(block.timestamp + 365 days));
        other.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        vm.warp(block.timestamp + other.SPONSOR_SILENCE());
        assertGt(other.unitsOf(), 0);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.GuardInUse.selector);
        other.handOffGuard(address(0));
    }

    /// @dev Ends the collateral pledge: the sponsor had COVER_TERM to seize before it.
    function _lapse() internal {
        vm.warp(block.timestamp + treasury.COVER_TERM() + 3 days);
        assertEq(treasury.unitsOf(), 0);
    }
}
