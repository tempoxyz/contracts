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
///         counts open converted holds at FX_STRESS_BPS.
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
        (uint128 tokens, uint128 units) = cash.paidOf(cards.legId(P1, TOKEN_LEG), address(usd));
        assertEq(tokens, held);
        assertEq(units, 100e6);
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
        // Refunds pay back at the rate the capture paid: every euro for what the euros covered.
        (uint128 tokens, uint128 units) = cash.paidOf(cards.legId(P1, TOKEN_LEG), address(usd));
        assertEq(tokens, h.captureLimit);
        assertEq(units, 100e6, "the euros covered the purchase, the issuer paying past the limit");
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
        // 49% of what the euros covered gives back 49% of the euros, whatever the venue does since.
        assertEq(eur.balanceOf(alice), 1000e6 - spent + spent * 49 / 100);
        // Refunds stop at what the settlement account was paid.
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, uint128(paid - 49e6 + 1));
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
        treasury.addFxSource(address(cash));
        assertEq(treasury.FX_STRESS_BPS(), 1000);
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

    /// @dev What the venue asks in euros for `units` dollars, whatever the reference rate.
    function _cost(uint256 units) internal view returns (uint256) {
        return conv.quoteOutAnchored(address(eur), address(usd), units, BID, BPS);
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
