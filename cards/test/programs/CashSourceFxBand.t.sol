// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardAuthBase } from "../../src/programs/CardAuthBase.sol";
import { CardLegs } from "../../src/programs/CardLegs.sol";
import { Conversion } from "../../src/programs/Conversion.sol";
import { IssuerTreasury } from "../../src/programs/IssuerTreasury.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";
import { Rates } from "./harness/Rates.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Captures and late charges of purchases funded in another stablecoin: the owner pays the locked price while
///         the venue stays within FX_BAND_BPS of it, the venue's price moved FX_BAND_BPS toward the owner past it, never
///         past the hold's capture limit; captures of live holds need no fresh reference rate; the exposure guard
///         counts open converted holds at their token's stress figure; the source keeps an exact open total per
///         converted token, for at most MAX_CONVERTED_TOKENS tokens at once.
contract CashSourceFxBandTest is AuthEnv {
    using FixedPointMathLib for uint256;

    bytes32 internal constant P1 = bytes32("fx-1");
    bytes32 internal constant P2 = bytes32("fx-2");
    bytes32 internal constant P3 = bytes32("fx-3");
    bytes32 internal constant P4 = bytes32("fx-4");
    uint256 internal constant TOKEN_LEG = 0;
    // EUR at $1.10 with a 30 bps conversion cost each way.
    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000;
    uint256 internal constant BPS = 10_000;

    ITIP20Token internal eur;
    Conversion internal conv;
    FixedPricePool internal bid;
    FixedPricePool internal ask;
    uint256 internal band;
    uint256 internal _tokenCount;

    function setUp() public {
        _deployPrograms();
        _issue(alice, _limits(5000e6, 10_000e6, 50_000e6));
        eur = _createToken("Euro", "EURX");
        conv = new Conversion(address(usd), address(this));
        bid = new FixedPricePool(address(eur), address(usd), BID);
        ask = new FixedPricePool(address(eur), address(usd), ASK);
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
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = _cashEntry(address(eur), 100);
        order[1] = _cashEntry(address(usd), 100);
        cards.setFunding(order);
        vm.stopPrank();
        // The owner lets captures run 10% past a hold.
        _setTolerance(alice, address(cash), address(eur), 1000);
        band = cash.FX_BAND_BPS();
        eur.mint(alice, 1000e6);
    }

    // Within the band.

    function test_withinBand_adverse_ownerPaysTheLockedPriceAndTheIssuerTheRest() public {
        _authorize(P1, 100e6);
        uint256 held = _cashHold(P1).held;
        // The euro falls 1.5%, inside the band: the owner pays the euros the lock promised.
        bid.setPrice(BID * 985 / 1000);
        _capture(P1, 100e6, true);
        uint256 paid = usd.balanceOf(settlement);
        assertEq(1000e6 - eur.balanceOf(alice), held);
        assertEq(paid, held * (BID * 985 / 1000) / 1e18);
        assertLt(paid, 100e6);
        assertEq(cards.purchaseOf(P1).refunded, 100e6 - paid, "the issuer absorbs the move");
        // Refunds count what the settlement account was paid, the issuer's share apart.
        (uint128 tokens, uint128 units) = cash.paidOf(cards.legId(P1, TOKEN_LEG), address(usd));
        assertEq(tokens, held);
        assertEq(units, paid);
    }

    function test_withinBand_favourable_ownerPaysTheLockedPriceAndTheIssuerKeepsTheGain() public {
        _authorize(P1, 100e6);
        uint256 held = _cashHold(P1).held;
        bid.setPrice(BID * 1015 / 1000);
        uint256 cost = _cost(100e6);
        _capture(P1, 100e6, true);
        assertEq(1000e6 - eur.balanceOf(alice), held);
        assertEq(usd.balanceOf(settlement), 100e6);
        // What the euros fetched past the purchase goes to the settlement account, in euros.
        assertEq(eur.balanceOf(settlement), held - cost);
        assertEq(cards.purchaseOf(P1).refunded, 0);
    }

    // Past the band.

    function test_pastBand_adverse_ownerPaysTheMarketLessTheBand() public {
        _authorize(P1, 100e6);
        bid.setPrice(BID * 95 / 100);
        uint256 cost = _cost(100e6);
        uint256 tokens = cost * (BPS - band) / BPS;
        _capture(P1, 100e6, true);
        assertEq(1000e6 - eur.balanceOf(alice), tokens);
        uint256 paid = usd.balanceOf(settlement);
        assertApproxEqAbs(paid, 98e6, 1);
        assertEq(cards.purchaseOf(P1).refunded, 100e6 - paid, "the issuer pays the band");
        assertEq(core.reserved(alice, address(eur)), 0);
        assertEq(cash.openConverted(), 0);
    }

    function test_pastBand_favourable_ownerPaysTheMarketPlusTheBand() public {
        _authorize(P1, 100e6);
        bid.setPrice(BID * 105 / 100);
        uint256 cost = _cost(100e6);
        uint256 tokens = FixedPointMathLib.mulDivUp(cost, BPS + band, BPS);
        _capture(P1, 100e6, true);
        assertEq(1000e6 - eur.balanceOf(alice), tokens);
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(eur.balanceOf(settlement), tokens - cost, "the issuer keeps the band");
        assertLt(tokens, _up(100e6, BID), "the owner gets the rest of the move back");
    }

    function test_pastBand_cappedByTheCaptureLimit_issuerPaysTheShortfall() public {
        _authorize(P1, 100e6);
        IReservationCore.HoldRecord memory h = _cashHold(P1);
        assertEq(h.captureLimit, h.held * 11 / 10);
        // Past the band and the owner's tolerance the venue prices only once the reference rate agrees.
        uint256 moved = BID * 70 / 100;
        bid.setPrice(moved);
        Rates.set(conv, address(eur), 1.1e18 * 70 / 100);
        _capture(P1, 100e6, true);
        assertEq(1000e6 - eur.balanceOf(alice), h.captureLimit, "never past the capture limit");
        uint256 paid = usd.balanceOf(settlement);
        assertEq(paid, uint256(h.captureLimit) * moved / 1e18);
        assertEq(usd.balanceOf(alice), 0);
        assertEq(cards.purchaseOf(P1).refunded, 100e6 - paid, "the issuer pays what the cap leaves");
        // Refunds pay back at the rate the capture paid: every euro for what the settlement account got for them.
        (uint128 tokens, uint128 units) = cash.paidOf(cards.legId(P1, TOKEN_LEG), address(usd));
        assertEq(tokens, h.captureLimit);
        assertEq(units, paid, "the issuer's share past the limit is never refunded");
    }

    function test_pastBand_capShortfall_issuerPaysNotTheNextLeg() public {
        usd.mint(alice, 100e6);
        _setTolerance(alice, address(cash), address(eur), 0);
        _authorize(P1, 100e6);
        uint256 held = _cashHold(P1).held;
        // Without tolerance the anchor band is FX_BAND_BPS alone: a 5% move waits for the reference rate.
        bid.setPrice(BID * 95 / 100);
        Rates.set(conv, address(eur), 1.1e18 * 95 / 100);
        _capture(P1, 100e6, true);
        // The euros stop at the capture limit (the hold); the issuer pays the rest, not the owner's dollars.
        assertEq(1000e6 - eur.balanceOf(alice), held);
        assertEq(usd.balanceOf(alice), 100e6);
        uint256 paid = usd.balanceOf(settlement);
        assertEq(paid, held * (BID * 95 / 100) / 1e18);
        assertEq(cards.purchaseOf(P1).refunded, 100e6 - paid);
    }

    function test_ownerShortOfTokens_nextLegPaysTheRest() public {
        vm.prank(alice);
        eur.transfer(address(0xdead), 962e6);
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        // A capture past the hold takes the owner's last euros; its dollars pay what the euros did not buy.
        _capture(P1, 44e6, true);
        assertEq(eur.balanceOf(alice), 0);
        uint256 covered = uint256(44e6).mulDiv(38e6, _up(44e6, BID));
        assertApproxEqAbs(usd.balanceOf(alice), 100e6 - (44e6 - covered), 1);
        assertApproxEqAbs(usd.balanceOf(settlement), 38e6 * BID / 1e18 + 44e6 - covered, 1);
    }

    function test_splitPurchase_nextLegIsAskedWhatTheConvertedLegLeft() public {
        // The euros fund a part of the purchase: an 11 euro hold, a 12.10 capture limit at the 10% tolerance.
        vm.prank(alice);
        eur.transfer(address(0xdead), 989e6);
        usd.mint(alice, 40e6);
        _authorize(P1, 40e6);
        IReservationCore.HoldRecord memory h = _cashHold(P1);
        assertEq(h.held, 11e6);
        assertEq(h.captureLimit, 12.1e6);
        uint256 rate = cash.lockedRate(cards.legId(P1, TOKEN_LEG));
        _capture(P1, 40e6, true);
        // The euros cover their share of the purchase at the locked price; the dollars are asked for the rest.
        uint256 covered = uint256(40e6).mulDiv(11e6, FixedPointMathLib.mulDivUp(40e6, 1e18, rate));
        assertApproxEqAbs(covered, uint256(11e6) * rate / 1e18, 1);
        assertEq(eur.balanceOf(alice), 0);
        assertEq(usd.balanceOf(alice), covered);
        assertLe(cards.purchaseOf(P1).refunded, 1, "nothing falls to the issuer");
        assertApproxEqAbs(usd.balanceOf(settlement), 40e6, 1);
    }

    function test_splitPurchase_capturePastCash_neverReportsMorePaidThanCovered() public {
        // Euro balances around what captures past the hold need, so the dollars pay any rest; each rounds differently.
        for (uint256 i; i < 24; ++i) {
            uint256 balance = 37e6 + i * 111_111;
            uint128 amount = uint128(41e6 + (i % 4) * 1e6);
            bytes32 ref = keccak256(abi.encode("past-cash", i));
            uint256 before = eur.balanceOf(alice);
            if (before > balance) {
                vm.prank(alice);
                eur.transfer(address(0xdead), before - balance);
            } else {
                eur.mint(alice, balance - before);
            }
            usd.mint(alice, 10e6);
            uint256 stlBefore = usd.balanceOf(settlement);
            _authorize(ref, 40e6);
            _capture(ref, amount, true);
            uint256 got = usd.balanceOf(settlement) - stlBefore;
            uint256 absorbed = cards.purchaseOf(ref).refunded;
            // The program records no more than the settlement account received, and the dollars pay what is left.
            assertGe(got + absorbed, amount, "recorded past what was paid");
            assertLe(absorbed, 1);
        }
    }

    // The reference rate.

    function test_staleReference_noLongerBlocksTheCaptureOfALiveHold() public {
        vm.prank(issuer);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 10 days), 0);
        uint256 held = _cashHold(P1).held;
        vm.warp(block.timestamp + conv.MAX_RATE_AGE() + 1);
        vm.expectRevert();
        conv.rate(address(eur), address(usd));
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(1000e6 - eur.balanceOf(alice), held);
        // A new authorization still needs a fresh reference rate: the euros cover nothing.
        usd.mint(alice, 10e6);
        _authorize(P2, 10e6);
        assertEq(_cashHold(P2).held, 0);
        assertEq(usd.balanceOf(alice), 0);
    }

    function test_venueBeyondTheBandAndTolerance_revertsUntilTheReferenceAgrees() public {
        _authorize(P1, 100e6);
        // The venue pays 30% less while the reference rate has not moved: past band and tolerance it is refused.
        bid.setPrice(BID * 70 / 100);
        vm.prank(issuer);
        vm.expectPartialRevert(Conversion.RateDeviates.selector);
        cards.capture(P1, 100e6, true);
        assertEq(cards.purchaseOf(P1).captured, 0);
        // Once the reference rate confirms the move the capture goes through, the issuer paying past the limit.
        Rates.set(conv, address(eur), 1.1e18 * 70 / 100);
        _capture(P1, 100e6, true);
        assertEq(cards.purchaseOf(P1).captured, 100e6);
    }

    function test_anchoredQuote_revertsBeyondTheBand() public {
        uint256 fair = _up(100e6, BID);
        assertEq(
            conv.quoteOutAnchored(address(eur), address(usd), 100e6, BID, 200),
            conv.quoteOut(address(eur), address(usd), 100e6)
        );
        bid.setPrice(BID * 97 / 100);
        uint256 cost = _cost(100e6);
        vm.expectRevert(
            abi.encodeWithSelector(Conversion.RateBeyondAnchor.selector, address(eur), address(usd), cost, fair)
        );
        conv.quoteOutAnchored(address(eur), address(usd), 100e6, BID, 200);
        assertEq(conv.quoteOutAnchored(address(eur), address(usd), 100e6, BID, 400), cost);
    }

    function test_anchoredSwaps_trustedOnlyAndBoundedByTheBand() public {
        eur.mint(address(this), 1000e6);
        eur.approve(address(conv), type(uint256).max);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.swapExactInAnchored(address(eur), address(usd), 10e6, BID, 200, address(this));
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.swapExactOutAnchored(address(eur), address(usd), 10e6, 20e6, BID, 200, address(this));
        conv.setTrusted(address(this), true);
        bid.setPrice(BID * 90 / 100);
        vm.expectPartialRevert(Conversion.RateBeyondAnchor.selector);
        conv.swapExactInAnchored(address(eur), address(usd), 10e6, BID, 500, address(this));
        vm.expectPartialRevert(Conversion.RateBeyondAnchor.selector);
        conv.swapExactOutAnchored(address(eur), address(usd), 10e6, 20e6, BID, 500, address(this));
        // Within the band they trade at the venue, a stale reference rate notwithstanding.
        vm.warp(block.timestamp + conv.MAX_RATE_AGE() + 1);
        uint256 out = conv.swapExactInAnchored(address(eur), address(usd), 10e6, BID, 1200, address(this));
        assertEq(out, 10e6 * (BID * 90 / 100) / 1e18);
    }

    function test_untrustedSource_keepsTheReferencePath() public {
        conv.setTrusted(address(cash), false);
        _authorize(P1, 100e6);
        vm.warp(block.timestamp + conv.MAX_RATE_AGE() + 1);
        vm.prank(issuer);
        vm.expectRevert();
        cards.capture(P1, 100e6, true);
    }

    // The tolerance a hold was placed with.

    function test_holdKeepsItsTolerance_narrowedAfterAuthorization_captureStillPricesInTheBand() public {
        _authorize(P1, 100e6);
        bytes32 leg = cards.legId(P1, TOKEN_LEG);
        assertEq(cash.lockedTolerance(leg), 1000);
        // The owner narrows its terms after authorizing; the hold and its band keep the 10% it was placed with.
        _setTolerance(alice, address(cash), address(eur), 0);
        bid.setPrice(BID * 95 / 100);
        uint256 cost = _cost(100e6);
        _capture(P1, 100e6, true);
        assertEq(1000e6 - eur.balanceOf(alice), cost * (BPS - band) / BPS);
        assertApproxEqAbs(usd.balanceOf(settlement), 98e6, 1);
    }

    function test_holdKeepsItsTolerance_narrowedAfterAuthorization_lateChargeStillPricesInTheBand() public {
        _authorize(P1, 100e6);
        bytes32 leg = cards.legId(P1, TOKEN_LEG);
        _setTolerance(alice, address(cash), address(eur), 0);
        vm.warp(block.timestamp + 7 days);
        cards.release(P1);
        assertEq(cash.lockedTolerance(leg), 1000, "an expired hold keeps its tolerance for a late charge");
        bid.setPrice(BID * 95 / 100);
        uint256 cost = _cost(100e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(1000e6 - eur.balanceOf(alice), cost * (BPS - band) / BPS);
        assertApproxEqAbs(usd.balanceOf(settlement), 98e6, 1);
        assertEq(cash.lockedTolerance(leg), 0, "the late charge consumes it");
    }

    function test_holdKeepsItsTolerance_lateChargeCappedByIt() public {
        _authorize(P1, 100e6);
        uint256 held = _cashHold(P1).held;
        vm.warp(block.timestamp + 7 days);
        cards.release(P1);
        // Raising the terms after the hold lapsed does not raise what a late charge may take.
        _setTolerance(alice, address(cash), address(eur), 1800);
        bid.setPrice(BID * 85 / 100);
        Rates.set(conv, address(eur), 1.1e18 * 85 / 100);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(1000e6 - eur.balanceOf(alice), uint256(held) * 11 / 10, "the hold's 10% caps the late charge");
    }

    function test_holdKeepsItsTolerance_widenedAfterAuthorization_bandStaysBounded() public {
        _authorize(P1, 100e6);
        _setTolerance(alice, address(cash), address(eur), type(uint16).max);
        uint256 before = eur.balanceOf(alice);
        // A venue paying a fifth of the locked price is past the hold's band: refused while the reference disagrees.
        bid.setPrice(BID / 5);
        vm.prank(issuer);
        vm.expectPartialRevert(Conversion.RateDeviates.selector);
        cards.capture(P1, 100e6, true);
        assertEq(eur.balanceOf(alice), before);
        assertEq(usd.balanceOf(settlement), 0);
    }

    function test_holdKeepsItsTolerance_resizeKeepsIt() public {
        _authorize(P1, 100e6);
        bytes32 leg = cards.legId(P1, TOKEN_LEG);
        _setTolerance(alice, address(cash), address(eur), 0);
        vm.prank(issuer);
        cards.adjust(P1, 120e6);
        assertEq(cash.lockedTolerance(leg), 1000);
    }

    function test_holdTolerancePastTheWidestBand_bandStopsThere() public {
        _setTolerance(alice, address(cash), address(eur), 5000);
        _authorize(P1, 100e6);
        assertEq(cash.lockedTolerance(cards.legId(P1, TOKEN_LEG)), 5000);
        // The band stops at the Conversion's widest: a 15% move prices against the lock, a 25% one does not.
        bid.setPrice(BID * 85 / 100);
        _capture(P1, 50e6, false);
        bid.setPrice(BID * 75 / 100);
        vm.prank(issuer);
        vm.expectPartialRevert(Conversion.RateDeviates.selector);
        cards.capture(P1, 50e6, true);
    }

    function test_anchoredQuotesAndSwaps_refuseABandPastTheWidest() public {
        uint256 most = conv.MAX_ANCHOR_BAND_BPS();
        assertEq(most, 2000);
        conv.quoteOutAnchored(address(eur), address(usd), 100e6, BID, most);
        vm.expectRevert(abi.encodeWithSelector(Conversion.BandTooWide.selector, most + 1));
        conv.quoteOutAnchored(address(eur), address(usd), 100e6, BID, most + 1);
        conv.setTrusted(address(this), true);
        eur.mint(address(this), 100e6);
        eur.approve(address(conv), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Conversion.BandTooWide.selector, BPS));
        conv.swapExactInAnchored(address(eur), address(usd), 10e6, BID, BPS, address(this));
        vm.expectRevert(abi.encodeWithSelector(Conversion.BandTooWide.selector, most + 1));
        conv.swapExactOutAnchored(address(eur), address(usd), 10e6, 20e6, BID, most + 1, address(this));
        assertEq(
            conv.swapExactInAnchored(address(eur), address(usd), 10e6, BID, most, address(this)), 10e6 * BID / 1e18
        );
    }

    // Late presentments.

    function test_latePresentment_pricesAgainstTheRateThePurchaseLocked() public {
        _authorize(P1, 100e6);
        bytes32 leg = cards.legId(P1, TOKEN_LEG);
        uint256 rate = cash.lockedRate(leg);
        vm.warp(block.timestamp + 7 days);
        cards.release(P1);
        assertEq(cash.lockedRate(leg), rate, "an expired hold keeps its rate for a late charge");
        assertEq(cash.openConverted(), 0);
        bid.setPrice(BID * 95 / 100);
        uint256 cost = _cost(100e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(1000e6 - eur.balanceOf(alice), cost * (BPS - band) / BPS);
        uint256 paid = usd.balanceOf(settlement);
        assertApproxEqAbs(paid, 98e6, 1);
        assertEq(cards.purchaseOf(P1).refunded, 100e6 - paid);
        assertEq(cash.lockedRate(leg), 0, "the late charge consumes it");
    }

    function test_latePresentment_withinBand_paysTheLockedPrice() public {
        _authorize(P1, 100e6);
        uint256 held = _cashHold(P1).held;
        vm.warp(block.timestamp + 7 days);
        cards.release(P1);
        bid.setPrice(BID * 99 / 100);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        assertEq(1000e6 - eur.balanceOf(alice), held);
    }

    function test_reversal_dropsTheRate() public {
        _authorize(P1, 100e6);
        vm.prank(issuer);
        cards.release(P1);
        assertEq(cash.lockedRate(cards.legId(P1, TOKEN_LEG)), 0);
        assertEq(cash.openConverted(), 0);
    }

    // Refunds.

    function test_refund_paysBackAtTheRateTheCapturePaid() public {
        _authorize(P1, 100e6);
        bid.setPrice(BID * 95 / 100);
        _capture(P1, 100e6, true);
        uint256 spent = 1000e6 - eur.balanceOf(alice);
        uint256 paid = usd.balanceOf(settlement);
        usd.mint(issuer, 100e6);
        vm.startPrank(issuer);
        usd.approve(address(cards), type(uint256).max);
        cards.refund(P1, 49e6);
        vm.stopPrank();
        // A share of what the euros paid the settlement account gives back that share of the euros, whatever the
        // venue does since.
        assertEq(eur.balanceOf(alice), 1000e6 - spent + spent * 49e6 / paid);
        // Refunds stop at what the settlement account was paid.
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, uint128(paid - 49e6 + 1));
        // The rest gives back every euro spent.
        vm.prank(issuer);
        cards.refund(P1, uint128(paid - 49e6));
        assertEq(eur.balanceOf(alice), 1000e6);
    }

    function test_fullRefund_withinBandAdverse_returnsEveryTokenSpent() public {
        _authorize(P1, 100e6);
        uint256 held = _cashHold(P1).held;
        bid.setPrice(BID * 985 / 1000);
        _capture(P1, 100e6, true);
        assertGt(cards.purchaseOf(P1).refunded, 0, "the issuer absorbs the move");
        uint256 floatBefore = eur.balanceOf(address(conv));
        uint256 amount = _refundAll(P1);
        assertEq(amount, usd.balanceOf(settlement), "a full refund is what the settlement account was paid");
        assertEq(eur.balanceOf(alice), 1000e6, "every euro back");
        assertEq(floatBefore - eur.balanceOf(address(conv)), held, "the float pays them out");
        (uint128 tokens, uint128 units) = cash.paidOf(cards.legId(P1, TOKEN_LEG), address(usd));
        assertEq(tokens, 0);
        assertEq(units, 0);
    }

    function test_fullRefund_cappedByTheCaptureLimit_returnsEveryTokenSpent() public {
        _authorize(P1, 100e6);
        IReservationCore.HoldRecord memory h = _cashHold(P1);
        bid.setPrice(BID * 70 / 100);
        Rates.set(conv, address(eur), 1.1e18 * 70 / 100);
        _capture(P1, 100e6, true);
        assertEq(1000e6 - eur.balanceOf(alice), h.captureLimit);
        _refundAll(P1);
        assertEq(eur.balanceOf(alice), 1000e6, "every euro back, the issuer's share past the limit apart");
    }

    function test_fullRefund_lateChargePastTheBand_returnsEveryTokenSpent() public {
        _authorize(P1, 100e6);
        vm.warp(block.timestamp + 7 days);
        cards.release(P1);
        bid.setPrice(BID * 95 / 100);
        vm.prank(issuer);
        cards.charge(CARD, P1, 100e6, merchant);
        (, uint128 units) = cash.paidOf(cards.legId(P1, TOKEN_LEG), address(usd));
        assertEq(units, usd.balanceOf(settlement));
        _refundAll(P1);
        assertEq(eur.balanceOf(alice), 1000e6);
    }

    // Part captures and the open total.

    function test_partCapture_keepsTheLockedRateForTheRest() public {
        _authorize(P1, 100e6);
        bytes32 leg = cards.legId(P1, TOKEN_LEG);
        uint256 rate = cash.lockedRate(leg);
        bid.setPrice(BID * 99 / 100);
        Rates.set(conv, address(eur), 1.1e18 * 99 / 100);
        _capture(P1, 40e6, false);
        assertEq(cash.lockedRate(leg), rate);
        assertEq(cash.openConverted(), uint256(_cashHold(P1).held) * rate / 1e18);
        _capture(P1, 60e6, true);
        assertEq(cash.openConverted(), 0);
        assertEq(core.reserved(alice, address(eur)), 0);
    }

    function test_openConverted_returnsToZeroOnceEveryHoldResolves() public {
        _authorize(P1, 100e6);
        _authorize(P2, 50e6);
        _authorize(P3, 30e6);
        _authorize(P4, 20e6);
        uint256 open = cash.openConverted();
        assertApproxEqAbs(open, 200e6, 4);
        assertEq(open, _value(P1) + _value(P2) + _value(P3) + _value(P4));
        // Shrinking and growing a hold moves the total with it.
        vm.startPrank(issuer);
        cards.adjust(P2, 20e6);
        assertEq(cash.openConverted(), _value(P1) + _value(P2) + _value(P3) + _value(P4));
        cards.adjust(P2, 60e6);
        assertEq(cash.openConverted(), _value(P1) + _value(P2) + _value(P3) + _value(P4));
        cards.capture(P1, 30e6, false);
        cards.capture(P1, 70e6, true);
        cards.release(P3);
        vm.stopPrank();
        assertEq(cash.openConverted(), _value(P2) + _value(P4));
        _capture(P2, 10e6, true);
        // A hold the core ended at its expiry counts until anyone releases the purchase.
        vm.warp(block.timestamp + 7 days);
        core.releaseExpired(alice, address(cash), cards.legId(P4, TOKEN_LEG));
        assertGt(cash.openConverted(), 0);
        cards.release(P4);
        assertEq(cash.openConverted(), 0);
    }

    // Per-token totals.

    function test_openConvertedOf_keepsAnExactTotalPerTokenThatReturnsToZero() public {
        (ITIP20Token gbp,) = _secondToken();
        _authorize(P1, 100e6);
        _fundIn(gbp);
        _authorize(P2, 50e6);
        _authorize(P3, 30e6);
        uint256 e = cash.openConvertedOf(address(eur));
        uint256 g = cash.openConvertedOf(address(gbp));
        assertEq(e, _value(P1));
        assertEq(g, _value(P2) + _value(P3));
        assertEq(cash.openConverted(), e + g);
        (address[] memory tokens, uint256[] memory open) = cash.convertedTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(eur));
        assertEq(tokens[1], address(gbp));
        assertEq(open[0], e);
        assertEq(open[1], g);
        vm.prank(issuer);
        cards.adjust(P2, 20e6);
        assertEq(cash.openConvertedOf(address(gbp)), _value(P2) + _value(P3));
        assertEq(cash.openConvertedOf(address(eur)), e, "other tokens stay as they were");
        _capture(P1, 40e6, false);
        assertEq(cash.openConvertedOf(address(eur)), _value(P1));
        _capture(P1, 60e6, true);
        assertEq(cash.openConvertedOf(address(eur)), 0);
        vm.prank(issuer);
        cards.release(P2);
        // An expired hold counts toward its token until anyone releases the purchase.
        uint256 left = _value(P3);
        assertEq(cash.openConvertedOf(address(gbp)), left);
        vm.warp(block.timestamp + 7 days);
        core.releaseExpired(alice, address(cash), cards.legId(P3, TOKEN_LEG));
        assertEq(cash.openConvertedOf(address(gbp)), left);
        cards.release(P3);
        assertEq(cash.openConvertedOf(address(gbp)), 0);
        assertEq(cash.openConverted(), 0);
        // Both keep their place while nothing else needs it.
        (tokens, open) = cash.convertedTokens();
        assertEq(tokens.length, 2);
        assertEq(open[0] + open[1], 0);
    }

    function test_convertedTokens_aLegThatDoesNotHoldTakesNoPlace() public {
        (ITIP20Token gbp,) = _secondToken();
        // The owner holds none of it: the leg holds nothing and the purchase falls to dollars.
        vm.prank(alice);
        gbp.transfer(makeAddr("elsewhere"), 1000e6);
        _fundIn(gbp);
        usd.mint(alice, 10e6);
        _authorize(P1, 10e6);
        assertEq(core.reserved(alice, address(usd)), 10e6);
        (address[] memory tokens,) = cash.convertedTokens();
        assertEq(tokens.length, 0);
    }

    function test_convertedTokens_atMostEightAndADrainedTokenGivesUpItsPlace() public {
        uint256 max = cash.MAX_CONVERTED_TOKENS();
        assertEq(max, 8);
        // Setting each token's reference rate moves the clock, so every token exists before any purchase.
        ITIP20Token[] memory more = new ITIP20Token[](max);
        for (uint256 i = 1; i < max; ++i) {
            (more[i],) = _secondToken();
        }
        (ITIP20Token ninth,) = _secondToken();
        // Each new rate moved the clock past the earlier rates' age: refresh them at the same price.
        conv.setReferenceRate(address(eur), 1.1e18);
        for (uint256 i = 1; i < max; ++i) {
            conv.setReferenceRate(address(more[i]), 1.1e18);
        }
        // P1 holds euros; seven more tokens each hold one purchase.
        _fundIn(eur);
        _authorize(P1, 10e6);
        for (uint256 i = 1; i < max; ++i) {
            _fundIn(more[i]);
            _authorize(bytes32(i), 10e6);
            assertGt(cash.openConvertedOf(address(more[i])), 0);
        }
        (address[] memory tokens,) = cash.convertedTokens();
        assertEq(tokens.length, max);
        // A ninth token finds no place: its leg is not placed and the purchase falls to dollars.
        _fundIn(ninth);
        usd.mint(alice, 10e6);
        _authorize(P2, 10e6);
        assertEq(core.reserved(alice, address(ninth)), 0);
        assertEq(cash.openConvertedOf(address(ninth)), 0);
        assertEq(core.reserved(alice, address(usd)), 10e6);
        // Once the euro holds close, the ninth token takes the euro's place.
        _capture(P1, 10e6, true);
        _authorize(P3, 10e6);
        assertGt(cash.openConvertedOf(address(ninth)), 0);
        (tokens,) = cash.convertedTokens();
        assertEq(tokens.length, max);
        assertEq(tokens[0], address(ninth));
        uint256 sum;
        for (uint256 i = 1; i < max; ++i) {
            sum += cash.openConvertedOf(address(more[i]));
        }
        assertEq(cash.openConverted(), sum + cash.openConvertedOf(address(ninth)));
        // The euro asks for a place again and finds none until another token drains.
        _fundIn(eur);
        usd.mint(alice, 10e6);
        _authorize(P4, 10e6);
        assertEq(core.reserved(alice, address(eur)), 0);
        assertEq(core.reserved(alice, address(usd)), 20e6);
    }

    // The exposure guard.

    function test_exposureGuard_countsOpenConvertedHoldsAtTheStressShare() public {
        IssuerTreasury treasury = new IssuerTreasury(cards);
        address sponsor = makeAddr("sponsor");
        usd.mint(settlement, 105e6);
        bytes32 id = treasury.pledgeId(1);
        vm.startPrank(settlement);
        core.pledge(address(treasury), address(usd), id, 105e6, uint64(block.timestamp + 365 days));
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
        assertEq(treasury.fxStressOf(address(eur)), 1000);
        _authorize(P1, 90e6);
        uint256 open = cash.openConverted();
        assertEq(treasury.stressedExposure(), treasury.exposure() + open.mulDivUp(1000, BPS));
        // 90 held plus 10% of 90 is past 95 more of the 105 posted: a 10 dollar purchase is refused.
        vm.prank(issuer);
        vm.expectPartialRevert(IssuerTreasury.ExposureAboveCollateral.selector);
        cards.authorize(CARD, P2, 10e6, merchant, uint64(block.timestamp + 7 days), 0);
        // A dollar-funded purchase counts at its value alone.
        vm.prank(issuer);
        cards.authorize(CARD, P2, 5e6, merchant, uint64(block.timestamp + 7 days), 0);
        // Capturing ends the stress share; what the capture still owes counts as before.
        _capture(P1, 90e6, true);
        assertEq(cash.openConverted(), open - open + _value(P2));
        assertEq(treasury.stressedExposure(), treasury.exposure() + _value(P2).mulDivUp(1000, BPS));
    }

    // Helpers.

    /// @dev A token at $1.10 like the euro, with venues, a reference rate, float, the owner's approval and funds.
    function _secondToken() internal returns (ITIP20Token token, FixedPricePool pool) {
        string memory id = vm.toString(++_tokenCount);
        token = _createToken(string.concat("Second ", id), string.concat("SCND", id));
        pool = new FixedPricePool(address(token), address(usd), BID);
        FixedPricePool back = new FixedPricePool(address(usd), address(token), ASK);
        usd.mint(address(pool), 1_000_000e6);
        token.mint(address(back), 1_000_000e6);
        conv.setVenue(address(token), address(usd), address(pool), true);
        conv.setVenue(address(usd), address(token), address(back), false);
        Rates.set(conv, address(token), 1.1e18);
        usd.mint(address(conv), 100_000e6);
        token.mint(address(conv), 100_000e6);
        vm.prank(alice);
        core.approveHolder(address(cash), address(token), type(uint128).max, 0);
        _setTolerance(alice, address(cash), address(token), 1000);
        token.mint(alice, 1000e6);
    }

    /// @dev Points the owner's funding order at `token`, then dollars.
    function _fundIn(ITIP20Token token) internal {
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = _cashEntry(address(token), 100);
        order[1] = _cashEntry(address(usd), 100);
        vm.prank(alice);
        cards.setFunding(order);
    }

    /// @dev What the venue asks in euros for `units` dollars, whatever the reference rate (within the widest band).
    function _cost(uint256 units) internal view returns (uint256) {
        return conv.quoteOutAnchored(address(eur), address(usd), units, BID, conv.MAX_ANCHOR_BAND_BPS());
    }

    /// @dev Refunds all the purchase still may and returns how much.
    function _refundAll(bytes32 ref) internal returns (uint256 amount) {
        amount = cards.purchaseOf(ref).captured - cards.purchaseOf(ref).refunded;
        usd.mint(issuer, amount);
        vm.startPrank(issuer);
        usd.approve(address(cards), type(uint256).max);
        cards.refund(ref, uint128(amount));
        vm.stopPrank();
    }

    function _value(bytes32 ref) internal view returns (uint256) {
        return uint256(_cashHold(ref).held) * cash.lockedRate(cards.legId(ref, TOKEN_LEG)) / 1e18;
    }

    function _cashHold(bytes32 ref) internal view returns (IReservationCore.HoldRecord memory) {
        return core.getHold(alice, address(cash), cards.legId(ref, TOKEN_LEG));
    }

    function _up(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return (amount * 1e18 + rate - 1) / rate;
    }
}
