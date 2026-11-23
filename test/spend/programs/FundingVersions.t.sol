// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardAuthBase } from "../../../src/spend/programs/CardAuthBase.sol";
import { CardLegs } from "../../../src/spend/programs/CardLegs.sol";
import { Conversion } from "../../../src/spend/programs/Conversion.sol";
import { ICardAuth } from "../../../src/interfaces/spend/programs/ICardAuth.sol";
import { FixedPricePool } from "./venues/FixedPricePool.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";
import { Rates } from "./harness/Rates.sol";

/// @notice Every purchase keeps the funding order it was placed under, however many times its owner changes the
///         order: each version is written once, an ended purchase records its whole version, and an open one its low
///         8 bits. Open purchases are counted by their window of 128 versions, and setFunding refuses to start a window
///         while a purchase from the one two back is open, so an open purchase stays within 256 of the latest.
contract FundingVersionsTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
        usd.mint(alice, 1000e6);
    }

    function test_setFunding_refusedBeforeAnOpenPurchasesVersionRepeats() public {
        _authorize(P1, 100e6);
        (uint32 placedAt,,) = cards.fundingState(alice);
        // Versions move freely to the end of the window after the purchase's own, at least 128 past it.
        uint32 lastAllowed = _lastAllowed(placedAt);
        assertGe(lastAllowed - placedAt, 128);
        _changeFunding(lastAllowed - placedAt, new CardLegs.Funding[](0));
        (uint32 latest, uint32 openEven, uint32 openOdd) = cards.fundingState(alice);
        assertEq(latest, lastAllowed);
        assertEq(openEven + openOdd, 1);
        assertEq(placedAt >> 7 & 1 == 0 ? openEven : openOdd, 1, "counted in its own window");
        vm.prank(alice);
        vm.expectRevert(CardAuthBase.FundingInUse.selector);
        cards.setFunding(new CardLegs.Funding[](0));

        // The capture still walks the order the purchase was placed under and takes alice's hold.
        _capture(P1, 100e6, true);
        ICardAuth.PurchaseView memory p = cards.purchaseOf(P1);
        assertEq(p.refunded, 0, "the cash hold covered it");
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(core.available(alice, address(usd)), 900e6);
        _assertCoreBalanced();
        // With nothing open, versions move on freely.
        (, openEven, openOdd) = cards.fundingState(alice);
        assertEq(openEven + openOdd, 0);
        _changeFunding(300, new CardLegs.Funding[](0));
    }

    /// @dev The widest gap the windows allow: a purchase placed at a window's first version while the latest is 255
    ///      past it, the last version of the next window. It still resolves its own order, and the next change waits.
    function test_openPurchase_resolvesItsVersionAtTheWidestGap() public {
        (uint32 v,,) = cards.fundingState(alice);
        _changeFunding(256 - v - 1, new CardLegs.Funding[](0));
        _changeFunding(1, _cashOnly());
        (uint32 placedAt,,) = cards.fundingState(alice);
        assertEq(placedAt, 256);
        _authorize(P1, 100e6);
        _changeFunding(255, new CardLegs.Funding[](0));
        (uint32 latest,,) = cards.fundingState(alice);
        assertEq(latest, placedAt + 255);
        vm.prank(alice);
        vm.expectRevert(CardAuthBase.FundingInUse.selector);
        cards.setFunding(new CardLegs.Funding[](0));
        (address[] memory sources,,) = cards.legsOf(P1);
        assertEq(sources.length, 1);
        assertEq(sources[0], address(cash));
        _capture(P1, 100e6, true);
        assertEq(cards.purchaseOf(P1).refunded, 0, "the cash hold covered it");
        assertEq(usd.balanceOf(settlement), 100e6);
        _assertCoreBalanced();
        _changeFunding(1, new CardLegs.Funding[](0));
    }

    /// @dev A busy card whose purchases always overlap (each authorized before the last one ends) never waits on
    ///      setFunding, however many times its owner changes the order: only a purchase two windows old holds it.
    function test_setFunding_overlappingPurchasesNeverHoldItBack() public {
        CardLegs.Funding[] memory order = _cashOnly();
        _authorize(_ref(0), 1e6);
        for (uint256 i = 1; i <= 260; ++i) {
            vm.prank(alice);
            cards.setFunding(order);
            _authorize(_ref(i), 1e6);
            vm.prank(issuer);
            cards.release(_ref(i - 1));
        }
        (uint32 latest, uint32 openEven, uint32 openOdd) = cards.fundingState(alice);
        assertEq(openEven + openOdd, 1, "only the newest purchase is open");
        assertEq(latest >> 7 & 1 == 0 ? openEven : openOdd, 1);
        // The newest purchase still resolves the order it was placed under and captures from it.
        assertGt(latest, 256, "past two window boundaries");
        _capture(_ref(260), 1e6, true);
        assertEq(cards.purchaseOf(_ref(260)).refunded, 0);
        _assertCoreBalanced();
    }

    /// @dev A long-open purchase holds setFunding back only until it ends, whatever newer purchases stay open.
    function test_setFunding_heldBackOnlyByTheOldestWindow() public {
        _authorize(P1, 1e6);
        (uint32 placedAt,,) = cards.fundingState(alice);
        _changeFunding(_lastAllowed(placedAt) - placedAt - 1, _cashOnly());
        _authorize(P2, 1e6);
        _changeFunding(1, new CardLegs.Funding[](0));
        vm.prank(alice);
        vm.expectRevert(CardAuthBase.FundingInUse.selector);
        cards.setFunding(new CardLegs.Funding[](0));
        vm.prank(issuer);
        cards.release(P1);
        // P2, placed in the window just before the new one, does not hold it back.
        _changeFunding(1, new CardLegs.Funding[](0));
        (, uint32 openEven, uint32 openOdd) = cards.fundingState(alice);
        assertEq(openEven + openOdd, 1);
    }

    function test_openPurchase_resolvesItsVersionAcrossTheEightBitBoundary() public {
        _changeFunding(249, new CardLegs.Funding[](0));
        _changeFunding(1, _cashOnly());
        _authorize(P1, 100e6);
        _changeFunding(100, new CardLegs.Funding[](0));
        (address[] memory sources,,) = cards.legsOf(P1);
        assertEq(sources.length, 1);
        assertEq(sources[0], address(cash));
        // An increment and the capture both draw on the order it was placed under, not today's empty one.
        vm.prank(issuer);
        cards.adjust(P1, 150e6);
        _capture(P1, 150e6, true);
        assertEq(cards.purchaseOf(P1).refunded, 0);
        assertEq(usd.balanceOf(settlement), 150e6);
    }

    function test_endedPurchase_keepsItsOrderPastAnyNumberOfVersions() public {
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        _authorize(P2, 10e6);
        vm.prank(issuer);
        cards.release(P2);
        _changeFunding(300, new CardLegs.Funding[](0));

        // A refund goes back to the cash leg the purchase drew on.
        usd.mint(issuer, 40e6);
        vm.startPrank(issuer);
        usd.approve(address(cards), 40e6);
        cards.refund(P1, 40e6);
        vm.stopPrank();
        assertEq(usd.balanceOf(alice), 940e6);
        // A late booking on the ended purchase draws on its own order's cash entry.
        vm.prank(issuer);
        cards.bookStandIn(CARD, P2, 50e6, merchant);
        assertEq(cards.purchaseOf(P2).refunded, 0, "free cash covered it");
        assertEq(usd.balanceOf(alice), 890e6);
        _assertCoreBalanced();
    }

    /// @dev The last version setFunding reaches while a purchase placed at `placedAt` is open: the end of the next window.
    function _lastAllowed(uint32 placedAt) internal pure returns (uint32) {
        return ((placedAt >> 7) + 2 << 7) - 1;
    }

    function _ref(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("purchase", i));
    }

    function _changeFunding(uint256 times, CardLegs.Funding[] memory order) internal {
        vm.startPrank(alice);
        for (uint256 i; i < times; ++i) {
            cards.setFunding(order);
        }
        vm.stopPrank();
    }

    function _cashOnly() internal view returns (CardLegs.Funding[] memory order) {
        order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(usd), 0);
    }
}

