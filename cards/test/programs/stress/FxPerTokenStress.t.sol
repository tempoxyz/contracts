// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { console } from "forge-std/console.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardLegs } from "../../../src/programs/CardLegs.sol";
import { CardLimits } from "../../../src/programs/CardLimits.sol";
import { Conversion } from "../../../src/programs/Conversion.sol";
import { IssuerTreasury } from "../../../src/programs/IssuerTreasury.sol";
import { FixedPricePool } from "../../venues/FixedPricePool.sol";
import { AuthEnv } from "../harness/AuthEnv.sol";
import { Rates } from "../harness/Rates.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice Two converted tokens in one program, each stressed at its own figure: an ARS-like token at 0.001 USD that
///         may move 40% overnight and a EUR-like one at 1.10 USD. Cardholders hold open purchases in both; each token
///         then falls overnight and every purchase captures once the reference rates agree. With ARS at the default
///         figure (10%) the issuer's loss on the ARS book passes its stress share; with ARS at 40% it stays within, while
///         the EUR book keeps 10%. Cardholders let captures run 10% past a hold, so a figure of s covers a move up to
///         1 - (1 - s) / 1.1: about 18% at 10%, 45% at 40%.
contract FxPerTokenStressTest is AuthEnv {
    using FixedPointMathLib for uint256;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant ARS_RATE = 0.001e18;
    uint256 internal constant EUR_RATE = 1.1e18;
    uint256 internal constant SPREAD_BPS = 30;
    uint16 internal constant TOLERANCE_BPS = 1000;
    uint256 internal constant ARS_FIGURE = 4000;

    ITIP20Token internal ars;
    ITIP20Token internal eur;
    Conversion internal conv;
    IssuerTreasury internal treasury;
    address internal sponsor = makeAddr("sponsor");
    mapping(address token => FixedPricePool[2]) internal pools;

    struct Book {
        bytes32[] refs;
        uint128[] amounts;
        uint256 amount;
    }

    Book internal arsBook;
    Book internal eurBook;
    uint256 internal n;

    function setUp() public {
        _deployPrograms();
        conv = new Conversion(address(usd), address(this));
        ars = _fxToken("Peso", "ARSX", ARS_RATE);
        eur = _fxToken("Euro", "EURX", EUR_RATE);
        conv.setTrusted(address(cash), true);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(0), address(0), address(conv))));
        treasury = new IssuerTreasury(cards);
        n = 10 * vm.envOr("STRESS_SCALE", uint256(1));
    }

    /// @dev Before: ARS counts at the default figure, which covers an 18% move, not 40%.
    function test_stress_arsAtTheDefaultFigure_fortyPctMove() public {
        (uint256 arsLoss, uint256 arsShare, uint256 eurLoss, uint256 eurShare) =
            _run("fx_per_token_ars_default_figure", false, 4000, 1800);
        assertGt(arsLoss, arsShare, "the default figure covers a 40% move");
        assertLe(eurLoss, eurShare, "EUR loss past its share");
    }

    /// @dev After: ARS at 40% covers a 40% move; EUR stays at 10%, which still covers 18%.
    function test_stress_arsAtFortyPct_fortyPctMove() public {
        (uint256 arsLoss, uint256 arsShare, uint256 eurLoss, uint256 eurShare) =
            _run("fx_per_token_ars_40pct_figure", true, 4000, 1800);
        assertLe(arsLoss, arsShare, "ARS loss past its share");
        assertLe(eurLoss, eurShare, "EUR loss past its share");
        assertEq(treasury.fxStressOf(address(eur)), 1000);
    }

    /// @dev The figure's edge: a 45% ARS move still fits a 40% figure, 47% does not.
    function test_stress_arsAtFortyPct_coversUpToAboutFortyFivePct() public {
        (uint256 arsLoss, uint256 arsShare,,) = _run("fx_per_token_ars_40pct_move_45", true, 4500, 0);
        assertLe(arsLoss, arsShare, "45% move: ARS loss past its share");
    }

    function test_stress_arsAtFortyPct_fallsShortOfAFortySevenPctMove() public {
        (uint256 arsLoss, uint256 arsShare,,) = _run("fx_per_token_ars_40pct_move_47", true, 4700, 0);
        assertGt(arsLoss, arsShare, "47% move: ARS loss within its share");
    }

    /// @dev With the same collateral the guard admits a smaller ARS book at 40% than at 10%: about 1 / 1.4 of the
    ///      collateral instead of 1 / 1.1.
    function test_stress_guardAdmitsASmallerArsBookAtFortyPct() public {
        uint256 atDefault = _admitted(false);
        uint256 atFigure = _admitted(true);
        _log("fx_per_token_guard", "ars_book_admitted_default_figure", atDefault);
        _log("fx_per_token_guard", "ars_book_admitted_40pct_figure", atFigure);
        assertApproxEqAbs(atDefault, uint256(1000e6) * BPS / 11_000, 10e6);
        assertApproxEqAbs(atFigure, uint256(1000e6) * BPS / 14_000, 10e6);
    }

    // Scenario.

    /// @dev Opens purchases for n cardholders on each token, falls ARS by arsMove and EUR by eurMove (bps) overnight,
    ///      then captures everything once the reference rates agree. Returns each book's issuer loss (settlement
    ///      units the account did not receive) and its stress share before the move.
    function _run(string memory t, bool figure, uint256 arsMove, uint256 eurMove)
        internal
        returns (uint256 arsLoss, uint256 arsShare, uint256 eurLoss, uint256 eurShare)
    {
        vm.pauseGasMetering();
        _collateral(1_000_000_000e6);
        if (figure) {
            vm.prank(issuer);
            treasury.setFxStress(address(ars), ARS_FIGURE);
        }
        _open(ars, arsBook, n);
        _open(eur, eurBook, n);
        uint256 arsOpen = cash.openConvertedOf(address(ars));
        uint256 eurOpen = cash.openConvertedOf(address(eur));
        arsShare = arsOpen.mulDiv(treasury.fxStressOf(address(ars)), BPS);
        eurShare = eurOpen.mulDiv(treasury.fxStressOf(address(eur)), BPS);
        uint256 exposure = treasury.exposure();
        uint256 stressed = treasury.stressedExposure();
        assertApproxEqAbs(stressed, exposure + arsShare + eurShare, 1);
        // Overnight.
        vm.warp(block.timestamp + 12 hours);
        _move(ars, ARS_RATE, arsMove);
        _move(eur, EUR_RATE, eurMove);
        arsLoss = _captureAll(arsBook);
        eurLoss = _captureAll(eurBook);
        assertEq(cash.openConverted(), 0);
        assertEq(treasury.stressedExposure(), treasury.exposure());
        _log(t, "cardholders_per_token", n);
        _log(t, "ars_figure_bps", treasury.fxStressOf(address(ars)));
        _log(t, "eur_figure_bps", treasury.fxStressOf(address(eur)));
        _log(t, "ars_move_bps", arsMove);
        _log(t, "eur_move_bps", eurMove);
        _logAmount(t, "exposure", exposure);
        _logAmount(t, "stressed_exposure", stressed);
        _logAmount(t, "ars_open_converted", arsOpen);
        _logAmount(t, "ars_stress_share", arsShare);
        _logAmount(t, "ars_issuer_loss", arsLoss);
        _log(t, "ars_loss_bps_of_open", arsLoss * BPS / arsOpen);
        _logAmount(t, "eur_open_converted", eurOpen);
        _logAmount(t, "eur_stress_share", eurShare);
        _logAmount(t, "eur_issuer_loss", eurLoss);
        _log(t, "eur_loss_bps_of_open", eurOpen == 0 ? 0 : eurLoss * BPS / eurOpen);
        _log(t, "ars_covered", arsLoss <= arsShare ? 1 : 0);
        _log(t, "eur_covered", eurLoss <= eurShare ? 1 : 0);
    }

    /// @dev How much of an ARS book (in settlement units, 10 at a time) the guard admits against 1,000 of collateral.
    function _admitted(bool figure) internal returns (uint256 book) {
        uint256 snap = vm.snapshotState();
        _collateral(1000e6);
        if (figure) {
            vm.prank(issuer);
            treasury.setFxStress(address(ars), ARS_FIGURE);
        }
        address h = _holder(ars, 0);
        bytes32 card = keccak256(abi.encode("card", h));
        for (uint256 i;; ++i) {
            vm.prank(issuer);
            try cards.authorize(
                card, keccak256(abi.encode("guard", i)), 10e6, merchant, uint64(block.timestamp + 7 days), 0
            ) {
                book += 10e6;
            } catch {
                break;
            }
        }
        vm.revertToState(snap);
    }

    function _open(ITIP20Token token, Book storage book, uint256 count) internal {
        for (uint256 i; i < count; ++i) {
            address h = _holder(token, i);
            bytes32 card = keccak256(abi.encode("card", h));
            for (uint256 j; j < 3; ++j) {
                bytes32 ref = keccak256(abi.encode(address(token), i, j));
                // 50 to 150 dollars.
                uint128 amount = uint128(50e6 + (uint256(ref) % 101) * 1e6);
                vm.prank(issuer);
                cards.authorize(card, ref, amount, merchant, uint64(block.timestamp + 7 days), 0);
                assertGt(core.reserved(h, address(token)), 0);
                book.refs.push(ref);
                book.amounts.push(amount);
                book.amount += amount;
            }
        }
    }

    /// @dev Captures every purchase of a book in full; returns what the settlement account fell short of their amount.
    function _captureAll(Book storage book) internal returns (uint256 loss) {
        uint256 before = usd.balanceOf(settlement);
        for (uint256 i; i < book.refs.length; ++i) {
            vm.prank(issuer);
            cards.capture(book.refs[i], book.amounts[i], true);
        }
        uint256 received = usd.balanceOf(settlement) - before;
        loss = book.amount > received ? book.amount - received : 0;
    }

    /// @dev Moves token's venues down by moveBps of rate and has the reference rate follow.
    function _move(ITIP20Token token, uint256 rate, uint256 moveBps) internal {
        if (moveBps == 0) return;
        uint256 mid = rate * (BPS - moveBps) / BPS;
        pools[address(token)][0].setPrice(mid.mulDiv(BPS - SPREAD_BPS, BPS));
        pools[address(token)][1].setPrice(mid.mulDivUp(BPS, BPS - SPREAD_BPS));
        Rates.set(conv, address(token), mid);
    }

    // World.

    function _fxToken(string memory name, string memory symbol, uint256 rate) internal returns (ITIP20Token token) {
        token = _createToken(name, symbol);
        FixedPricePool bid = new FixedPricePool(address(token), address(usd), rate.mulDiv(BPS - SPREAD_BPS, BPS));
        FixedPricePool ask = new FixedPricePool(address(token), address(usd), rate.mulDivUp(BPS, BPS - SPREAD_BPS));
        usd.mint(address(bid), 1e15);
        token.mint(address(ask), 1e18);
        conv.setVenue(address(token), address(usd), address(bid), true);
        conv.setVenue(address(usd), address(token), address(ask), false);
        Rates.set(conv, address(token), rate);
        usd.mint(address(conv), 1e13);
        token.mint(address(conv), 1e16);
        pools[address(token)] = [bid, ask];
    }

    /// @dev Cardholder i of token: a card whose order lists only token, with plenty of it and a 10% tolerance.
    function _holder(ITIP20Token token, uint256 i) internal returns (address h) {
        h = makeAddr(string.concat(token.symbol(), "-holder-", vm.toString(i)));
        bytes32 card = keccak256(abi.encode("card", h));
        if (cards.cardOf(card).owner != address(0)) return h;
        vm.prank(issuer);
        cards.issueCard(card, h, uint40(block.timestamp + 365 days), _limits(1e12, 1e13, 1e14), 7);
        CardLegs.Funding[] memory order = new CardLegs.Funding[](1);
        order[0] = _cashEntry(address(token), 100);
        vm.startPrank(h);
        core.approveHolder(address(cash), address(token), type(uint128).max, 0);
        cards.setFunding(order);
        cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
        vm.stopPrank();
        _setTolerance(h, address(cash), address(token), TOLERANCE_BPS);
        token.mint(h, address(token) == address(ars) ? 1e14 : 1e11);
    }

    /// @dev The settlement account pledges units of collateral and the treasury becomes the exposure guard.
    function _collateral(uint256 units) internal {
        usd.mint(settlement, units);
        vm.startPrank(settlement);
        core.pledge(
            address(treasury), address(usd), treasury.pledgeId(1), uint128(units), uint64(block.timestamp + 365 days)
        );
        treasury.post(sponsor, IEarnVault(address(0)), 1);
        vm.stopPrank();
        _setting(abi.encodeCall(cards.setExposureGuard, (address(treasury))));
    }

    function _log(string memory test, string memory metric, uint256 value) internal pure {
        console.log(string.concat("STRESS ", test, " ", metric, "=", vm.toString(value)));
    }

    /// @dev Logs a 6-decimal amount with two decimals.
    function _logAmount(string memory test, string memory metric, uint256 value) internal pure {
        uint256 cents = value / 1e4;
        string memory frac = vm.toString(cents % 100);
        if (cents % 100 < 10) frac = string.concat("0", frac);
        console.log(string.concat("STRESS ", test, " ", metric, "=", vm.toString(cents / 100), ".", frac));
    }
}
