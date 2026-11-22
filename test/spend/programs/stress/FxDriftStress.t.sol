// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FxBase } from "./FxBase.sol";

/// @notice The venue steadily beating or lagging the reference rate by 0.5% to 0.99% (inside the 1% band) for a month.
///         The keeper only refreshes the reference, never moving it. Cardholders hold LCL (0.05 USD) for a USD issuer;
///         half list only LCL, half fall back to USD. Each cardholder swipes three times a day, the network presents
///         purchases a day old, and the issuer refunds every tenth purchase in full three days after its capture.
///         Measures where the gap between the two rates ends up: cardholders, the issuer's settlement account, the
///         venue or the Conversion's float.
contract FxDriftStressTest is FxBase {
    uint256 internal constant RATE = 0.05e18;
    uint256 internal constant DAYS = 30;

    function test_stress_venueBeatsReferenceBy50Bps() public {
        _drift("drift_venue_up50", 50, true);
    }

    function test_stress_venueBeatsReferenceBy99Bps() public {
        _drift("drift_venue_up99", 99, true);
    }

    function test_stress_venueLagsReferenceBy50Bps() public {
        _drift("drift_venue_down50", 50, false);
    }

    function test_stress_venueLagsReferenceBy99Bps() public {
        _drift("drift_venue_down99", 99, false);
    }

    function _drift(string memory t, uint256 offBps, bool up) internal {
        vm.pauseGasMetering();
        _fxWorld(RATE, 0, 1_000_000e6, 100_000_000e6);
        uint256 n = 10 * _scaleBy();
        _addHolders(n, true, 100, 1_000_000e6, 0);
        _addHolders(n, false, 100, 1_000_000e6, 50_000e6);
        _baseline(1_000_000e6);
        _setVenuePrice(up ? RATE * (BPS + offBps) / BPS : RATE * (BPS - offBps) / BPS);
        uint256 start = vm.getBlockTimestamp();
        uint256 venueBefore = _valueUsd(address(bidPool)) + _valueUsd(address(askPool));
        uint256 floatBefore = _valueUsd(address(conv));
        uint256 settlementBefore = _valueUsd(settlement);
        uint256 refunds;
        uint256 refunded;
        uint256 next;
        for (uint256 d; d < DAYS; ++d) {
            uint256 day = start + d * 1 days;
            vm.warp(day + 8 hours);
            // A refresh at the same rate keeps the reference fresh without moving it.
            conv.setReferenceRate(address(lcl), RATE);
            assertTrue(_quotes(), "venue left the band");
            for (uint256 h; h < 3; ++h) {
                vm.warp(day + 9 hours + h * 4 hours);
                _swipeRound(1, 7 days, d * 3 + h);
            }
            vm.warp(day + 20 hours);
            _captureRound(1 days);
            // Refund every tenth purchase captured at least three days ago.
            for (; next < buys.length && buys[next].at + 4 days <= vm.getBlockTimestamp(); next += 10) {
                Buy storage b = buys[next];
                if (!b.done || cards.purchaseOf(b.ref).captured == 0) continue;
                uint128 room = uint128(cards.purchaseOf(b.ref).captured - cards.purchaseOf(b.ref).refunded);
                (bool ok, uint256 back) = _tryRefund(b.k, b.ref, room);
                assertTrue(ok, "refund reverted");
                if (b.legs & 1 != 0) assertLe(back, spentOf[b.ref], "refund past what was paid");
                (refunds, refunded) = (refunds + 1, refunded + room);
            }
            _checkConservation();
        }
        vm.warp(start + DAYS * 1 days + 20 hours);
        conv.setReferenceRate(address(lcl), RATE);
        _captureRound(0);
        _releaseAll();
        _report(t);
        int256 venuePnl = int256(_valueUsd(address(bidPool)) + _valueUsd(address(askPool))) - int256(venueBefore);
        _log(t, "offset_bps", offBps);
        _log(t, "refunds", refunds);
        _logAmount(t, "refunded_usd", int256(refunded));
        _logAmount(t, "venue_pnl_usd", venuePnl);
        _logAmount(t, "float_pnl_usd", int256(_valueUsd(address(conv))) - int256(floatBefore));
        _logAmount(t, "settlement_pnl_usd", int256(_valueUsd(settlement)) - int256(settlementBefore));
        _logAmount(t, "holder_vs_reference_per_10k_usd", st.holderCostRef * int256(BPS) * 1e6 / int256(st.bought));
        // Cardholders pay the venue's rate, within a unit of rounding per capture, whichever side of the reference it
        // sits: the reference only bounds it.
        assertApproxEqAbs(st.holderCost, 0, st.captures, "cardholders paid off the venue rate");
        assertEq(st.expired, 0, "purchases expired");
    }
}
