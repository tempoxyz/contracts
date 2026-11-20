// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FxBase } from "./FxBase.sol";

/// @notice A devaluation of the cardholders' currency against the issuer's USD: LCL at 0.05 USD falls 10%, 25% or 40%
///         over one to five days, in equal daily steps at 03:00 from the third day. The reference rate may move only 2% a day at once, so
///         it lags the venue; the keeper steps it at 09:00 and 21:00 and schedules the market price for two days
///         later. Half the cardholders list only LCL, half fall back to USD. Each cardholder swipes at 06:00, 12:00
///         and 18:00; the network presents purchases a day old at 20:00, every day.
contract FxDevaluationStressTest is FxBase {
    uint256 internal constant RATE = 0.05e18;
    uint64 internal constant LIFE = 7 days;
    uint256 internal constant DAYS = 16;
    /// @dev IssuerTreasury.FX_STRESS_BPS: the share of open converted holds the sponsor's collateral backs.
    uint256 internal constant FX_STRESS_BPS = 1000;

    uint256 internal n;

    struct Outcome {
        uint256 openAtMove;
        uint256 declinedDuring;
        uint256 declinedAfter;
        uint256 outOfBandHours;
        uint256 lastOutOfBand;
        uint256 maxGap;
        uint256 captureFailDays;
    }

    function setUp() public {
        _fxWorld(RATE, 30, 1_000_000e6, 100_000_000e6);
        n = 10 * _scaleBy();
        _addHolders(n, true, 100, 1_000_000e6, 0);
        _addHolders(n, false, 100, 1_000_000e6, 50_000e6);
        _baseline(1_000_000e6);
    }

    /// @dev Past the band: the cardholders pay the market less FX_BAND_BPS (8% of the move), the issuer the band.
    function test_stress_devalue10PctInOneDay() public {
        _assertSplit(_devalue("devalue_10pct_1d", 1000, 1), 200, 800);
    }

    function test_stress_devalue10PctOverFiveDays() public {
        _devalue("devalue_10pct_5d", 1000, 5);
    }

    /// @dev Past the capture limit: the cardholders pay 10% more tokens than the lock (7.5% of the purchase at the
    ///      fallen market), the issuer the rest (1 - 1.1 * 0.75 = 17.5%), once the reference rate confirms the move.
    function test_stress_devalue25PctInOneDay() public {
        _assertSplit(_devalue("devalue_25pct_1d", 2500, 1), 1750, 750);
    }

    function test_stress_devalue25PctOverThreeDays() public {
        _devalue("devalue_25pct_3d", 2500, 3);
    }

    /// @dev As at 25%: cardholders 10% more tokens (6% at the market), the issuer 1 - 1.1 * 0.6 = 34%.
    function test_stress_devalue40PctInOneDay() public {
        _assertSplit(_devalue("devalue_40pct_1d", 4000, 1), 3400, 600);
    }

    /// @dev fx-policy.md: band, tolerance and the exposure guard's FX stress share (10% of open) cover an overnight
    ///      move up to about 18% (1 - 0.9 / 1.1 = 18.2%). Past it the issuer's loss exceeds what collateral backs.
    function test_stress_collateralCoversAnEighteenPctOvernightMove() public {
        uint256 open = _devalue("devalue_18pct_1d", 1800, 1);
        assertLe(st.issuerGap, int256(open * FX_STRESS_BPS / BPS), "18% move: issuer loss past the collateral");
    }

    function test_stress_collateralFallsShortOfANineteenPctOvernightMove() public {
        uint256 open = _devalue("devalue_19pct_1d", 1900, 1);
        assertGt(st.issuerGap, int256(open * FX_STRESS_BPS / BPS), "19% move: issuer loss within the collateral");
    }

    /// @dev Daily steps within the band and the cardholders' tolerance: every capture goes through on time, the issuer
    ///      paying at most the band on any purchase.
    function test_stress_devalue40PctOverFiveDays() public {
        _devalue("devalue_40pct_5d", 4000, 5);
        assertEq(st.captureFails, 0, "captures stalled");
        assertEq(st.lateCharged, 0, "purchases charged late");
        assertLe(st.maxGapBps, cash.FX_BAND_BPS(), "issuer paid past the band");
    }

    /// @dev The reverse move: LCL gains 10% in a day. The issuer keeps the band; the cardholders get the rest back.
    function test_stress_appreciate10PctInOneDay() public {
        uint256 open = _devalue("appreciate_10pct_1d", 0, 1);
        assertApproxEqAbs(st.issuerGap, -int256(open * 200 / BPS), open * 50 / BPS, "issuer keeps the band");
        assertApproxEqAbs(st.holderShare, -int256(open * 800 / BPS), open * 50 / BPS, "cardholders get the rest");
    }

    /// @dev Any drop of up to 50% over one to six days ends with rates caught up, nothing stuck and the issuer's loss
    ///      within the move. Each run simulates DAYS days, so runs stay few.
    /// forge-config: default.fuzz.runs = 8
    /// forge-config: ci.fuzz.runs = 8
    function testFuzz_stress_devaluation(uint256 dropBps, uint256 days_) public {
        dropBps = bound(dropBps, 100, 5000);
        days_ = bound(days_, 1, 6);
        _devalue("devalue_fuzz", dropBps, days_);
    }

    /// @dev Runs DAYS days, the move falling on days 2 to 2 + moveDays - 1. dropBps zero means a 10% rise instead.
    function _devalue(string memory t, uint256 dropBps, uint256 moveDays) internal returns (uint256) {
        vm.pauseGasMetering();
        uint256 start = vm.getBlockTimestamp();
        uint256 target = dropBps == 0 ? RATE * 11_000 / BPS : RATE * (BPS - dropBps) / BPS;
        Outcome memory o;
        for (uint256 d; d < DAYS; ++d) {
            uint256 day = start + d * 1 days;
            if (d >= 2 && d < 2 + moveDays) {
                vm.warp(day + 3 hours);
                // Equal steps reach the target on the last day.
                uint256 left = 2 + moveDays - d;
                _setMarket(target > market ? market + (target - market) / left : market - (market - target) / left);
            }
            if (d == 2) o.openAtMove = _openConverted();
            for (uint256 h; h < 4; ++h) {
                vm.warp(day + [uint256(6 hours), 9 hours, 12 hours, 18 hours][h]);
                if (h == 1) _keeperTick();
                if (_gapBps() > o.maxGap) o.maxGap = _gapBps();
                if (h == 1) continue;
                if (!_quotes()) {
                    o.outOfBandHours += 6;
                    o.lastOutOfBand = d + 1;
                }
                uint256 before = st.declined;
                _swipeRound(1, LIFE, d * 4 + h);
                if (d >= 2) {
                    if (d < 2 + moveDays) o.declinedDuring += st.declined - before;
                    else o.declinedAfter += st.declined - before;
                }
            }
            vm.warp(day + 20 hours);
            uint256 fails = st.captureFails;
            _captureRound(1 days);
            if (st.captureFails > fails) ++o.captureFailDays;
            vm.warp(day + 21 hours);
            _keeperTick();
        }
        vm.warp(start + DAYS * 1 days + 20 hours);
        _keeperTick();
        _captureRound(0);
        _releaseAll();
        _captureRound(0);
        _report(t);
        _log(t, "move_bps", dropBps == 0 ? 1000 : dropBps);
        _log(t, "move_days", moveDays);
        _log(t, "max_reference_gap_bps", o.maxGap);
        _logAmount(t, "open_converted_at_move", int256(o.openAtMove));
        _log(t, "declined_during_move", o.declinedDuring);
        _log(t, "declined_after_move", o.declinedAfter);
        _log(t, "out_of_band_swipe_hours", o.outOfBandHours);
        // Days from the move's first day to the end of the last day the venue sat outside the band.
        _log(t, "days_until_rates_quote", o.lastOutOfBand > 2 ? o.lastOutOfBand - 2 : 0);
        _log(t, "capture_fail_days", o.captureFailDays);
        _log(t, "final_reference_gap_bps", _gapBps());
        // The reference caught up and nothing stayed stuck.
        assertEq(_gapBps(), 0, "reference never caught up");
        assertTrue(_quotes(), "still not quoting");
        // Every purchase was paid for: captured, or charged late once rates quoted again.
        assertEq(st.captures + st.lateCharged, st.swipes - st.declined, "purchases left unpaid");
        // On a rise the issuer never loses; on a drop the cardholders never gain.
        if (dropBps == 0) assertLe(st.issuerGap, 0, "issuer lost on a rise");
        else assertGe(st.holderShare, 0, "cardholders gained on a drop");
        return o.openAtMove;
    }

    /// @dev What the issuer lost and the cardholders paid past their locks, against the share of what converted
    ///      purchases held open at the move the policy gives each (within 0.5% of it, for rounding and spread).
    function _assertSplit(uint256 open, uint256 issuerBps, uint256 holderBps) internal view {
        assertApproxEqAbs(st.issuerGap, int256(open * issuerBps / BPS), open * 50 / BPS, "issuer share");
        assertApproxEqAbs(st.holderShare, int256(open * holderBps / BPS), open * 50 / BPS, "cardholder share");
    }

    /// @dev What converted purchases hold open, in settlement units.
    function _openConverted() internal view returns (uint256 sum) {
        for (uint256 i = firstOpen; i < buys.length; ++i) {
            if (!buys[i].done && buys[i].legs & 1 != 0) sum += buys[i].amount;
        }
    }
}
