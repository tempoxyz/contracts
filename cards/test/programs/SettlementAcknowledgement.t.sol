// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { CardAuthBase } from "../../src/programs/CardAuthBase.sol";
import { IssuerTreasury } from "../../src/programs/IssuerTreasury.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice With an exposure guard set, only the guard acknowledges settlement, and the treasury lets only the sponsor
///         that is owed it do so: the issuer cannot clear the exposure the guard and the sponsor's seizures read.
contract SettlementAcknowledgementTest is AuthEnv {
    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 1000e6);
        treasury = new IssuerTreasury(cards);
        usd.mint(settlement, 100e6);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), id, 100e6, uint64(block.timestamp + 365 days));
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
    }

    function test_acknowledgeSettlement_issuerCannotClearExposurePastCollateral() public {
        _authorize("p-0", 100e6);
        _capture("p-0", 100e6, true);
        (uint64 seq,,,) = cards.ledger();
        // Neither directly nor through the treasury.
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.Unauthorized.selector);
        cards.acknowledgeSettlement(seq);
        vm.prank(issuer);
        vm.expectRevert(IssuerTreasury.NotSponsor.selector);
        treasury.acknowledgeSettlement(seq, 0);
        assertEq(treasury.exposure(), 100e6);
        // So the guard refuses a second purchase past the collateral.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 200e6, 100e6));
        cards.authorize(CARD, "p-1", 100e6, merchant, uint64(block.timestamp + 1 days), 0);
        // And the sponsor can still seize against the unpaid 100.
        vm.prank(sponsor);
        treasury.seize(100e6);
        assertEq(usd.balanceOf(sponsor), 100e6);
    }

    function test_acknowledgeSettlement_sponsorClearsWhatWasPaid() public {
        _authorize("p-0", 100e6);
        _capture("p-0", 100e6, true);
        (uint64 seq,,,) = cards.ledger();
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(seq, 0);
        assertEq(treasury.exposure(), 0);
        _authorize("p-1", 100e6);
        _capture("p-1", 100e6, true);
        assertEq(treasury.exposure(), 100e6);
    }
}
