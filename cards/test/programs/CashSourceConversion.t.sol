// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardAuth } from "../../src/programs/CardAuth.sol";
import { CardLegs } from "../../src/programs/CardLegs.sol";
import { CardLimits } from "../../src/programs/CardLimits.sol";
import { Conversion } from "../../src/programs/Conversion.sol";
import { Rewards } from "../../src/programs/Rewards.sol";
import { IReservationCore } from "../../src/programs/interfaces/IReservationCore.sol";
import { ISource } from "../../src/programs/interfaces/ISource.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { AuthEnv } from "./harness/AuthEnv.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Purchases funded in another stablecoin through the cash source, and issuers settling in one: rate locks at
///         authorization, the capture that pays the issuer exactly, slippage within the owner's tolerance, re-quotes
///         once it lapses, reversals that keep the leg's share rounded up, refunds at the reference rate, and moving
///         the program to another settlement token.
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
        conv.setReferenceRate(address(eur), 1.1e18);
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

    function test_capture_withinToleranceThePriceTheHoldLocked() public {
        vm.prank(alice);
        conv.setRateTolerance(address(cash), 200);
        _tokenFirst(100);
        eur.mint(alice, 200e6);
        _authorize(P1, 100e6);
        uint256 held = _cashHold(P1, TOKEN_LEG).held;
        // The euro falls 1%: the cardholder pays only the euros the hold locked, and the issuer carries the slippage.
        bid.setPrice(BID * 99 / 100);
        conv.setReferenceRate(address(eur), 1.1e18 * 99 / 100);
        assertFalse(_lapsed(cards.legId(P1, TOKEN_LEG)));
        _capture(P1, 100e6, true);
        uint256 paid = usd.balanceOf(settlement);
        assertEq(paid, held * (BID * 99 / 100) / 1e18);
        assertLt(paid, 100e6);
        assertEq(eur.balanceOf(alice), 200e6 - held);
        assertEq(cards.purchaseOf(P1).refunded, 100e6 - paid, "the issuer absorbs the slippage");
    }

    function test_capture_pastToleranceRequotesAndCostsTheCardholderMore() public {
        vm.prank(alice);
        conv.setRateTolerance(address(cash), 200);
        // The owner lets the cash source capture up to 10% past a hold.
        _setTolerance(alice, address(cash), address(eur), 1000);
        _tokenFirst(100);
        eur.mint(alice, 200e6);
        _authorize(P1, 100e6);
        uint256 held = _cashHold(P1, TOKEN_LEG).held;
        bid.setPrice(BID * 95 / 100);
        conv.setReferenceRate(address(eur), 1.1e18 * 95 / 100);
        uint256 cost = conv.quoteOut(address(eur), address(usd), 100e6);
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        uint256 spent = 200e6 - eur.balanceOf(alice);
        assertGt(spent, held);
        assertEq(spent, cost);
    }

    function test_capture_pastTolerance_neverPastWhatTheOwnerAllowsPastTheHold() public {
        vm.prank(alice);
        conv.setRateTolerance(address(cash), 200);
        _tokenFirst(100);
        eur.mint(alice, 200e6);
        _authorize(P1, 100e6);
        uint256 held = _cashHold(P1, TOKEN_LEG).held;
        bid.setPrice(BID * 95 / 100);
        conv.setReferenceRate(address(eur), 1.1e18 * 95 / 100);
        assertTrue(_lapsed(cards.legId(P1, TOKEN_LEG)));
        // The lock lapsed, but with no tolerance past the hold the owner spends only the hold; the issuer gets what
        // it buys and absorbs the rest.
        _capture(P1, 100e6, true);
        assertEq(eur.balanceOf(alice), 200e6 - held);
        uint256 paid = usd.balanceOf(settlement);
        assertLt(paid, 100e6);
        assertEq(cards.purchaseOf(P1).refunded, 100e6 - paid);
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
        assertEq(cards.purchaseOf(P1).refunded, 80e6 - paid);
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
        conv.setReferenceRate(address(eur), 1.1e18 * 101 / 100);
        vm.prank(issuer);
        cards.adjust(P1, 60e6);
        assertEq(cash.lockedRate(leg), conv.rate(address(eur), address(usd)));
        assertApproxEqAbs(cash.held(alice, _position(address(eur), 100), leg), 60e6, 1);
    }

    function test_refund_paysTheTokenBackAtTheReferenceRate() public {
        _tokenFirst(100);
        eur.mint(alice, 200e6);
        _authorize(P1, 100e6);
        _capture(P1, 100e6, true);
        uint256 before = eur.balanceOf(alice);
        _fundRefunds(usd, 22e6);
        vm.prank(issuer);
        cards.refund(P1, 22e6);
        assertEq(eur.balanceOf(alice), before + 20e6);
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
        // A refund converts back at the reference rate the charge kept.
        assertEq(cash.lockedRate(cards.legId(P1, TOKEN_LEG)), conv.mid(address(eur), address(usd)));
        // A foreign token never becomes debt: past the owner's euros the issuer absorbs the charge.
        _setDebtCap(alice, address(cash), address(eur), 500e6);
        vm.prank(issuer);
        cards.charge(CARD, P2, 200e6, merchant);
        assertEq(eur.balanceOf(alice), 0);
        assertEq(_owed(alice, address(eur), address(cash)), 0);
        // Too costly a conversion takes nothing.
        _tokenFirst(20);
        eur.mint(alice, 100e6);
        vm.prank(issuer);
        cards.charge(CARD, bytes32("purchase-3"), 10e6, merchant);
        assertEq(eur.balanceOf(alice), 100e6);
        assertEq(cards.purchaseOf(bytes32("purchase-3")).refunded, 10e6);
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
        vm.expectRevert(CardAuth.InsufficientAvailable.selector);
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

    function test_localIssuer_refundPaysTheCardholderAtTheReferenceRate() public {
        _localIssuer();
        _usdCash(100);
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        _capture(P1, 40e6, true);
        uint256 before = usd.balanceOf(alice);
        _fundRefunds(eur, 20e6);
        vm.prank(issuer);
        cards.refund(P1, 20e6);
        assertEq(usd.balanceOf(alice), before + 22e6);
        assertEq(eur.balanceOf(issuer), 0);
    }

    function test_localIssuer_lateChargeIsOwedInItsToken() public {
        _localIssuer();
        _tokenFirst(0);
        _setDebtCap(alice, address(cash), address(eur), 50e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 30e6, merchant);
        assertEq(_owed(alice, address(eur), address(cash)), 30e6);
        assertEq(cards.purchaseOf(P1).refunded, 0);
        // Euros arriving later repay the source, which forwards them to the settlement account.
        eur.mint(alice, 50e6);
        _repay(alice, address(eur));
        assertEq(_owed(alice, address(eur), address(cash)), 0);
        cash.sweep(address(eur));
        assertEq(eur.balanceOf(settlement), 30e6);
        assertEq(eur.balanceOf(alice), 20e6);
    }

    function test_localIssuer_forcePostConvertsCashAndRefundsItAtTodaysRate() public {
        _localIssuer();
        _usdCash(100);
        usd.mint(alice, 100e6);
        uint256 cost = conv.quoteOut(address(usd), address(eur), 10e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 10e6, merchant);
        assertEq(usd.balanceOf(alice), 100e6 - cost);
        assertEq(eur.balanceOf(settlement), 10e6);
        assertEq(_owed(alice, address(eur), address(cash)), 0);
        _fundRefunds(eur, 10e6);
        vm.prank(issuer);
        cards.refund(P1, 10e6);
        // The refund gives the USD cash back at today's reference rate, not the venue's price.
        uint256 mid = conv.mid(address(usd), address(eur));
        assertEq(usd.balanceOf(alice), 100e6 - cost + 10e6 * 1e18 / mid);
    }

    function test_localIssuer_refundPastDebtCapRepaysAndLandsTheRestInItsToken() public {
        _localIssuer();
        _tokenFirst(0);
        eur.mint(alice, 20e6);
        _setDebtCap(alice, address(cash), address(eur), 50e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 80e6, merchant);
        assertEq(cards.purchaseOf(P1).token, address(eur));
        assertEq(_owed(alice, address(eur), address(cash)), 50e6);
        // The issuer absorbed the 10 neither cash nor debt covered, so 70 refunds.
        assertEq(cards.purchaseOf(P1).refunded, 10e6);
        _fundRefunds(eur, 80e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 70e6 + 1);
        vm.prank(issuer);
        cards.refund(P1, 70e6);
        assertEq(_owed(alice, address(eur), address(cash)), 0);
        assertEq(core.available(alice, address(eur)), 20e6);
        // The forgiven debt stays with the source until it is swept to the settlement account.
        assertEq(eur.balanceOf(address(cash)), 50e6);
        assertEq(eur.balanceOf(issuer), 10e6);
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
        vm.expectRevert(CardAuth.NotCompanion.selector);
        cards.setSettlementToken(address(eur), EUR_SCALE);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.NotCompanion.selector);
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
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 15.01e6);
        vm.prank(issuer);
        cards.refund(P1, 15e6);
        vm.prank(issuer);
        vm.expectRevert(CardAuth.InvalidAmount.selector);
        cards.refund(P1, 0.01e6);
        assertEq(cards.purchaseOf(P1).refunded, 40e6);
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

    function test_operatorCap_rescalesWithTheSettlementToken() public {
        // A EUR 100 cap; EUR 40 used before the issuer moves to GBP at $1.25.
        FixedPricePool gbpAsk = new FixedPricePool(address(otherUsd), address(usd), 1.25e18);
        otherUsd.mint(address(gbpAsk), 1_000_000e6);
        conv.setVenue(address(usd), address(otherUsd), address(gbpAsk), false);
        conv.setReferenceRate(address(otherUsd), 1.25e18);
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
        vm.expectRevert(CardAuth.OperatorCapExceeded.selector);
        cards.authorize(CARD, P2, 52.81e6, merchant, uint64(block.timestamp + 7 days), 0);
        // A stand-in approval counts too.
        uint8 standIn = cards.STAND_IN();
        vm.prank(key);
        vm.expectRevert(CardAuth.OperatorCapExceeded.selector);
        cards.authorize(CARD, P2, 52.81e6, merchant, uint64(block.timestamp + 7 days), standIn);
        vm.prank(key);
        cards.authorize(CARD, P2, 50e6, merchant, uint64(block.timestamp + 7 days), 0);
        // An increase counts what it adds.
        vm.prank(key);
        vm.expectRevert(CardAuth.OperatorCapExceeded.selector);
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

    function _lapsed(bytes32 leg) internal returns (bool lapsed) {
        uint256 locked = cash.lockedRate(leg);
        uint256 current = conv.rate(address(eur), address(usd));
        vm.prank(address(cash));
        lapsed = conv.lapsed(alice, locked, current);
    }

    function _cashHold(bytes32 ref, uint256 leg) internal view returns (IReservationCore.HoldRecord memory) {
        return core.getHold(alice, address(cash), cards.legId(ref, leg));
    }

    function _up(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return (amount * 1e18 + rate - 1) / rate;
    }
}
