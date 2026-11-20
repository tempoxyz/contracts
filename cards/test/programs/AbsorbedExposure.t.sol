// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

import { IssuerTreasury } from "../../src/programs/IssuerTreasury.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice What the issuer absorbs (captured or charged past what the owner's sources cover) is owed to the network
///         like any capture, so it counts toward settlement and the program's exposure: the guard bounds it, the
///         sponsor can seize against it, and acknowledging settlement clears it.
contract AbsorbedExposureTest is AuthEnv {
    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 50_000e6, 500_000e6));
        // alice holds nothing and has no debt terms, so the issuer absorbs whatever is charged to her.
        treasury = new IssuerTreasury(cards);
        _postCash(100e6);
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
    }

    function test_forcePostOnEmptyCard_countsAsExposureAndIsBoundedByTheGuard() public {
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 1000e6, 100e6));
        cards.charge(CARD, bytes32("fp-big"), 1000e6, merchant);
        vm.prank(issuer);
        cards.charge(CARD, bytes32("fp-1"), 60e6, merchant);
        assertEq(usd.balanceOf(settlement), 0, "nothing was covered");
        (uint256 held,, uint256 unsettled) = cards.exposure();
        assertEq(held, 0);
        assertEq(unsettled, 60e6);
        assertEq(treasury.exposure(), 60e6);
        // A second post past the collateral is refused.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 110e6, 100e6));
        cards.charge(CARD, bytes32("fp-2"), 50e6, merchant);
        // The sponsor, owed what it fronted, can seize against it.
        uint256 before = usd.balanceOf(sponsor);
        vm.prank(sponsor);
        treasury.seize(60e6);
        assertEq(usd.balanceOf(sponsor) - before, 60e6);
    }

    function test_capturedStandInOnEmptyCard_keepsCountingUntilAcknowledged() public {
        uint8 si = cards.STAND_IN();
        vm.prank(issuer);
        cards.authorize(CARD, bytes32("si-1"), 100e6, merchant, uint64(block.timestamp + 1 days), si);
        assertEq(treasury.exposure(), 100e6);
        vm.prank(issuer);
        cards.capture(bytes32("si-1"), 100e6, true);
        assertEq(treasury.exposure(), 100e6, "absorbed capture still owed to the network");
        // The next stand-in is refused while the first is unsettled.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 101e6, 100e6));
        cards.authorize(CARD, bytes32("si-2"), 1e6, merchant, uint64(block.timestamp + 1 days), si);
        // Once the sponsor acknowledges settlement, the absorbed amount clears like any captured net.
        (uint64 seq,,,) = cards.ledger();
        vm.prank(sponsor);
        treasury.acknowledgeSettlement(seq, 0);
        assertEq(treasury.exposure(), 0);
        vm.prank(issuer);
        cards.authorize(CARD, bytes32("si-2"), 1e6, merchant, uint64(block.timestamp + 1 days), si);
    }

    function test_captureOverageOnEmptyCard_isCheckedByTheGuard() public {
        usd.mint(alice, 80e6);
        _setTolerance(alice, address(cash), address(usd), 5000);
        _authorize(bytes32("tip"), 80e6);
        // 80 held and up to 40 of tolerance, all of it past the hold absorbed: 120 against 100 is refused.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 120e6, 100e6));
        cards.capture(bytes32("tip"), 120e6, true);
        vm.prank(issuer);
        cards.capture(bytes32("tip"), 95e6, true);
        assertEq(usd.balanceOf(settlement), 80e6);
        (,, int128 net,) = cards.ledger();
        assertEq(net, 95e6, "the absorbed 15 counts with the covered 80");
        assertEq(treasury.exposure(), 95e6);
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
