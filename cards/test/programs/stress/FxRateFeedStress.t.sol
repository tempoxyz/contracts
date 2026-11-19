// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FxBase } from "./FxBase.sol";

/// @notice The reference rate feed stopping: over a weekend while the market gaps, and for more than the rate's
///         seven-day age. Cardholders hold LCL (an emerging-market stablecoin at 0.05 USD) for a USD issuer; half list
///         only LCL, half fall back to USD. Each day every cardholder swipes at noon, and at 18:00 on weekdays the
///         network presents purchases at least a day old, so Friday's purchases settle on Monday.
contract FxRateFeedStressTest is FxBase {
    uint256 internal constant RATE = 0.05e18;
    uint64 internal constant LIFE = 7 days;

    uint256 internal n;

    function setUp() public {
        _fxWorld(RATE, 30, 1_000_000e6, 100_000_000e6);
        n = 10 * _scaleBy();
        _addHolders(n, true, 100, 400_000e6, 0);
        _addHolders(n, false, 100, 400_000e6, 20_000e6);
        _baseline(1_000_000e6);
    }

    /// @dev The keeper stops Friday after its morning round and comes back Monday 09:00, both weekends; the market
    ///      gaps down 1.5% on the first Saturday and 3% on the second.
    function test_stress_feedPausesOverWeekendsWhileTheMarketGaps() public {
        vm.pauseGasMetering();
        string memory t = "feed_weekend";
        uint256 start = vm.getBlockTimestamp();
        uint256 weekendDeclines;
        uint256 mondayDeclines;
        uint256 tuesdayDeclines;
        uint256 maxGap;
        for (uint256 d; d < 14; ++d) {
            uint256 day = start + d * 1 days;
            uint256 dow = d % 7;
            vm.warp(day + 9 hours);
            if (dow < 5) _keeperTick();
            if (d == 5) _setMarket(market * 9850 / BPS);
            if (d == 12) _setMarket(market * 9700 / BPS);
            if (_gapBps() > maxGap) maxGap = _gapBps();
            vm.warp(day + 12 hours);
            uint256 before = st.declined;
            _swipeRound(1, LIFE, d);
            uint256 declined = st.declined - before;
            if (dow >= 5) weekendDeclines += declined;
            if (dow == 0) mondayDeclines += declined;
            if (dow == 1) tuesdayDeclines += declined;
            if (dow < 5) {
                vm.warp(day + 18 hours);
                _captureRound(1 days);
            }
        }
        // Monday and Tuesday of the third week: the network presents the weekend's purchases.
        for (uint256 d = 14; d < 16; ++d) {
            vm.warp(start + d * 1 days + 9 hours);
            _keeperTick();
            vm.warp(start + d * 1 days + 18 hours);
            _captureRound(0);
        }
        _releaseAll();
        _report(t);
        _log(t, "weekend_declines", weekendDeclines);
        _log(t, "monday_declines", mondayDeclines);
        _log(t, "tuesday_declines", tuesdayDeclines);
        _log(t, "max_market_gap_bps", maxGap);
        // A weekend is well inside the seven-day age: no swipe declines for a stale rate. Declines come only from the
        // venue leaving the band around a rate that cannot follow it.
        assertEq(st.expired, 0, "a weekend outage expired purchases");
        // Captures fail only while the venue sits outside the band, and only for the day the rate needs to catch up.
        assertLe(st.captureFails, 2 * n, "captures failed past a day");
    }

    /// @dev The keeper's last round is Wednesday 09:00 and it comes back ten days later; the market stays flat. The
    ///      rate goes stale after seven days, the following Wednesday 09:00.
    function test_stress_feedStopsForTenDays() public {
        vm.pauseGasMetering();
        string memory t = "feed_ten_days";
        uint256 start = vm.getBlockTimestamp();
        uint256 lastTick;
        uint256 staleDeclines;
        uint256 staleFallbacks;
        uint256 staleCaptureFails;
        uint256 refundsOk;
        uint256 refundsFailed;
        uint256 staleSwipeDays;
        for (uint256 d; d < 16; ++d) {
            uint256 day = start + d * 1 days;
            vm.warp(day + 9 hours);
            bool feed = d <= 2 || d >= 12;
            if (feed) (lastTick) = (_tick());
            bool stale = vm.getBlockTimestamp() > lastTick + conv.MAX_RATE_AGE();
            vm.warp(day + 12 hours);
            stale = vm.getBlockTimestamp() > lastTick + conv.MAX_RATE_AGE();
            uint256 declinedBefore = st.declined;
            uint256 plainBefore = st.onPlain;
            _swipeRound(1, LIFE, d);
            if (stale) {
                ++staleSwipeDays;
                staleDeclines += st.declined - declinedBefore;
                staleFallbacks += st.onPlain - plainBefore;
            }
            vm.warp(day + 18 hours);
            uint256 failsBefore = st.captureFails;
            if (d % 7 < 5) _captureRound(1 days);
            if (stale) staleCaptureFails += st.captureFails - failsBefore;
            // While stale, the issuer refunds half of up to 2n captured LCL purchases.
            if (stale && d == 10) (refundsOk, refundsFailed) = _refundHalf(2 * n);
        }
        vm.warp(start + 16 days + 18 hours);
        _captureRound(0);
        _releaseAll();
        _report(t);
        _log(t, "stale_swipe_days", staleSwipeDays);
        _log(t, "stale_declines", staleDeclines);
        _log(t, "stale_fallbacks_to_usd", staleFallbacks);
        _log(t, "stale_capture_reverts", staleCaptureFails);
        _log(t, "stale_refunds_ok", refundsOk);
        _log(t, "stale_refunds_reverted", refundsFailed);
        // Every LCL-only swipe declines while stale, and every swipe with USD behind it falls back.
        assertEq(staleDeclines, staleSwipeDays * n, "LCL-only swipes while stale");
        assertEq(staleFallbacks, staleSwipeDays * n, "fallbacks while stale");
        // Once the rate is fresh again every capture goes through before its purchase expires.
        assertEq(st.expired, 0, "purchases expired");
    }

    function _tick() internal returns (uint256) {
        _keeperTick();
        return vm.getBlockTimestamp();
    }

    /// @dev Refunds half of up to count captured LCL-only purchases.
    function _refundHalf(uint256 count) internal returns (uint256 ok, uint256 failed) {
        for (uint256 i; i < buys.length && ok + failed < count; ++i) {
            Buy storage b = buys[i];
            if (b.legs != 1 || cards.purchaseOf(b.ref).captured == 0) continue;
            (bool done,) = _tryRefund(b.k, b.ref, b.amount / 2);
            if (done) ++ok;
            else ++failed;
            _checkConservation();
        }
    }
}
