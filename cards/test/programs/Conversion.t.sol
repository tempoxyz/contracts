// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardFunding } from "../../src/programs/CardFunding.sol";
import { CardProgram } from "../../src/programs/CardProgram.sol";
import { Conversion } from "../../src/programs/Conversion.sol";
import { IssuerDesk } from "../../src/programs/IssuerDesk.sol";
import { FixedPricePool } from "../venues/FixedPricePool.sol";
import { ProgramsEnv } from "./harness/ProgramsEnv.sol";

/// @notice Purchases funded in another stablecoin, and issuers settling in one: rate locks at authorization, the
///         capture that pays the issuer exactly, slippage within the owner's tolerance, re-quotes once it lapses,
///         reversals that keep the leg's share rounded up and refunds at the reference rate.
contract ConversionTest is ProgramsEnv {
    bytes32 internal constant P1 = bytes32("purchase-1");
    bytes32 internal constant P2 = bytes32("purchase-2");
    uint8 internal constant CASH = 1;
    uint8 internal constant TOKEN = 64;
    // EUR at $1.10 with a 30 bps conversion cost each way.
    uint256 internal constant BID = 1.0967e18;
    uint256 internal constant ASK = 1_103_310_000_000_000_000; // ~1.1 / 0.997

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
        conv.setTrusted(address(cards), true);
        usd.mint(address(conv), 100_000e6);
        eur.mint(address(conv), 100_000e6);
        vm.prank(issuer);
        cards.setConversion(address(conv));
        vm.startPrank(alice);
        core.approveHolder(address(cards), address(eur), type(uint128).max);
        vm.stopPrank();
    }

    // Conversion on its own.

    function test_quotes_routeThroughTheHub() public {
        FixedPricePool gbpAsk = new FixedPricePool(address(otherUsd), address(usd), 1.25e18);
        otherUsd.mint(address(gbpAsk), 1_000_000e6);
        conv.setVenue(address(usd), address(otherUsd), address(gbpAsk), false);
        assertTrue(conv.converts(address(eur), address(otherUsd)));
        assertFalse(conv.converts(address(otherUsd), address(eur)));
        uint256 out = conv.quoteIn(address(eur), address(otherUsd), 100e6);
        assertEq(out, uint256(100e6) * BID / 1e18 * 1e18 / 1.25e18);
        eur.mint(bob, 100e6);
        vm.startPrank(bob);
        eur.approve(address(conv), 100e6);
        assertEq(conv.swapExactIn(address(eur), address(otherUsd), 100e6, out, bob), out);
        vm.stopPrank();
        assertEq(otherUsd.balanceOf(bob), out);
        assertEq(eur.balanceOf(address(conv)), 100_000e6, "no float used");
    }

    function test_swapExactOut_paysExactlyAndPullsOnlyWhatItSpends() public {
        uint256 cost = conv.quoteOut(address(eur), address(usd), 50e6);
        eur.mint(bob, 100e6);
        vm.startPrank(bob);
        eur.approve(address(conv), type(uint256).max);
        assertEq(conv.swapExactOut(address(eur), address(usd), 50e6, cost, bob), cost);
        vm.stopPrank();
        assertEq(usd.balanceOf(bob), 50e6);
        assertEq(eur.balanceOf(bob), 100e6 - cost);
    }

    function test_swapExactOut_revertsPastTheBound() public {
        uint256 cost = conv.quoteOut(address(eur), address(usd), 50e6);
        eur.mint(bob, 100e6);
        vm.startPrank(bob);
        eur.approve(address(conv), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Conversion.Slippage.selector, cost, cost - 1));
        conv.swapExactOut(address(eur), address(usd), 50e6, cost - 1, bob);
        vm.stopPrank();
    }

    function test_costBps_measuresAgainstTheReferenceRate() public view {
        assertEq(conv.costBps(address(eur), address(usd), conv.rate(address(eur), address(usd))), 30);
        assertEq(conv.costBps(address(eur), address(usd), 1.2e18), 0);
    }

    function test_lapsed_followsTheOwnersToleranceForTheCallingProgram() public {
        vm.prank(alice);
        conv.setRateTolerance(address(cards), 200);
        vm.startPrank(address(cards));
        assertFalse(conv.lapsed(alice, 1e18, 1.02e18));
        assertTrue(conv.lapsed(alice, 1e18, 1.0201e18));
        vm.stopPrank();
        // Another program sees no tolerance, so its locks never lapse.
        assertFalse(conv.lapsed(alice, 1e18, 2e18));
    }

    function test_configuration_isTheOwnersAlone() public {
        vm.startPrank(bob);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.setVenue(address(eur), address(usd), address(bid), true);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.setReferenceRate(address(eur), 2e18);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.setTrusted(bob, true);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.sweep(address(eur), bob, 1);
        vm.expectRevert(Conversion.InvalidAmount.selector);
        conv.setRateTolerance(address(cards), 10_001);
        vm.stopPrank();
    }

    function test_convertAtMid_onlyForTrustedPrograms() public {
        usd.mint(bob, 10e6);
        vm.startPrank(bob);
        usd.approve(address(conv), 10e6);
        vm.expectRevert(Conversion.Unauthorized.selector);
        conv.convertAtMid(address(usd), address(eur), 10e6, bob);
        vm.stopPrank();
    }

    // Purchases in another stablecoin, for a USD issuer.

    function test_tokenLeg_locksTheRateAndPaysTheIssuerExactly() public {
        _tokenFirst(alice, 100);
        eur.mint(alice, 200e6);
        _authorize(P1, 100e6);
        assertEq(cards.lockedRate(cards.legId(P1, TOKEN)), BID);
        uint256 held = _hold(alice, P1, TOKEN).held;
        assertEq(held, _up(100e6, BID));
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        assertEq(eur.balanceOf(alice), 200e6 - conv.quoteOut(address(eur), address(usd), 100e6));
        assertEq(core.reserved(alice, address(eur)), 0);
        assertEq(eur.balanceOf(address(cards)), 0, "nothing left in the program");
        assertEq(usd.balanceOf(address(cards)), 0, "nothing left in the program");
    }

    function test_tokenLeg_skippedWhileConvertingCostsMoreThanAllowed() public {
        _tokenFirst(alice, 20);
        eur.mint(alice, 200e6);
        usd.mint(alice, 100e6);
        _authorize(P1, 50e6);
        assertEq(_hold(alice, P1, TOKEN).held, 0);
        assertEq(_hold(alice, P1, CASH).held, 50e6);
    }

    function test_capture_withinToleranceThePriceTheHoldLocked() public {
        vm.prank(alice);
        conv.setRateTolerance(address(cards), 200);
        _tokenFirst(alice, 100);
        eur.mint(alice, 200e6);
        _authorize(P1, 100e6);
        uint256 held = _hold(alice, P1, TOKEN).held;
        // The euro falls 1%: the cardholder pays only the euros the hold locked, and the issuer carries the slippage.
        bid.setPrice(BID * 99 / 100);
        _capture(P1, 100e6, true);
        uint256 paid = usd.balanceOf(settlement);
        assertEq(paid, held * (BID * 99 / 100) / 1e18);
        assertLt(paid, 100e6);
        assertEq(eur.balanceOf(alice), 200e6 - held);
    }

    function test_capture_pastToleranceRequotesAndCostsTheCardholderMore() public {
        vm.prank(alice);
        conv.setRateTolerance(address(cards), 200);
        _tokenFirst(alice, 100);
        eur.mint(alice, 200e6);
        _authorize(P1, 100e6);
        uint256 held = _hold(alice, P1, TOKEN).held;
        bid.setPrice(BID * 95 / 100);
        _capture(P1, 100e6, true);
        assertEq(usd.balanceOf(settlement), 100e6);
        uint256 spent = 200e6 - eur.balanceOf(alice);
        assertGt(spent, held);
        assertEq(spent, conv.quoteOut(address(eur), address(usd), 100e6));
    }

    function test_capture_neverSpendsMoreThanTheOwnerHas() public {
        _tokenFirst(alice, 100);
        eur.mint(alice, 50e6);
        _authorize(P1, 50e6);
        vm.expectRevert();
        _capture(P1, 100e6, true);
    }

    // An issuer settling in another stablecoin.

    function test_localIssuer_cashConvertsAtCaptureAndTheIssuerGetsItsTokenExactly() public {
        _localIssuer();
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        uint256 held = _hold(alice, P1, CASH).held;
        assertEq(held, _up(40e6, uint256(1e18) * 1e18 / ASK));
        uint256 cost = conv.quoteOut(address(usd), address(eur), 40e6);
        _capture(P1, 40e6, true);
        assertEq(eur.balanceOf(settlement), 40e6);
        // At the locked rate the owner pays the whole hold; the venue's rounding left over reaches the settlement account.
        assertEq(usd.balanceOf(alice), 100e6 - held);
        assertEq(usd.balanceOf(settlement), held - cost);
    }

    function test_localIssuer_parLegNeedsNoConversion() public {
        _localIssuer();
        _tokenFirst(alice, 0);
        eur.mint(alice, 100e6);
        _authorize(P1, 60e6);
        assertEq(_hold(alice, P1, TOKEN).held, 60e6);
        _capture(P1, 60e6, true);
        assertEq(eur.balanceOf(settlement), 60e6);
        assertEq(eur.balanceOf(alice), 40e6);
    }

    function test_localIssuer_partialReversalKeepsHalfRoundedUp() public {
        _localIssuer();
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        uint256 placed = _hold(alice, P1, CASH).held;
        vm.prank(issuer);
        cards.adjust(P1, 20e6);
        assertEq(_hold(alice, P1, CASH).held, (placed + 1) / 2);
    }

    function test_localIssuer_refundPaysTheCardholderAtTheReferenceRate() public {
        _localIssuer();
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        _capture(P1, 40e6, true);
        uint256 cash = usd.balanceOf(alice);
        eur.mint(issuer, 20e6);
        vm.prank(issuer);
        eur.approve(address(cards), 20e6);
        vm.prank(issuer);
        cards.refund(P1, 20e6);
        assertEq(usd.balanceOf(alice), cash + 22e6);
        assertEq(eur.balanceOf(issuer), 0);
    }

    function test_localIssuer_lateChargeIsOwedInItsTokenAndCashRepaysItThroughTheVenue() public {
        _localIssuer();
        vm.prank(alice);
        core.setDebtCap(address(cards), address(eur), 50e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 30e6, merchant);
        (address creditor, uint128 debt) = core.debtOf(alice, address(eur));
        assertEq(creditor, address(cards));
        assertEq(debt, 30e6);
        // The debt is in the program's exposure, so the issuer keeps its token until it is repaid.
        (, uint256 owing, uint256 debtors) = cards.outstanding();
        assertEq(owing, 30e6);
        assertEq(debtors, 1);
        (uint64 seq,,,) = cards.ledger();
        vm.startPrank(issuer);
        cards.acknowledgeSettlement(seq);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettlementTokenInUse.selector, uint8(3)));
        cards.setSettlementToken(address(usd));
        vm.stopPrank();
        // Cash arriving later converts to repay the euro debt, and the issuer gets its token.
        usd.mint(alice, 50e6);
        uint256 cost = conv.quoteOut(address(usd), address(eur), 30e6);
        cards.repayConverted(alice);
        // The node repays debt from each credit as it lands; the model does it on the next operation.
        core.repay(alice, address(eur));
        (, debt) = core.debtOf(alice, address(eur));
        assertEq(debt, 0);
        assertEq(usd.balanceOf(alice), 50e6 - cost);
        assertEq(eur.balanceOf(alice), 0);
        assertEq(eur.balanceOf(address(cards)), 30e6);
        (, owing,) = cards.outstanding();
        assertEq(owing, 0);
        // Nothing owed, nothing taken.
        assertEq(cards.repayConverted(alice), 0);
        assertEq(usd.balanceOf(alice), 50e6 - cost);
    }

    function test_localIssuer_partRepaysWithWhatCashThereIs() public {
        _localIssuer();
        vm.prank(alice);
        core.setDebtCap(address(cards), address(eur), 50e6);
        vm.prank(issuer);
        cards.charge(CARD, P1, 30e6, merchant);
        usd.mint(alice, 11e6);
        uint256 repaid = conv.quoteIn(address(usd), address(eur), 11e6);
        cards.repayConverted(alice);
        core.repay(alice, address(eur));
        (, uint128 debt) = core.debtOf(alice, address(eur));
        assertEq(debt, 30e6 - repaid);
        assertEq(usd.balanceOf(alice), 0);
    }

    function test_setSettlementToken_refusedWhilePurchasesAreUnsettled() public {
        usd.mint(alice, 100e6);
        _authorize(P1, 10e6);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettlementTokenInUse.selector, uint8(1)));
        cards.setSettlementToken(address(eur));
    }

    function test_setSettlementToken_refusedWhileTheSettlementBalanceIsLiened() public {
        _localIssuer();
        eur.mint(settlement, 10e6);
        address authority = makeAddr("authority");
        core.grantLienRole(authority, true);
        vm.prank(authority);
        core.lien(settlement, address(eur), bytes32("freeze"), 5e6, 0);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(CardProgram.SettlementTokenInUse.selector, uint8(6)));
        cards.setSettlementToken(address(usd));
        vm.prank(authority);
        core.releaseLien(bytes32("freeze"));
        assertEq(core.liened(settlement, address(eur)), 0);
    }

    function test_desk_refundsAnEarlierTokensPurchaseInTodaysTokenAndKeepsItsSplitsInTheOld() public {
        IssuerDesk desk = new IssuerDesk(cards);
        address network = makeAddr("network");
        IssuerDesk.Line[] memory lines = new IssuerDesk.Line[](1);
        lines[0] = IssuerDesk.Line({ payee: network, bps: 100, kind: "interchange" });
        vm.startPrank(issuer);
        cards.setOperator(address(desk), true);
        desk.setTerms(lines);
        vm.stopPrank();
        vm.startPrank(settlement);
        usd.approve(address(desk), type(uint256).max);
        eur.approve(address(desk), type(uint256).max);
        vm.stopPrank();
        vm.prank(network);
        core.approveHolder(address(desk), address(usd), type(uint128).max);
        // Booked in dollars, then the issuer settles in euros.
        usd.mint(alice, 100e6);
        _authorize(P1, 40e6);
        vm.prank(issuer);
        desk.capture(P1, 40e6, true);
        assertEq(usd.balanceOf(network), 0.4e6);
        (uint64 seq,,,) = cards.ledger();
        vm.startPrank(issuer);
        cards.acknowledgeSettlement(seq);
        cards.setSettlementToken(address(eur));
        vm.stopPrank();
        // A $22 refund costs the issuer EUR 20 at the reference rate, and the network gives back its dollar split.
        uint256 cash = usd.balanceOf(alice);
        eur.mint(settlement, 50e6);
        vm.prank(issuer);
        desk.refund(P1, 22e6);
        assertEq(usd.balanceOf(alice), cash + 22e6);
        assertEq(eur.balanceOf(settlement), 30e6);
        assertEq(eur.balanceOf(address(desk)), 0);
        assertEq(usd.balanceOf(network), 0.18e6);
        // The rest refunds, and nothing past what it captured.
        vm.prank(issuer);
        desk.refund(P1, 18e6);
        assertEq(usd.balanceOf(alice), cash + 40e6);
        vm.prank(issuer);
        vm.expectRevert();
        desk.refund(P1, 0.01e6);
    }

    function test_setSettlementToken_issuerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        cards.setSettlementToken(address(eur));
    }

    function test_setOrder_rejectsBadTokenEntries() public {
        CardFunding.Source[] memory order = new CardFunding.Source[](1);
        order[0] = CardFunding.Source({ kind: TOKEN, source: address(usd), lineId: 0 });
        vm.prank(alice);
        vm.expectRevert(CardFunding.InvalidOrder.selector);
        cards.setFunding(address(usd), order);
        order[0] = CardFunding.Source({ kind: TOKEN, source: address(eur), lineId: 10_001 });
        vm.prank(alice);
        vm.expectRevert(CardFunding.InvalidOrder.selector);
        cards.setFunding(address(usd), order);
    }

    // Helpers.

    function _tokenFirst(address owner, uint64 maxCostBps) internal {
        CardFunding.Source[] memory order = new CardFunding.Source[](2);
        order[0] = CardFunding.Source({ kind: TOKEN, source: address(eur), lineId: maxCostBps });
        order[1] = CardFunding.Source({ kind: CASH, source: address(usd), lineId: 0 });
        vm.prank(owner);
        cards.setFunding(address(usd), order);
    }

    function _localIssuer() internal {
        vm.prank(issuer);
        cards.setSettlementToken(address(eur));
        assertEq(cards.settlementToken(), address(eur));
    }

    function _up(uint256 amount, uint256 rate) internal pure returns (uint256) {
        return (amount * 1e18 + rate - 1) / rate;
    }
}
