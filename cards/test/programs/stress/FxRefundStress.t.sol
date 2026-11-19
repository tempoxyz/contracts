// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FxBase } from "./FxBase.sol";

/// @notice Refunds and dispute credits on converted legs after a large move. Cardholders hold LCL (0.05 USD) for a USD
///         issuer; over two days each makes three purchases, all captured at the old rate. LCL then moves 25% or 40%
///         in a day, the keeper catches the reference up through its scheduled move, and the issuer refunds every
///         purchase in one to four parts (a dispute credit pays through the same refund). A refund pays back at the
///         rate the capture paid: from the Conversion's float when it holds enough LCL, else through the venue.
contract FxRefundStressTest is FxBase {
    uint256 internal constant RATE = 0.05e18;

    uint256 internal n;

    function test_stress_refundsAfter25PctDevaluationFromFloat() public {
        _run("refund_down25_float", 7500, true);
    }

    function test_stress_refundsAfter40PctDevaluationFromFloat() public {
        _run("refund_down40_float", 6000, true);
    }

    function test_stress_refundsAfter40PctAppreciationFromFloat() public {
        _run("refund_up40_float", 14_000, true);
    }

    function test_stress_refundsAfter40PctDevaluationThroughVenue() public {
        _run("refund_down40_venue", 6000, false);
    }

    function test_stress_refundsAfter40PctAppreciationThroughVenue() public {
        _run("refund_up40_venue", 14_000, false);
    }

    /// @dev Runs the scenario with the market ending at movePct of BPS times RATE; withFloat gives the Conversion LCL
    ///      float to pay refunds from.
    function _run(string memory t, uint256 movePct, bool withFloat) internal {
        vm.pauseGasMetering();
        _fxWorld(RATE, 30, 1_000_000e6, withFloat ? 100_000_000e6 : 0);
        n = 20 * _scaleBy();
        _addHolders(n, true, 100, 1_000_000e6, 0);
        _baseline(1_000_000e6);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 d; d < 2; ++d) {
            vm.warp(start + d * 1 days + 10 hours);
            _keeperTick();
            _swipeRound(1, 7 days, d);
            vm.warp(start + d * 1 days + 12 hours);
            _swipeRound(1, 7 days, d + 100);
            vm.warp(start + d * 1 days + 20 hours);
            _captureRound(0);
        }
        assertEq(st.captures, 4 * n, "captures before the move");
        // The move, and the keeper catching up through a scheduled rate.
        vm.warp(start + 2 days + 3 hours);
        _setMarket(RATE * movePct / BPS);
        for (uint256 d = 2; d < 6; ++d) {
            vm.warp(start + d * 1 days + 9 hours);
            _keeperTick();
        }
        assertEq(_gapBps(), 0, "reference caught up");
        uint256 floatBefore = _valueUsd(address(conv));
        uint256 settlementBefore = _valueUsd(settlement);
        uint256 issuerBefore = _valueUsd(issuer);
        uint256 holdersBefore = _holdersValue();
        uint256 refunded;
        uint256 refunds;
        uint256 failed;
        uint256 tokensSpent;
        uint256 tokensBack;
        uint256 maxShortTokens;
        for (uint256 i; i < buys.length; ++i) {
            Buy storage b = buys[i];
            uint256 parts = 1 + _rand(i, 7) % 4;
            uint256 back;
            uint256 sent;
            for (uint256 j; j < parts; ++j) {
                uint128 part = j + 1 == parts ? b.amount - uint128(sent) : b.amount / uint128(parts);
                (bool ok, uint256 got) = _tryRefund(b.k, b.ref, part);
                if (!ok) {
                    ++failed;
                    continue;
                }
                (refunds, refunded, sent, back) = (refunds + 1, refunded + part, sent + part, back + got);
                _checkConservation();
            }
            uint256 spent = spentOf[b.ref];
            // A refund never returns more tokens than the purchase took.
            assertLe(back, spent, "refund returned more tokens than paid");
            tokensSpent += spent;
            tokensBack += back;
            if (spent - back > maxShortTokens) maxShortTokens = spent - back;
        }
        int256 floatPnl = int256(_valueUsd(address(conv))) - int256(floatBefore);
        int256 issuerPnl = int256(_valueUsd(settlement) + _valueUsd(issuer)) - int256(settlementBefore + issuerBefore);
        int256 holdersPnl = int256(_holdersValue()) - int256(holdersBefore);
        _log(t, "purchases", buys.length);
        _log(t, "refunds", refunds);
        _log(t, "refunds_reverted", failed);
        _logAmount(t, "refunded_usd", int256(refunded));
        _log(t, "tokens_spent", tokensSpent);
        _log(t, "tokens_back", tokensBack);
        _log(t, "tokens_short", tokensSpent - tokensBack);
        _log(t, "max_tokens_short_per_purchase", maxShortTokens);
        _logAmount(t, "float_pnl_usd", floatPnl);
        _logAmount(t, "issuer_pnl_usd", issuerPnl);
        _logAmount(t, "holders_pnl_usd", holdersPnl);
        // Value moved only between these three and the venue.
        assertEq(failed, 0, "refunds reverted");
    }

    function _holdersValue() internal view returns (uint256 sum) {
        for (uint256 k; k < holders.length; ++k) {
            sum += _valueUsd(holders[k]);
        }
    }
}