/// @notice An open converted leg is released in the token it was placed in, however the owner changes the order.
contract FundingVersionsConvertedTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");

    ITIP20Token internal eur;

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
        eur = _createToken("Euro", "EURX");
        Conversion conv = new Conversion(address(usd), address(this));
        FixedPricePool bid = new FixedPricePool(address(eur), address(usd), 1.0967e18);
        FixedPricePool ask = new FixedPricePool(address(eur), address(usd), 1_103_310_000_000_000_000);
        usd.mint(address(bid), 1_000_000e6);
        eur.mint(address(ask), 1_000_000e6);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(eur), address(ask), false);
        Rates.set(conv, address(eur), 1.1e18);
        conv.setTrusted(address(cash), true);
        usd.mint(address(conv), 100_000e6);
        eur.mint(address(conv), 100_000e6);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(0), address(0), address(conv))));
        vm.startPrank(alice);
        core.approveHolder(address(cash), address(eur), type(uint128).max, 0);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(eur), 100);
        cards.setFunding(order);
        vm.stopPrank();
        eur.mint(alice, 1000e6);
    }

    function test_openConvertedLeg_releasesInItsOwnToken() public {
        (uint32 placedAt,,) = cards.fundingState(alice);
        _authorize(P1, 100e6);
        assertGt(cash.openConvertedOf(address(eur)), 99e6);
        // The owner changes the order as often as allowed (to the end of the window after the purchase's), ending on
        // dollars at the leg's entry; the next change is refused while the purchase is open.
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(usd), 0);
        uint256 changes = ((placedAt >> 7) + 2 << 7) - 1 - placedAt;
        assertGe(changes, 128);
        vm.startPrank(alice);
        for (uint256 i; i < changes - 1; ++i) {
            cards.setFunding(new CardLegs.Funding[](0));
        }
        cards.setFunding(order);
        vm.expectRevert(CardAuthBase.FundingInUse.selector);
        cards.setFunding(order);
        vm.stopPrank();

        // The hold expires and the core ends it; the release still names the euro position.
        vm.warp(block.timestamp + 8 days);
        core.releaseExpired(alice, address(cash), cards.legId(P1, 0));
        cards.release(P1);
        (uint256 held,) = cards.exposure();
        assertEq(held, 0);
        assertEq(cash.openConvertedOf(address(eur)), 0, "euro total cleared");
        assertEq(cash.openConvertedOf(address(usd)), 0);
        vm.prank(alice);
        cards.setFunding(order);
    }

    /// @dev A refund after the owner moved to dollars at the leg's entry, past any number of versions, pays back the
    ///      euros the capture took and no dollars.
    function test_endedConvertedLeg_refundsInItsOwnToken() public {
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        uint256 spent = 1000e6 - eur.balanceOf(alice);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(usd), 0);
        vm.startPrank(alice);
        for (uint256 i; i < 300; ++i) {
            cards.setFunding(new CardLegs.Funding[](0));
        }
        cards.setFunding(order);
        vm.stopPrank();

        uint256 dollars = usd.balanceOf(alice);
        usd.mint(issuer, 50e6);
        vm.startPrank(issuer);
        usd.approve(address(cards), 50e6);
        cards.refund(P1, 50e6);
        vm.stopPrank();
        assertEq(eur.balanceOf(alice), 1000e6 - spent + spent / 2, "half the euros come back");
        assertEq(usd.balanceOf(alice), dollars, "no dollars");
        assertEq(cash.openConverted(), 0);
        _assertCoreBalanced();
    }
}
