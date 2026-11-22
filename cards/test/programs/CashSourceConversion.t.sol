// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardAuthBase } from "../../src/programs/CardAuthBase.sol";
import { CardLegs } from "../../src/programs/CardLegs.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { Conversion } from "../../src/programs/Conversion.sol";
import { IssuerTreasury } from "../../src/programs/IssuerTreasury.sol";
import { Rewards } from "../../src/programs/Rewards.sol";
import { ICardAuth } from "../../src/programs/interfaces/ICardAuth.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ISource } from "../../src/programs/interfaces/ISource.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";
import { Rates } from "./harness/Rates.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Purchases funded in another stablecoin through the cash source, and issuers settling in one: rate locks at
///         authorization, the capture that pays the issuer exactly, reversals that keep the leg's share rounded up,
///         refunds at the rate the capture paid, reference rates the Conversion owner moves, and moving the program to
///         another settlement token. CashSourceFxBand.t.sol covers how captures price once the market moves.
contract CashSourceConversionTest is AuthEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    uint256 internal constant TOKEN_LEG = 0;
    uint256 internal constant USD_LEG = 1;
    // EUR at $1.10 with a 30 bps conversion cost each way.
    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000; // ~1.1 / 0.997
    // EUR per USD at the reference rate: the settlement token scale moving from USD to EUR.
    uint256 internal constant EUR_SCALE = uint256(1e36) / 1.1e18;

    ITIP20Token internal eur;
    Conversion internal conv;
    FixedPricePool internal bid;
    FixedPricePool internal ask;

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
        conv.setTrusted(address(savings), true);
        usd.mint(address(conv), 100_000e6);
        eur.mint(address(conv), 100_000e6);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(0), address(0), address(conv))));
        _setting(abi.encodeCall(cards.setCompanion, (address(this), true)));
        vm.prank(alice);
        core.approveHolder(address(cash), address(eur), type(uint128).max, 0);
    }

    // Purchases in another stablecoin, for a USD issuer.

    function test_tokenLeg_locksTheRateAndPaysTheIssuerExactly() public {
        _tokenFirst(100);
        eur.mint(alice, 200e6);
        _authorize(P1, 100e6);
        bytes32 leg = cards.legId(P1, TOKEN_LEG);
        assertEq(cash.lockedRate(leg), BID);
        uint256 held = _cashHold(P1, TOKEN_LEG).held;
        assertEq(held, _up(100e6, BID));
        assertEq(cash.held(alice, _position(address(eur), 100), leg), held * BID / 1e18);
        uint256 cost = conv.quoteOut(address(eur), address(usd), 100e6);
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        // The owner pays what the venue asks, never more than the hold the locked rate set.
        assertLe(cost, held);
        assertEq(eur.balanceOf(alice), 200e6 - cost);
        assertEq(core.reserved(alice, address(eur)), 0);
        assertEq(cash.lockedRate(leg), 0, "the lock goes with the leg");
        _assertSourcesEmpty();
        assertEq(eur.balanceOf(address(cash)), 0, "nothing left in the source");
        assertEq(eur.balanceOf(address(cards)), 0, "nothing left in the program");
    }

    /// @dev A venue asking a unit more than the rate implies sets the lock at the price the hold reserved, so the
    ///      capture spends exactly the hold.
    function test_tokenLeg_venueAskingMore_locksThePriceTheHoldReserved() public {
        _tokenFirst(100);
        eur.mint(alice, 200e6);
        uint256 asked = _up(100e6, BID) + 1;
        vm.mockCall(
            address(conv), abi.encodeCall(conv.quoteOut, (address(eur), address(usd), 100e6)), abi.encode(asked)
        );
        _authorize(P1, 100e6);
        bytes32 leg = cards.legId(P1, TOKEN_LEG);
        assertEq(_cashHold(P1, TOKEN_LEG).held, asked);
        assertEq(cash.lockedRate(leg), FixedPointMathLib.mulDivUp(100e6, 1e18, asked));
        assertEq(cash.held(alice, _position(address(eur), 100), leg), 100e6);
        _capture(P1, 100e6, true);
        vm.clearMockedCalls();
        assertEq(eur.balanceOf(alice), 200e6 - asked);
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(core.reserved(alice, address(eur)), 0);
    }

    function test_tokenLeg_skippedWhileConvertingCostsMoreThanAllowed() public {
        _tokenFirst(20);
        eur.mint(alice, 200e6);
        usd.mint(alice, 100e6);
        _authorize(P1, 50e6);
        assertEq(_cashHold(P1, TOKEN_LEG).held, 0);
        assertEq(_cashHold(P1, USD_LEG).held, 50e6);
        assertEq(cash.coverable(alice, _position(address(eur), 20)), 0);
        assertEq(
            cash.coverable(alice, _position(address(eur), 30)), 200e6 * conv.rate(address(eur), address(usd)) / 1e18
        );
    }

    function test_capture_neverSpendsMoreThanTheOwnerHas() public {
        _setTolerance(alice, address(cash), address(eur), 10_000);
        _tokenFirst(100);
        eur.mint(alice, 50e6);
        _authorize(P1, 40e6);
        uint256 placed = _cashHold(P1, TOKEN_LEG).held;
        _capture(P1, 80e6, true);
        assertEq(eur.balanceOf(alice), 0);
        uint256 paid = usd.balanceOf(settlement);
        assertEq(paid, 50e6 * BID / 1e18);
        assertGt(paid, placed * BID / 1e18);
        // The leg reports at most what its euros covered at the locked price, rounded down; the unit of rounding the
        // swap fetched past it stays with the settlement account.
        assertApproxEqAbs(cards.purchaseOf(P1).refunded, 80e6 - paid, 1);
        assertGe(cards.purchaseOf(P1).refunded, 80e6 - paid);
    }

    function test_partialReversal_keepsTheLockedRateRoundedUp() public {
        _tokenFirst(100);
        eur.mint(alice, 200e6);
        _authorize(P1, 40e6);
        bytes32 leg = cards.legId(P1, TOKEN_LEG);
        uint256 rate = cash.lockedRate(leg);
        vm.prank(issuer);
        cards.adjust(P1, 20e6);
        assertEq(_cashHold(P1, TOKEN_LEG).held, _up(20e6, rate));
        assertEq(cash.lockedRate(leg), rate);
        // Growing past what it holds re-prices the leg at today's rate.
        bid.setPrice(BID * 101 / 100);
        Rates.set(conv, address(eur), 1.1e18 * 101 / 100);
        vm.prank(issuer);
        cards.adjust(P1, 60e6);
        assertEq(cash.lockedRate(leg), conv.rate(address(eur), address(usd)));
        assertApproxEqAbs(cash.held(alice, _position(address(eur), 100), leg), 60e6, 1);
    }

    function test_refund_paysTheTokenBackAtTheRateTheCapturePaid() public {
        _tokenFirst(100);
        eur.mint(alice, 200e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        uint256 before = eur.balanceOf(alice);
        uint256 spent = 200e6 - before;
        (uint128 tokens, uint128 units) = cash.paidOf(cards.legId(P1, TOKEN_LEG), address(usd));
        assertEq(tokens, spent);
        assertEq(units, 100e6);
        _fundRefunds(usd, 22e6);
        vm.prank(issuer);
        cards.refund(P1, 22e6);
        // 22% of the purchase gives back 22% of the euros it took, above their value at the reference rate.
        assertEq(eur.balanceOf(alice), before + spent * 22 / 100);
        assertGt(spent * 22 / 100, 20e6);
        assertEq(usd.balanceOf(issuer), 0);
    }

    function test_forcePost_inAForeignToken_convertsWithinTheMaxCost() public {
        _tokenFirst(100);
        eur.mint(alice, 100e6);
        uint256 cost = conv.quoteOut(address(eur), address(usd), 30e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 30e6, merchant);
        assertEq(usd.balanceOf(settlement), 30e6);
        assertEq(eur.balanceOf(alice), 100e6 - cost);
        // A refund converts back at the rate the charge paid.
        (uint128 tokens, uint128 units) = cash.paidOf(cards.legId(P1, TOKEN_LEG), address(usd));
        assertEq(tokens, cost);
        assertEq(units, 30e6);
        // Past the owner's euros the issuer absorbs the charge.
        vm.prank(issuer);
        cards.charge(CARD, P2, 200e6, merchant);
        assertEq(eur.balanceOf(alice), 0);
        // Too costly a conversion takes nothing.
        _tokenFirst(20);
        eur.mint(alice, 100e6);
        vm.prank(issuer);
        cards.charge(CARD, bytes32("purchase-3"), 10e6, merchant);
        assertEq(eur.balanceOf(alice), 100e6);
        assertEq(cards.purchaseOf(bytes32("purchase-3")).refunded, 10e6);
    }

    // Reference rates the Conversion's owner moves, and a stale rate.

    /// @dev A rate far from the market waits for the delay, and once set, the venue disagrees with it: the token
    ///      covers nothing instead of paying ten times its price.
    function test_referenceRate_farFromTheVenueWaitsAndThenConvertsNothing() public {
        _tokenFirst(100);
        eur.mint(alice, 20_000e6);
        vm.expectRevert(abi.encodeWithSelector(Conversion.RateStepTooLarge.selector, address(eur), 0.11e18));
        conv.setReferenceRate(address(eur), 0.11e18);
        Rates.set(conv, address(eur), 0.11e18);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InsufficientAvailable.selector);
        cards.authorize(CARD, P1, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
        assertEq(eur.balanceOf(alice), 20_000e6);
    }

    /// @dev Within the agreement band the venue's price decides what the owner pays, not the reference rate: a
    ///      reference moved up within one step never takes more euros than the venue asks for the dollars.
    function test_capture_spendsTheVenuesPriceWhateverTheReferenceRate() public {
        _tokenFirst(100);
        eur.mint(alice, 200e6);
        conv.setReferenceRate(address(eur), 1.105e18);
        uint256 cost = conv.quoteOut(address(eur), address(usd), 100e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        // What a hold at the venue's rate rounds to, within a unit of the venue's own price.
        assertApproxEqAbs(200e6 - eur.balanceOf(alice), cost, 1);
    }

    /// @dev The venue pays a little above the reference rate the hold locked, and the reference moves a little down
    ///      before the capture: the capture still pays exactly what it asked.
    function test_capture_paysWhatItAsksWhenTheVenueBeatsTheReference() public {
        bid.setPrice(1.1005e18);
        _tokenFirst(100);
        eur.mint(alice, 2000e6);
        _authorize(P1, 100e6);
        conv.setReferenceRate(address(eur), 1.0995e18);
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(cards.purchaseOf(P1).captured, 100e6);
        // A larger gap within the band captures too.
        bid.setPrice(1.105e18);
        conv.setReferenceRate(address(eur), 1.098e18);
        _authorize(P2, 100e6);
        _capture(P2, 100e6, true);
        assertEq(usd.balanceOf(settlement), 200e6);
    }

    /// @dev A venue paying far above the reference rate is out of agreement with it: the token covers nothing rather
    ///      than lock a rate a capture cannot honour, and a hold already locked waits for them to agree again.
    function test_venueStrayingFromTheReference_tokenCoversNothing() public {
        _tokenFirst(100);
        eur.mint(alice, 2000e6);
        _authorize(P1, 100e6);
        bid.setPrice(1.2e18);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InsufficientAvailable.selector);
        cards.authorize(CARD, P2, 100e6, merchant, uint64(block.timestamp + 1 days), 0);
        vm.expectPartialRevert(Conversion.RateDeviates.selector);
        this.captureExternal(P1, 100e6);
        bid.setPrice(1.105e18);
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
    }

    function captureExternal(bytes32 ref, uint128 amount) external {
        _capture(ref, amount, true);
    }

    /// @dev A stale reference rate stops the token covering purchases; the owner's other funds still pay.
    function test_staleReferenceRate_skipsTheTokenAndOtherFundsPay() public {
        _tokenFirst(100);
        eur.mint(alice, 5000e6);
        usd.mint(alice, 1000e6);
        vm.warp(block.timestamp + conv.MAX_RATE_AGE() + 1);
        _authorize(P1, 10e6);
        _capture(P1, 10e6, true);
        assertEq(eur.balanceOf(alice), 5000e6);
        assertEq(usd.balanceOf(alice), 990e6);
        assertEq(usd.balanceOf(settlement), 10e6);
    }

    /// @dev Refunds need no reference rate: a stale one, or one moved a hundredfold after the capture, leaves what a
    ///      refund pays back unchanged.
    function test_refund_paysTheSameTokensWhateverTheReferenceRateDoes() public {
        _tokenFirst(100);
        eur.mint(alice, 5000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        uint256 spent = 5000e6 - eur.balanceOf(alice);
        _fundRefunds(usd, 1000e6);
        vm.warp(block.timestamp + conv.MAX_RATE_AGE() + 1);
        vm.prank(issuer);
        cards.refund(P1, 22e6);
        assertEq(eur.balanceOf(alice), 5000e6 - spent + spent * 22 / 100);
        Rates.set(conv, address(eur), 110e18);
        uint256 left = spent - spent * 22 / 100;
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        assertEq(eur.balanceOf(alice), 5000e6 - spent + spent * 22 / 100 + left * 50 / 78);
    }

    /// @dev Without float the refund buys the tokens at the venue instead of reverting.
    function test_refund_buysAtTheVenueWhenTheFloatIsShort() public {
        _tokenFirst(100);
        eur.mint(alice, 5000e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        uint256 before = eur.balanceOf(alice);
        conv.sweep(address(eur), address(0xdead), eur.balanceOf(address(conv)));
        _fundRefunds(usd, 1000e6);
        uint256 fetched = conv.quoteIn(address(usd), address(eur), 50e6);
        vm.prank(issuer);
        cards.refund(P1, 50e6);
        assertEq(eur.balanceOf(alice) - before, fetched);
        assertEq(cards.purchaseOf(P1).refunded, 50e6);
        assertEq(usd.balanceOf(address(cash)), 0);
    }

    // An issuer settling in another stablecoin.

    /// @dev Rewards pay in the token the purchase settled in: a euro issuer's reward on a dollar-funded purchase is euros.
    function test_rewards_payInThePurchasesToken() public {
        Rewards rewards = new Rewards(cards, funder);
        _setting(abi.encodeCall(cards.setCompanion, (address(rewards), true)));
        _localIssuer();
        _usdCash(100);
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        _capture(P1, 40e6, true);
        eur.mint(funder, 1e6);
        vm.prank(funder);
        eur.approve(address(rewards), 1e6);
        vm.prank(issuer);
        rewards.pay(P1, 1e6);
        assertEq(eur.balanceOf(alice), 1e6);
    }

    /// @dev A reward clawed back after the settlement token changed is taken in the purchase's token and valued in
    ///      today's at the mid rate, which is what its funder is owed.
    function test_rewards_clawBackValuedInTodaysToken() public {
        Rewards rewards = new Rewards(cards, funder);
        _setting(abi.encodeCall(cards.setCompanion, (address(rewards), true)));
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        _capture(P1, 40e6, true);
        usd.mint(funder, 1e6);
        vm.prank(funder);
        usd.approve(address(rewards), 1e6);
        vm.prank(issuer);
        rewards.pay(P1, 1e6);
        vm.prank(alice);
        core.approveHolder(address(rewards), address(usd), type(uint128).max, 0);
        _acknowledge();
        cards.setSettlementToken(address(eur), EUR_SCALE);
        uint256 today = 1e6 * conv.mid(address(usd), address(eur)) / 1e18;
        vm.expectEmit(address(rewards));
        emit Rewards.RewardClawedBack(P1, alice, 1e6, today);
        vm.prank(issuer);
        assertEq(rewards.clawBack(P1, 1e6), 1e6);
        assertEq(usd.balanceOf(funder), 1e6);
    }

    function test_localIssuer_cashConvertsAtCaptureAndTheIssuerGetsItsTokenExactly() public {
        _localIssuer();
        _usdCash(100);
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        uint256 held = _hold(alice, P1, CASH_LEG).held;
        assertEq(held, _up(40e6, conv.rate(address(usd), address(eur))));
        uint256 cost = conv.quoteOut(address(usd), address(eur), 40e6);
        _capture(P1, 40e6, true);
        assertEq(eur.balanceOf(settlement), 40e6);
        // At the rate it locked, the whole leg spends the whole hold: the owner pays what the lock promised, and what
        // the venue did not need goes to the settlement account with the capture.
        assertLt(cost, held);
        assertEq(usd.balanceOf(alice), 100e6 - held);
        assertEq(core.available(alice, address(usd)), 100e6 - held);
        assertEq(usd.balanceOf(settlement), held - cost);
        assertEq(usd.balanceOf(address(cash)), 0);
    }

    function test_localIssuer_parLegNeedsNoConversion() public {
        _localIssuer();
        _tokenFirst(0);
        eur.mint(alice, 100e6);
        _authorize(P1, 60e6);
        assertEq(_cashHold(P1, TOKEN_LEG).held, 60e6);
        assertEq(cash.lockedRate(cards.legId(P1, TOKEN_LEG)), 0);
        _capture(P1, 60e6, true);
        assertEq(eur.balanceOf(settlement), 60e6);
        assertEq(eur.balanceOf(alice), 40e6);
    }

    function test_localIssuer_usdCashWithoutAMaxCost_coversNothing() public {
        _localIssuer();
        usd.mint(alice, 100e6);
        assertEq(cash.coverable(alice, _position(address(usd), 0)), 0);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InsufficientAvailable.selector);
        cards.authorize(CARD, P1, 40e6, merchant, uint64(block.timestamp + 7 days), 0);
    }

    function test_localIssuer_partialReversalKeepsHalfRoundedUp() public {
        _localIssuer();
        _usdCash(100);
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        uint256 rate = cash.lockedRate(cards.legId(P1, CASH_LEG));
        uint256 placed = _hold(alice, P1, CASH_LEG).held;
        vm.prank(issuer);
        cards.adjust(P1, 20e6);
        assertEq(_hold(alice, P1, CASH_LEG).held, _up(20e6, rate));
        assertEq(_hold(alice, P1, CASH_LEG).held, (placed + 1) / 2);
    }

    function test_localIssuer_refundPaysTheCardholderAtTheRateTheCapturePaid() public {
        _localIssuer();
        _usdCash(100);
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        _capture(P1, 40e6, true);
        uint256 before = usd.balanceOf(alice);
        uint256 spent = 100e6 - before;
        _fundRefunds(eur, 20e6);
        vm.prank(issuer);
        cards.refund(P1, 20e6);
        assertEq(usd.balanceOf(alice), before + spent / 2);
        assertEq(eur.balanceOf(issuer), 0);
    }

    function test_localIssuer_chargeWithoutEuros_issuerAbsorbsItInItsToken() public {
        _localIssuer();
        _tokenFirst(0);
        vm.prank(issuer);
        cards.charge(CARD, P1, 30e6, merchant);
        assertEq(cards.purchaseOf(P1).token, address(eur));
        assertEq(cards.purchaseOf(P1).refunded, 30e6);
        assertEq(eur.balanceOf(settlement), 0);
        // Euros arriving later stay the owner's: nothing is owed for the absorbed charge.
        eur.mint(alice, 50e6);
        assertEq(core.available(alice, address(eur)), 50e6);
        assertEq(eur.balanceOf(address(cash)), 0);
    }

    function test_localIssuer_forcePostConvertsCashAndRefundsWhatItTook() public {
        _localIssuer();
        _usdCash(100);
        usd.mint(alice, 100e6);
        uint256 cost = conv.quoteOut(address(usd), address(eur), 10e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 10e6, merchant);
        assertEq(usd.balanceOf(alice), 100e6 - cost);
        assertEq(eur.balanceOf(settlement), 10e6);
        _fundRefunds(eur, 10e6);
        vm.prank(issuer);
        cards.refund(P1, 10e6);
        // A full refund gives back every dollar the charge took, whatever the rate does since.
        assertEq(usd.balanceOf(alice), 100e6);
    }

    function test_localIssuer_refundOfAPartlyAbsorbedChargeLandsInItsToken() public {
        _localIssuer();
        _tokenFirst(0);
        eur.mint(alice, 20e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 80e6, merchant);
        assertEq(cards.purchaseOf(P1).token, address(eur));
        assertEq(eur.balanceOf(settlement), 20e6);
        // The issuer absorbed the 60 the owner's euros did not cover, so 20 refunds.
        assertEq(cards.purchaseOf(P1).refunded, 60e6);
        _fundRefunds(eur, 80e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, 20e6 + 1);
        vm.prank(issuer);
        cards.refund(P1, 20e6);
        assertEq(core.available(alice, address(eur)), 20e6);
        assertEq(eur.balanceOf(address(cash)), 0);
        assertEq(eur.balanceOf(issuer), 60e6);
    }

    // Moving the program to another settlement token.

    function test_setSettlementToken_refusedWhilePurchasesAreUnsettled() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 10e6);
        vm.expectRevert(CardLegs.Unsettled.selector);
        cards.setSettlementToken(address(eur), EUR_SCALE);
        _capture(P1, 10e6, true);
        // Captured but not yet acknowledged.
        vm.expectRevert(CardLegs.Unsettled.selector);
        cards.setSettlementToken(address(eur), EUR_SCALE);
        _acknowledge();
        cards.setSettlementToken(address(eur), EUR_SCALE);
        assertEq(cards.settlementToken(), address(eur));
    }

    /// @dev A limit past what base units hold limits nothing: in a token worth less than a dollar it saturates.
    function test_issueCard_unlimitedInACheaperToken() public {
        cards.setSettlementToken(address(eur), EUR_SCALE);
        uint80 max = type(uint64).max;
        bytes32 card = keccak256("eur card");
        vm.prank(issuer);
        cards.issueCard(card, alice, uint40(block.timestamp + 365 days), CardLimits.Limits(max, max, max), 7);
        CardLimits.Limits memory limits = cards.cardOf(card).limits;
        assertEq(limits.perPurchase, type(uint64).max);
        assertEq(limits.monthly, type(uint64).max);
    }

    function test_setSettlementToken_companionOnly() public {
        vm.prank(alice);
        vm.expectRevert(CardAuthBase.NotCompanion.selector);
        cards.setSettlementToken(address(eur), EUR_SCALE);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.NotCompanion.selector);
        cards.setSettlementToken(address(eur), EUR_SCALE);
    }

    function test_refund_earlierTokensPurchase_neverPassesWhatItCaptured() public {
        // Booked in dollars, then the issuer settles in euros: refunds stay in dollars, paid in euros at the scale.
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        _capture(P1, 40e6, true);
        _acknowledge();
        _localIssuer();
        _fundRefunds(eur, 100e6);
        vm.prank(issuer);
        cards.refund(P1, 25e6);
        uint256 paid = 100e6 - eur.balanceOf(issuer);
        assertEq(
            paid, (25e6 * EUR_SCALE + 1e18 - 1) / 1e18, "the issuer pays EUR 22.727273, rounded up for the cardholder"
        );
        // The cash leg converts the euros back to dollars at the reference rate.
        assertEq(usd.balanceOf(alice), 60e6 + paid * 1.1e18 / 1e18);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, 15.01e6);
        vm.prank(issuer);
        cards.refund(P1, 15e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuthBase.InvalidAmount.selector);
        cards.refund(P1, 0.01e6);
        assertEq(cards.purchaseOf(P1).refunded, 40e6);
    }

    /// @dev An earlier era's refund the issuer recovered elsewhere nets to nothing owed: the refund and the credit back
    ///      both round up in today's token.
    function test_creditBack_earlierTokensRecoveredRefund_netsToNothing() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        _capture(P1, 40e6, true);
        _acknowledge();
        _localIssuer();
        _fundRefunds(eur, 100e6);
        vm.prank(issuer);
        cards.refund(P1, 25e6);
        address desk = makeAddr("desk");
        _setting(abi.encodeCall(cards.setCompanion, (desk, true)));
        vm.prank(desk);
        cards.creditBack(P1, 0, -25e6);
        (uint64 seq, uint64 settledThrough, int128 net, int128 settledNet) = cards.ledger();
        assertEq(seq - settledThrough, 2);
        assertEq(net, settledNet);
    }

    function test_refund_earlierTokensSavingsPurchase_paidInTodaysTokenAtTheReferenceRate() public {
        // Booked in dollars on $20 of cash and $25 of savings, then the issuer settles in euros.
        usd.mint(alice, 20e6);
        usd.mint(alice, 100e6);
        _depositEarn(alice, 100e6);
        _authorize(P1, 45e6);
        _capture(P1, 45e6, true);
        assertEq(usd.balanceOf(alice), 0);
        _acknowledge();
        _localIssuer();
        _fundRefunds(eur, 100e6);
        uint256 shares = earnShare.balanceOf(alice);
        vm.prank(issuer);
        cards.refund(P1, 25e6);
        assertEq(
            eur.balanceOf(issuer),
            100e6 - (25e6 * EUR_SCALE + 1e18 - 1) / 1e18,
            "the issuer pays EUR 22.727273, rounded up"
        );
        assertEq(usd.balanceOf(issuer), 0, "and no dollars");
        // The last leg, savings, takes it back first, converted back at the reference rate.
        assertEq(usd.balanceOf(alice), 0, "cash untouched");
        assertApproxEqAbs(earnVault.previewRedeem(earnShare.balanceOf(alice) - shares), 25e6, 2);
    }

    /// @dev A payee's split returned in the token it was paid in converts into today's at the reference rate.
    function test_treasury_convertHeld_atTheReferenceRate() public {
        IssuerTreasury treasury = new IssuerTreasury(ICardAuth(address(cards)));
        conv.setTrusted(address(treasury), true);
        _localIssuer();
        usd.mint(settlement, 0.2e6);
        vm.prank(settlement);
        usd.approve(address(treasury), 0.2e6);
        vm.prank(alice);
        vm.expectRevert(IssuerTreasury.NotIssuer.selector);
        treasury.convertHeld(address(usd));
        vm.prank(settlement);
        vm.expectRevert(IssuerTreasury.WrongAsset.selector);
        treasury.convertHeld(address(eur));
        uint256 before = eur.balanceOf(settlement);
        vm.prank(settlement);
        uint256 out = treasury.convertHeld(address(usd));
        assertEq(out, uint256(0.2e6) * 1e18 / 1.1e18);
        assertEq(eur.balanceOf(settlement) - before, out);
        assertEq(usd.balanceOf(settlement), 0);
    }

    function test_operatorCap_rescalesWithTheSettlementToken() public {
        // A EUR 100 cap; EUR 40 used before the issuer moves to GBP at $1.25.
        FixedPricePool gbpAsk = new FixedPricePool(address(otherUsd), address(usd), 1.25e18);
        otherUsd.mint(address(gbpAsk), 1_000_000e6);
        conv.setVenue(address(usd), address(otherUsd), address(gbpAsk), false);
        Rates.set(conv, address(otherUsd), 1.25e18);
        _localIssuer();
        _tokenFirst(0);
        eur.mint(alice, 500e6);
        address key = makeAddr("key");
        vm.prank(issuer);
        cards.setOperator(key, 7, 100e6);
        vm.prank(key);
        cards.authorize(CARD, P1, 40e6, merchant, uint64(block.timestamp + 7 days), 0);
        assertEq(_capInUnits(key), 100e6 - 1, "within a unit of the cap, in base units");
        assertApproxEqAbs(_usedInUnits(key), 40e6, 1);
        vm.prank(key);
        cards.capture(P1, 40e6, true);
        _acknowledge();
        // GBP per EUR at the reference rates.
        cards.setSettlementToken(address(otherUsd), 0.88e18);
        assertApproxEqAbs(_capInUnits(key), 88e6, 1, "the cap rescales down");
        assertApproxEqAbs(_usedInUnits(key), 35.2e6, 1, "and its use");
        vm.startPrank(alice);
        core.approveHolder(address(cash), address(otherUsd), type(uint128).max, 0);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(otherUsd), 0);
        cards.setFunding(order);
        vm.stopPrank();
        otherUsd.mint(alice, 500e6);
        vm.prank(key);
        vm.expectRevert(CardAuthBase.OperatorCapExceeded.selector);
        cards.authorize(CARD, P2, 52.81e6, merchant, uint64(block.timestamp + 7 days), 0);
        vm.prank(key);
        cards.authorize(CARD, P2, 50e6, merchant, uint64(block.timestamp + 7 days), 0);
        // An increase counts what it adds.
        vm.prank(key);
        vm.expectRevert(CardAuthBase.OperatorCapExceeded.selector);
        cards.adjust(P2, 52.81e6);
        vm.prank(key);
        cards.adjust(P2, 52.8e6);
        // The issuer is not counted.
        vm.prank(issuer);
        cards.authorize(CARD, bytes32("purchase-3"), 100e6, merchant, uint64(block.timestamp + 7 days), 0);
        // Removing the key clears the cap.
        vm.prank(issuer);
        cards.setOperator(key, 0, 0);
        assertEq(cards.operatorOf(key).cap, 0);
        assertFalse(cards.hasRoles(key, 1));
    }

    // Helpers.

    /// @dev Alice's order: EUR cash at up to maxCostBps of conversion cost, then USD cash.
    function _tokenFirst(uint16 maxCostBps) internal {
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = _cashEntry(address(eur), maxCostBps);
        order[1] = _cashEntry(address(usd), maxCostBps);
        vm.prank(alice);
        cards.setFunding(order);
    }

    /// @dev Alice's order: USD cash at up to maxCostBps of conversion cost, then savings.
    function _usdCash(uint16 maxCostBps) internal {
        CardLegs.Funding[] memory order = new CardLegs.Funding[](2);
        order[0] = _cashEntry(address(usd), maxCostBps);
        order[1] = CardLegs.Funding(ISource(address(savings)), bytes32(0));
        vm.prank(alice);
        cards.setFunding(order);
    }

    function _localIssuer() internal {
        cards.setSettlementToken(address(eur), EUR_SCALE);
        assertEq(cards.settlementToken(), address(eur));
    }

    function _acknowledge() internal {
        (uint64 seq,,,) = cards.ledger();
        vm.prank(issuer);
        cards.acknowledgeSettlement(seq);
    }

    function _fundRefunds(ITIP20Token token, uint256 amount) internal {
        token.mint(issuer, amount);
        vm.prank(issuer);
        token.approve(address(cards), type(uint256).max);
    }

    function _capInUnits(address key) internal view returns (uint256) {
        uint96 scale = _scale();
        return uint256(cards.operatorOf(key).cap) * scale / 1e18;
    }

    function _usedInUnits(address key) internal view returns (uint256) {
        uint96 scale = _scale();
        return uint256(cards.operatorOf(key).used) * scale / 1e18;
    }

    /// @dev The current era's scale: today's settlement units per base unit.
    function _scale() internal view returns (uint96 scale) {
        for (uint8 i;; ++i) {
            (address token, uint96 next) = cards.eras(i);
            if (token == address(0)) return scale;
            scale = next;
        }
    }

    function _cashHold(bytes32 ref, uint256 leg) internal view returns (IReservationCore.HoldRecord memory) {
        return core.getHold(alice, address(cash), cards.legId(ref, leg));
    }

    function _up(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return (amount * 1e18 + rate - 1) / rate;
    }
}
