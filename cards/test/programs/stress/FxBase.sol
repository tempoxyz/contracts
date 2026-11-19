// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { console } from "forge-std/console.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";

import { CardLegs } from "../../../src/programs/CardLegs.sol";
import { CardLimits } from "../../../src/programs/CardLimits.sol";
import { Conversion } from "../../../src/programs/Conversion.sol";
import { FixedPricePool } from "../../venues/FixedPricePool.sol";
import { AuthEnv } from "../harness/AuthEnv.sol";
import { Rates } from "../harness/Rates.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/// @notice A many-cardholder world for stressing converted legs: a second stablecoin LCL priced in USD by a market the
///         test moves (USD per LCL, 18 decimals), venues quoting it with a spread, a Conversion whose reference rate a
///         keeper moves within the contract's step, delay and age rules, and a driver that swipes, captures and
///         releases day by day while checking that no value appears, disappears or lands outside the known parties.
abstract contract FxBase is AuthEnv {
    using FixedPointMathLib for uint256;

    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant DEPTH = 1e15;
    /// @dev Monday 2026-11-02 00:00 UTC; simulations start a week later, also on a Monday.
    uint256 internal constant MONDAY = 1_793_577_600;

    /// @dev One purchase the driver tracks.
    struct Buy {
        bytes32 ref;
        uint32 k;
        uint8 legs;
        bool done;
        /// @dev The hold expired uncaptured and the issuer charges it late, once rates quote.
        bool late;
        uint64 at;
        uint64 expiresAt;
        uint128 amount;
        uint256 lock;
    }

    /// @dev What the driver counted.
    struct Stats {
        uint256 swipes;
        uint256 onConverted;
        uint256 onPlain;
        uint256 declined;
        uint256 captures;
        uint256 captureFails;
        uint256 expired;
        uint256 expiredAmount;
        /// @dev Late charges of expired holds: count, what the issuer absorbed, and what the cardholders paid past the
        ///      rate their purchase locked, valued at the market.
        uint256 lateCharged;
        uint256 lateAbsorbed;
        uint256 lateHolderExtra;
        /// @dev Settlement units the issuer pays the network beyond what the settlement account received at capture,
        ///      converted tokens valued at the market (negative: the issuer gained).
        int256 issuerGap;
        uint256 maxGapBps;
        /// @dev Settlement units CardAuth recorded as absorbed by the issuer (the purchase's refunded count).
        uint256 absorbed;
        /// @dev Converted tokens cardholders paid beyond the rate their purchase locked, summed.
        uint256 overLock;
        /// @dev Gas of the first cardholder's approved authorizations and captures (the sample), summed, with counts.
        uint256 authGas;
        uint256 authSampled;
        uint256 captureGas;
        uint256 captureSampled;
        /// @dev Market value of converted tokens cardholders paid, in settlement units, against what they bought.
        int256 holderCost;
        /// @dev The same at the reference rate.
        int256 holderCostRef;
        uint256 bought;
    }

    ITIP20Token internal lcl;
    Conversion internal conv;
    FixedPricePool internal bidPool;
    FixedPricePool internal askPool;

    /// @dev The venue's mid, USD per LCL.
    uint256 internal market;
    /// @dev The venue's spread on each side, in bps.
    uint256 internal spreadBps;
    /// @dev The reference rate the keeper last set, USD per LCL.
    uint256 internal refRate;
    /// @dev Whether the issuer settles in LCL, cardholders then holding USD.
    bool internal localIssuer;

    address[] internal holders;
    bytes32[] internal holderCards;
    uint256 internal nonce;
    Buy[] internal buys;
    uint256 internal firstOpen;
    Stats internal st;

    /// @dev Supply of each token outside the known parties, fixed by _baseline.
    mapping(address token => uint256) internal outside;

    /// @dev The size multiplier: STRESS_SCALE=10 runs ten times the cardholders or operations.
    function _scaleBy() internal view returns (uint256) {
        return vm.envOr("STRESS_SCALE", uint256(1));
    }

    // World.

    /// @dev Deploys the programs and a Conversion for LCL at rate USD per LCL with spread bps each way, trusted by the
    ///      cash and savings sources and holding floatUsd and floatLcl of float.
    function _fxWorld(uint256 rate, uint256 spread, uint256 floatUsd, uint256 floatLcl) internal {
        vm.warp(MONDAY);
        _deployPrograms();
        lcl = _createToken("Local", "LCLX");
        conv = new Conversion(address(usd), address(this));
        market = rate;
        spreadBps = spread;
        bidPool = new FixedPricePool(address(lcl), address(usd), _bid());
        askPool = new FixedPricePool(address(lcl), address(usd), _ask());
        usd.mint(address(bidPool), DEPTH);
        lcl.mint(address(askPool), DEPTH * 100);
        conv.setVenue(address(lcl), address(usd), address(bidPool), true);
        conv.setVenue(address(usd), address(lcl), address(askPool), false);
        Rates.set(conv, address(lcl), rate);
        refRate = rate;
        conv.setTrusted(address(cash), true);
        conv.setTrusted(address(savings), true);
        if (floatUsd != 0) usd.mint(address(conv), floatUsd);
        if (floatLcl != 0) lcl.mint(address(conv), floatLcl);
        _setting(abi.encodeCall(cards.setCompanions, (address(0), address(0), address(0), address(conv))));
        _setting(abi.encodeCall(cards.setCompanion, (address(this), true)));
        vm.label(address(conv), "Conversion");
        vm.label(address(bidPool), "BidPool");
        vm.label(address(askPool), "AskPool");
        // Start the next full week with a fresh rate.
        vm.warp(MONDAY + 7 days);
        conv.setReferenceRate(address(lcl), rate);
    }

    /// @dev Moves the program to settle in LCL at today's reference rate.
    function _settleInLocal() internal {
        cards.setSettlementToken(address(lcl), ONE.mulDiv(ONE, refRate));
        localIssuer = true;
    }

    /// @dev Adds n cardholders, each with a card. With convertedOnly the order lists only the converted token, else
    ///      the plain settlement token follows it. Funds each with tokens of the converted token and plain of the
    ///      settlement token. Returns the index of the first.
    function _addHolders(uint256 n, bool convertedOnly, uint16 maxCost, uint256 tokens, uint256 plain)
        internal
        returns (uint256 first)
    {
        first = holders.length;
        for (uint256 i; i < n; ++i) {
            uint256 k = holders.length;
            address h = makeAddr(string.concat("holder-", vm.toString(k)));
            bytes32 card = keccak256(abi.encode("card", k));
            holders.push(h);
            holderCards.push(card);
            vm.prank(issuer);
            cards.issueCard(card, h, uint40(vm.getBlockTimestamp() + 730 days), _limits(1e13, 1e14, 1e15), 7);
            CardLegs.Funding[] memory order = new CardLegs.Funding[](convertedOnly ? 1 : 2);
            order[0] = _cashEntry(_converted(), maxCost);
            if (!convertedOnly) order[1] = _cashEntry(_settlementToken(), 0);
            vm.startPrank(h);
            core.approveHolder(address(cash), address(lcl), type(uint128).max, 0);
            core.approveHolder(address(cash), address(usd), type(uint128).max, 0);
            cards.setFunding(order);
            cards.grant(CardLimits.Terms({ limit: 0, perPurchase: 0, daily: 0, monthly: 0, utcOffset: 0 }));
            vm.stopPrank();
            if (tokens != 0) ITIP20Token(_converted()).mint(h, tokens);
            if (plain != 0) ITIP20Token(_settlementToken()).mint(h, plain);
        }
    }

    /// @dev Fixes what lies outside the known parties and gives the issuer refund money, so later checks see anything
    ///      leaking out. Call after the last mint.
    function _baseline(uint256 refundMoney) internal {
        ITIP20Token stl = ITIP20Token(_settlementToken());
        if (refundMoney != 0) stl.mint(issuer, refundMoney);
        vm.prank(issuer);
        stl.approve(address(cards), type(uint256).max);
        outside[address(usd)] = usd.totalSupply() - _partiesBalance(usd);
        outside[address(lcl)] = lcl.totalSupply() - _partiesBalance(lcl);
    }

    function _converted() internal view returns (address) {
        return localIssuer ? address(usd) : address(lcl);
    }

    function _settlementToken() internal view returns (address) {
        return localIssuer ? address(lcl) : address(usd);
    }

    /// @dev Market value in settlement units of tokens of the converted token.
    function _atMarket(uint256 tokens) internal view returns (uint256) {
        return localIssuer ? tokens.mulDiv(ONE, market) : tokens.mulDiv(market, ONE);
    }

    /// @dev Value at the reference rate in settlement units of tokens of the converted token.
    function _atRef(uint256 tokens) internal view returns (uint256) {
        return localIssuer ? tokens.mulDiv(ONE, refRate) : tokens.mulDiv(refRate, ONE);
    }

    /// @dev Market value in USD of what account holds of both tokens, held ones included.
    function _valueUsd(address account) internal view returns (uint256) {
        uint256 l = lcl.balanceOf(account) + core.reserved(account, address(lcl));
        uint256 u = usd.balanceOf(account) + core.reserved(account, address(usd));
        return u + l.mulDiv(market, ONE);
    }

    // Market and reference rate.

    function _bid() internal view returns (uint256) {
        return market.mulDiv(BPS - spreadBps, BPS);
    }

    function _ask() internal view returns (uint256) {
        return market.mulDivUp(BPS, BPS - spreadBps);
    }

    /// @dev Moves the venue's mid to mid, keeping the spread.
    function _setMarket(uint256 mid) internal {
        market = mid;
        bidPool.setPrice(_bid());
        askPool.setPrice(_ask());
    }

    /// @dev Prices both venues at price, with no spread, and takes it as the market.
    function _setVenuePrice(uint256 price) internal {
        market = price;
        bidPool.setPrice(price);
        askPool.setPrice(price);
    }

    /// @dev Whether the Conversion quotes LCL now: a fresh reference rate with the venue within its band.
    function _quotes() internal view returns (bool) {
        try conv.rate(_converted(), _settlementToken()) returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev How far the market sits from the reference rate, in bps of the reference.
    function _gapBps() internal view returns (uint256) {
        uint256 d = market > refRate ? market - refRate : refRate - market;
        return d * BPS / refRate;
    }

    /// @dev One keeper round, as a careful operator runs it: applies a due scheduled rate when it lands closer to the
    ///      market than a step would, steps toward the market as far as the day's window allows (a step of zero only
    ///      refreshes the rate's age), then schedules the market when a gap remains, keeping a schedule still waiting
    ///      (replacing it restarts its delay) and cancelling one no longer needed.
    function _keeperTick() internal {
        (uint128 scheduled, uint64 readyAt) = conv.scheduledRateOf(address(lcl));
        uint256 stepped = _stepped();
        if (readyAt != 0 && vm.getBlockTimestamp() >= readyAt && _dist(scheduled) < _dist(stepped)) {
            conv.setReferenceRate(address(lcl), scheduled);
            (refRate, readyAt) = (scheduled, 0);
            stepped = _stepped();
        }
        conv.setReferenceRate(address(lcl), stepped);
        refRate = stepped;
        if (stepped == market) {
            if (readyAt != 0) conv.scheduleReferenceRate(address(lcl), 0);
        } else if (readyAt == 0 || vm.getBlockTimestamp() >= readyAt) {
            conv.scheduleReferenceRate(address(lcl), market);
        }
    }

    /// @dev The rate nearest the market the reference may step to now.
    function _stepped() internal view returns (uint256 next) {
        (uint128 anchor, uint64 openedAt) = conv.rateWindowOf(address(lcl));
        if (vm.getBlockTimestamp() >= openedAt + conv.RATE_STEP_WINDOW()) anchor = uint128(refRate);
        uint256 room = uint256(anchor) * conv.MAX_RATE_STEP_BPS() / BPS;
        next = market;
        if (next + room < anchor) next = anchor - room;
        if (next > anchor + room) next = anchor + room;
    }

    function _dist(uint256 rate) internal view returns (uint256) {
        return rate > market ? rate - market : market - rate;
    }

    // Purchases.

    function _newRef() internal returns (bytes32) {
        return keccak256(abi.encode("purchase", ++nonce));
    }

    /// @dev Authorizes amount on holder k's card; returns whether it was approved and which order entries it drew on
    ///      (bit 0 the converted entry, bit 1 the plain one).
    function _swipe(uint256 k, bytes32 ref, uint128 amount, uint64 life) internal returns (bool ok, uint8 legs) {
        uint64 expiresAt = uint64(vm.getBlockTimestamp()) + life;
        // Gas metering stays paused except for the sample, which keeps long runs under the test's gas limit.
        bool sample = k == 0;
        vm.prank(issuer);
        if (sample) vm.resumeGasMetering();
        uint256 g = gasleft();
        try cards.authorize(holderCards[k], ref, amount, merchant, expiresAt, 0) returns (uint256) {
            g -= gasleft();
            if (sample) (st.authGas, st.authSampled) = (st.authGas + g, st.authSampled + 1);
            ok = true;
        } catch { }
        if (sample) vm.pauseGasMetering();
        if (!ok) return (false, 0);
        (,, bytes32[] memory ids) = cards.legsOf(ref);
        for (uint256 j; j < ids.length; ++j) {
            if (ids[j] == cards.legId(ref, 0)) legs |= 1;
            if (ids[j] == cards.legId(ref, 1)) legs |= 2;
        }
    }

    /// @dev A purchase amount between 5 and 200 settlement units of 6 decimals, in whole cents.
    function _amount(uint256 seed) internal pure returns (uint128) {
        return uint128((5e6 + seed % 195e6) / 1e4 * 1e4);
    }

    /// @dev Every cardholder swipes perHolder purchases that stay open for life, and the driver tracks them.
    function _swipeRound(uint256 perHolder, uint64 life, uint256 seed) internal {
        for (uint256 k; k < holders.length; ++k) {
            for (uint256 s; s < perHolder; ++s) {
                bytes32 ref = _newRef();
                uint128 amount = _amount(_rand(seed, nonce));
                (bool ok, uint8 legs) = _swipe(k, ref, amount, life);
                ++st.swipes;
                if (!ok) {
                    ++st.declined;
                    continue;
                }
                if (legs & 1 != 0) ++st.onConverted;
                else ++st.onPlain;
                uint256 lock = legs & 1 != 0 ? cash.lockedRate(cards.legId(ref, 0)) : 0;
                buys.push(
                    Buy({
                        ref: ref,
                        k: uint32(k),
                        legs: legs,
                        done: false,
                        late: false,
                        at: uint64(vm.getBlockTimestamp()),
                        expiresAt: uint64(vm.getBlockTimestamp()) + life,
                        amount: amount,
                        lock: lock
                    })
                );
            }
        }
        _checkConservation();
    }

    /// @dev Captures in full every tracked purchase at least minAge old. A hold that expired uncaptured is released
    ///      (the network still presents it) and the issuer charges it late once the Conversion quotes: a late charge
    ///      while it doesn't would leave the issuer absorbing all of it.
    function _captureRound(uint256 minAge) internal {
        bool quotes = _quotes();
        for (uint256 i = firstOpen; i < buys.length; ++i) {
            Buy storage b = buys[i];
            if (b.done) {
                if (i == firstOpen) ++firstOpen;
                continue;
            }
            if (!b.late && vm.getBlockTimestamp() >= b.expiresAt) {
                cards.release(b.ref);
                (b.late, st.expired, st.expiredAmount) = (true, st.expired + 1, st.expiredAmount + b.amount);
            }
            if (b.late) {
                if (quotes) b.done = _lateCharge(b);
                continue;
            }
            if (vm.getBlockTimestamp() < b.at + minAge) continue;
            if (_captureBuy(b)) b.done = true;
        }
        _checkConservation();
    }

    /// @dev Charges an expired purchase in full after its hold ended and records who paid.
    function _lateCharge(Buy storage b) internal returns (bool) {
        ITIP20Token stl = ITIP20Token(_settlementToken());
        ITIP20Token cvt = ITIP20Token(_converted());
        uint256 stlBefore = stl.balanceOf(settlement);
        uint256 cvtBefore = cvt.balanceOf(settlement);
        uint256 holderBefore = _holderTokens(b.k);
        vm.prank(issuer);
        try cards.charge(holderCards[b.k], b.ref, b.amount, merchant) { }
        catch {
            return false;
        }
        ++st.lateCharged;
        uint256 got = stl.balanceOf(settlement) - stlBefore + _atMarket(cvt.balanceOf(settlement) - cvtBefore);
        if (got < b.amount) st.lateAbsorbed += b.amount - got;
        uint256 spent = holderBefore - _holderTokens(b.k);
        uint256 promised = b.lock == 0 ? 0 : uint256(b.amount).mulDivUp(ONE, b.lock);
        if (b.legs & 1 != 0 && spent > promised) st.lateHolderExtra += _atMarket(spent - promised);
        return true;
    }

    /// @dev Captures one purchase in full and records who paid what; false when the capture reverted.
    function _captureBuy(Buy storage b) internal returns (bool) {
        ITIP20Token stl = ITIP20Token(_settlementToken());
        ITIP20Token cvt = ITIP20Token(_converted());
        uint256 stlBefore = stl.balanceOf(settlement);
        uint256 cvtBefore = cvt.balanceOf(settlement);
        uint256 holderBefore = _holderTokens(b.k);
        uint64 absorbedBefore = cards.purchaseOf(b.ref).refunded;
        bool sample = b.k == 0;
        bool ok;
        vm.prank(issuer);
        if (sample) vm.resumeGasMetering();
        uint256 g = gasleft();
        try cards.capture(b.ref, b.amount, true) {
            g -= gasleft();
            if (sample) (st.captureGas, st.captureSampled) = (st.captureGas + g, st.captureSampled + 1);
            ok = true;
        } catch { }
        if (sample) vm.pauseGasMetering();
        if (!ok) {
            ++st.captureFails;
            return false;
        }
        ++st.captures;
        st.absorbed += cards.purchaseOf(b.ref).refunded - absorbedBefore;
        uint256 got = stl.balanceOf(settlement) - stlBefore + _atMarket(cvt.balanceOf(settlement) - cvtBefore);
        int256 gap = int256(uint256(b.amount)) - int256(got);
        st.issuerGap += gap;
        if (gap > 0 && uint256(gap) * BPS / b.amount > st.maxGapBps) st.maxGapBps = uint256(gap) * BPS / b.amount;
        uint256 spent = holderBefore - _holderTokens(b.k);
        if (b.legs == 1) {
            uint256 promised = uint256(b.amount).mulDivUp(ONE, b.lock);
            // The cardholder never pays more converted tokens than the rate it was shown promised.
            assertLe(spent, promised + 1, "paid past the locked rate");
            // The issuer loses at most what the venue's move since the swipe takes from the cardholder's tokens.
            uint256 floor = uint256(b.amount).mulDiv(_bid(), b.lock);
            if (floor > b.amount) floor = b.amount;
            assertGe(got + 2, floor, "issuer lost past the market move");
            if (spent > promised) st.overLock += spent - promised;
            st.holderCost += int256(_atMarket(spent)) - int256(uint256(b.amount));
            st.holderCostRef += int256(_atRef(spent)) - int256(uint256(b.amount));
            st.bought += b.amount;
        }
        return true;
    }

    /// @dev Refunds amount of ref as the issuer; returns whether it went through and the converted tokens holder k got
    ///      back.
    function _tryRefund(uint256 k, bytes32 ref, uint128 amount) internal returns (bool ok, uint256 back) {
        uint256 before = _holderTokens(k);
        vm.prank(issuer);
        try cards.refund(ref, amount) {
            ok = true;
        } catch {
            return (false, 0);
        }
        back = _holderTokens(k) - before;
    }

    /// @dev The converted tokens holder k owns, held ones included.
    function _holderTokens(uint256 k) internal view returns (uint256) {
        address t = _converted();
        return ITIP20Token(t).balanceOf(holders[k]) + core.reserved(holders[k], t);
    }

    // Invariants.

    /// @dev Every token sits with a known party or where it sat at the baseline, the core holds exactly what it
    ///      reserves, and the sources and program keep nothing between calls.
    function _checkConservation() internal view {
        assertEq(usd.totalSupply(), outside[address(usd)] + _partiesBalance(usd), "usd left the parties");
        assertEq(lcl.totalSupply(), outside[address(lcl)] + _partiesBalance(lcl), "lcl left the parties");
        assertEq(usd.balanceOf(address(core)), core.totalReserved(address(usd)), "usd reserved");
        assertEq(lcl.balanceOf(address(core)), core.totalReserved(address(lcl)), "lcl reserved");
        assertEq(usd.balanceOf(address(cash)) + lcl.balanceOf(address(cash)), 0, "cash source keeps tokens");
        assertEq(usd.balanceOf(address(cards)) + lcl.balanceOf(address(cards)), 0, "program keeps tokens");
    }

    function _partiesBalance(ITIP20Token token) internal view returns (uint256 sum) {
        for (uint256 i; i < holders.length; ++i) {
            sum += token.balanceOf(holders[i]);
        }
        sum += token.balanceOf(settlement) + token.balanceOf(issuer) + token.balanceOf(address(conv))
        + token.balanceOf(address(bidPool)) + token.balanceOf(address(askPool)) + token.balanceOf(address(cash))
        + token.balanceOf(address(cards)) + token.balanceOf(address(core)) + token.balanceOf(merchant);
    }

    /// @dev Releases every tracked purchase still open once the last has expired, showing none is stuck, and checks
    ///      that the core then reserves nothing.
    function _releaseAll() internal {
        for (uint256 i = firstOpen; i < buys.length; ++i) {
            Buy storage b = buys[i];
            if (!cards.purchaseOf(b.ref).open) continue;
            if (vm.getBlockTimestamp() < b.expiresAt) vm.warp(b.expiresAt);
            cards.release(b.ref);
            if (!b.done && !b.late) {
                (b.late, st.expired, st.expiredAmount) = (true, st.expired + 1, st.expiredAmount + b.amount);
            }
        }
        assertEq(core.totalReserved(address(lcl)), 0, "lcl still reserved");
        assertEq(core.totalReserved(address(usd)), 0, "usd still reserved");
        _checkConservation();
    }

    // Output.

    function _log(string memory test, string memory metric, uint256 value) internal pure {
        console.log(string.concat("STRESS ", test, " ", metric, "=", vm.toString(value)));
    }

    /// @dev Logs a 6-decimal amount as a decimal string.
    function _logAmount(string memory test, string memory metric, int256 value) internal pure {
        console.log(string.concat("STRESS ", test, " ", metric, "=", _decimal(value, 6)));
    }

    /// @dev Logs the driver's counts.
    function _report(string memory test) internal view {
        if (st.authSampled != 0) _log(test, "gas_per_authorize", st.authGas / st.authSampled);
        if (st.captureSampled != 0) _log(test, "gas_per_capture", st.captureGas / st.captureSampled);
        _log(test, "swipes", st.swipes);
        _log(test, "on_converted", st.onConverted);
        _log(test, "on_plain", st.onPlain);
        _log(test, "declined", st.declined);
        _log(test, "captures", st.captures);
        _log(test, "capture_reverts", st.captureFails);
        _log(test, "expired_uncaptured", st.expired);
        _logAmount(test, "expired_uncaptured_amount", int256(st.expiredAmount));
        _log(test, "late_charged", st.lateCharged);
        _logAmount(test, "late_issuer_absorbed", int256(st.lateAbsorbed));
        _logAmount(test, "late_holder_paid_past_lock", int256(st.lateHolderExtra));
        _logAmount(test, "issuer_fx_loss", st.issuerGap);
        _logAmount(test, "issuer_absorbed_recorded", int256(st.absorbed));
        _log(test, "issuer_max_loss_bps", st.maxGapBps);
        _logAmount(test, "holder_cost_vs_market", st.holderCost);
        _logAmount(test, "holder_cost_vs_reference", st.holderCostRef);
        _logAmount(test, "holder_bought_converted", int256(st.bought));
        _log(test, "holder_tokens_over_lock", st.overLock);
    }

    function _decimal(int256 value, uint256 decimals) internal pure returns (string memory) {
        bool negative = value < 0;
        uint256 v = uint256(negative ? -value : value);
        uint256 unit = 10 ** decimals;
        string memory frac = vm.toString(v % unit);
        while (bytes(frac).length < decimals) {
            frac = string.concat("0", frac);
        }
        return string.concat(negative ? "-" : "", vm.toString(v / unit), ".", frac);
    }

    /// @dev A deterministic pseudo-random number from a seed and a salt.
    function _rand(uint256 seed, uint256 salt) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt)));
    }
}
