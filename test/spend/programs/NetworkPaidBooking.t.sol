// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "../../../src/interfaces/earn/IEarnVault.sol";
import { CardLimits } from "../../../src/spend/programs/CardLimits.sol";
import { IssuerTreasury } from "../../../src/spend/programs/IssuerTreasury.sol";
import { ICardAuth } from "../../../src/interfaces/spend/programs/ICardAuth.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";

/// @notice What the network already paid (a stand-in once it clears, a late charge, a tip past the hold) is always
///         booked, so it enters the settlement net and the exposure the sponsor's collateral backs: neither the
///         exposure guard nor the card's or account's state nor the grant refuses it, only the operator's cap. The
///         owner's free cash pays what it can, except for a merchant the owner revoked, which the issuer absorbs.
contract NetworkPaidBookingTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    address internal sponsor = makeAddr("sponsor");
    address internal other = makeAddr("other-merchant");
    IssuerTreasury internal treasury;

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(500e6, 1000e6, 5000e6));
        usd.mint(alice, 10_000e6);
    }

    function test_standIn_pastTheCollateral_booksAndCountsInExposure() public {
        _guard(100e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        uint256 before = usd.balanceOf(alice);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P2, 50e6, merchant);
        assertEq(before - usd.balanceOf(alice), 50e6, "alice pays her stand-in");
        assertEq(treasury.exposure(), 150e6, "owed to the network, so in exposure");
        (,, int128 net,) = cards.ledger();
        assertEq(net, 150e6);
        // What the issuer chooses is still refused past the collateral.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 151e6, 100e6));
        cards.authorize(CARD, bytes32("purchase-3"), 1e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(IssuerTreasury.ExposureAboveCollateral.selector, 151e6, 100e6));
        cards.charge(CARD, bytes32("purchase-3"), 1e6, merchant);
    }

    function test_lateCharge_pastTheCollateral_books() public {
        _guard(100e6);
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        _authorize(P2, 100e6);
        _capture(P2, 100e6, true);
        vm.prank(issuer);
        cards.charge(CARD, P1, 30e6, merchant);
        assertEq(cards.purchaseOf(P1).captured, 30e6);
        assertEq(treasury.exposure(), 130e6);
    }

    function test_standIn_cardOrGrantState_neverRefuses() public {
        // Frozen by the owner.
        vm.prank(alice);
        cards.setOwnStatus(CARD, 1);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P1, 10e6, merchant);
        assertEq(cards.purchaseOf(P1).refunded, 0, "free cash paid");
        // A revoked grant.
        vm.prank(alice);
        cards.revoke();
        vm.prank(issuer);
        cards.bookStandIn(CARD, P2, 10e6, merchant);
        assertEq(cards.purchaseOf(P2).refunded, 0);
        // Past the card's expiry.
        vm.warp(block.timestamp + 400 days);
        vm.prank(issuer);
        cards.bookStandIn(CARD, bytes32("purchase-3"), 10e6, merchant);
        assertEq(usd.balanceOf(settlement), 30e6);
        (,, int128 net,) = cards.ledger();
        assertEq(net, 30e6);
        // A card never issued is refused.
        vm.prank(issuer);
        vm.expectRevert(CardLimits.CardNotActive.selector);
        cards.bookStandIn(bytes32("no-card"), bytes32("purchase-4"), 10e6, merchant);
    }

    function test_standIn_revokedMerchant_absorbedByTheIssuer() public {
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);
        uint256 before = usd.balanceOf(alice);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P1, 10e6, merchant);
        ICardAuth.PurchaseView memory p = cards.purchaseOf(P1);
        assertEq(p.captured, 10e6);
        assertEq(p.refunded, 10e6, "absorbed in full");
        assertEq(usd.balanceOf(alice), before, "alice pays nothing");
        (uint64 committed,,,,) = cards.usageOf(alice);
        assertEq(committed, 0, "not counted toward her limits");
        (, uint256 unsettled) = cards.exposure();
        assertEq(unsettled, 10e6, "the network is owed it");
    }

    function test_lateBooking_readsThePurchasesOwnMerchant() public {
        // A mandate limit records the merchant of P1; P2 at another merchant records none.
        vm.prank(alice);
        cards.setMandate(merchant, false, 1000e6);
        _authorize(P1, 10e6);
        vm.prank(issuer);
        cards.authorize(CARD, P2, 10e6, other, uint64(block.timestamp + 1 days), 0);
        vm.startPrank(issuer);
        cards.release(P1);
        cards.release(P2);
        vm.stopPrank();
        assertEq(cards.mandateMerchant(P1), merchant);
        vm.prank(alice);
        cards.setMandate(merchant, true, 0);

        // Naming another merchant changes nothing: P1's merchant is revoked, so the issuer absorbs it.
        uint256 before = usd.balanceOf(alice);
        vm.prank(issuer);
        cards.bookStandIn(CARD, P1, 700e6, other);
        assertEq(cards.purchaseOf(P1).refunded, 700e6);
        assertEq(usd.balanceOf(alice), before);
        // Nor does naming the revoked merchant on P2, whose merchant nothing recorded: alice pays it.
        vm.prank(issuer);
        cards.charge(CARD, P2, 40e6, merchant);
        assertEq(cards.purchaseOf(P2).refunded, 0);
        assertEq(before - usd.balanceOf(alice), 40e6);
    }

    function _guard(uint128 collateral) internal {
        treasury = new IssuerTreasury(cards);
        usd.mint(settlement, collateral);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(
            address(treasury), address(usd), id, collateral, uint64(block.timestamp + treasury.COVER_TERM() + 3 days)
        );
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
    }
}
