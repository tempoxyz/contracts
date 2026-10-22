// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    BPS_DENOMINATOR,
    FeeAllocation,
    FeeConfig,
    FeePreview,
    MAX_FIXED_FEE_RECIPIENTS
} from "../interfaces/core/EarnFeeTypes.sol";

library EarnFeeMath {
    uint256 internal constant YEAR = 365 days;

    struct Input {
        uint256 activeAssets;
        uint256 earnShareSupply;
        uint256 earnShareScale;
        uint256 highWaterMark;
        uint256 targetBase;
        uint256 targetStartedAt;
        uint256 timestamp;
    }

    function targetAt(uint256 base, uint256 annualRateBps, uint256 startedAt, uint256 timestamp)
        internal
        pure
        returns (uint256 target)
    {
        target = base;
        if (base == 0 || annualRateBps == 0 || timestamp <= startedAt) return target;

        uint256 annualGrowth = Math.mulDiv(base, annualRateBps, BPS_DENOMINATOR);
        target += Math.mulDiv(annualGrowth, timestamp - startedAt, YEAR);
    }

    function valuePerEarnShare(uint256 activeAssets, uint256 earnShareScale, uint256 earnShareSupply)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(activeAssets, earnShareScale, earnShareSupply);
    }

    /// @dev Stored fee baselines round up so unrepresentable value is treated as already
    ///      checkpointed. This deliberately favors holders over charging the same fractional
    ///      value band more than once.
    function valuePerEarnShareUp(uint256 activeAssets, uint256 earnShareScale, uint256 earnShareSupply)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(activeAssets, earnShareScale, earnShareSupply, Math.Rounding.Ceil);
    }

    function preview(Input memory input, FeeConfig memory config, uint256[5] memory remainders)
        internal
        pure
        returns (FeePreview memory result, uint256[5] memory nextRemainders)
    {
        result.activeAssets = input.activeAssets;
        if (input.earnShareSupply == 0 || input.earnShareScale == 0) {
            return (result, remainders);
        }

        result.preFeeValuePerEarnShare =
            valuePerEarnShare(input.activeAssets, input.earnShareScale, input.earnShareSupply);
        result.targetValuePerEarnShare = config.excess.enabled
            ? targetAt(input.targetBase, config.excess.annualTargetRateBps, input.targetStartedAt, input.timestamp)
            : 0;

        if (result.preFeeValuePerEarnShare > input.highWaterMark) {
            result.positiveAccrualAssets = Math.mulDiv(
                result.preFeeValuePerEarnShare - input.highWaterMark, input.earnShareSupply, input.earnShareScale
            );
        }

        uint256 fixedCount = config.fixedFeeCount;
        for (uint256 i = 0; i < fixedCount && i < MAX_FIXED_FEE_RECIPIENTS; i++) {
            (uint256 feeAssets, uint256 remainder) =
                _withRemainder(result.positiveAccrualAssets, config.fixedFees[i].rateBps, remainders[i]);
            nextRemainders[i] = remainder;
            result.fixedFeeAssets += feeAssets;
            result.allocations[result.allocationCount++] = FeeAllocation(config.fixedFees[i].account, feeAssets, 0);
        }
        _capFixedFeeAssets(result, nextRemainders);

        if (config.excess.enabled) {
            uint256 afterFixed =
                input.activeAssets > result.fixedFeeAssets ? input.activeAssets - result.fixedFeeAssets : 0;
            uint256 excessBase;
            if (result.targetValuePerEarnShare < result.preFeeValuePerEarnShare) {
                uint256 targetAssets =
                    Math.mulDiv(result.targetValuePerEarnShare, input.earnShareSupply, input.earnShareScale);
                excessBase = afterFixed > targetAssets ? afterFixed - targetAssets : 0;
            }
            uint256 remainingAccrual = result.positiveAccrualAssets > result.fixedFeeAssets
                ? result.positiveAccrualAssets - result.fixedFeeAssets
                : 0;
            if (excessBase > remainingAccrual) excessBase = remainingAccrual;

            (result.excessFeeAssets, nextRemainders[4]) =
                _withRemainder(excessBase, config.excess.excessFeeRateBps, remainders[4]);
            result.allocations[result.allocationCount++] =
                FeeAllocation(config.excess.account, result.excessFeeAssets, 0);
        }

        result.totalFeeAssets = result.fixedFeeAssets + result.excessFeeAssets;
        if (result.totalFeeAssets > result.positiveAccrualAssets) {
            result.totalFeeAssets = result.positiveAccrualAssets;
        }

        if (result.totalFeeAssets != 0 && result.totalFeeAssets < input.activeAssets) {
            result.totalFeeEarnShares =
                Math.mulDiv(result.totalFeeAssets, input.earnShareSupply, input.activeAssets - result.totalFeeAssets);
            _allocateEarn(result);
        }

        uint256 postEarnShareSupply = input.earnShareSupply + result.totalFeeEarnShares;
        result.postFeeValuePerEarnShare =
            valuePerEarnShareUp(input.activeAssets, input.earnShareScale, postEarnShareSupply);
    }

    function _withRemainder(uint256 value, uint256 rateBps, uint256 oldRemainder)
        private
        pure
        returns (uint256 quotient, uint256 remainder)
    {
        quotient = Math.mulDiv(value, rateBps, BPS_DENOMINATOR) + oldRemainder / BPS_DENOMINATOR;
        remainder = mulmod(value, rateBps, BPS_DENOMINATOR) + oldRemainder % BPS_DENOMINATOR;
        if (remainder >= BPS_DENOMINATOR) {
            quotient += 1;
            remainder -= BPS_DENOMINATOR;
        }
    }

    function _capFixedFeeAssets(FeePreview memory result, uint256[5] memory nextRemainders) private pure {
        uint256 uncapped = result.fixedFeeAssets;
        uint256 cap = result.positiveAccrualAssets;
        if (uncapped <= cap) return;

        uint256 count = result.allocationCount;
        uint256[4] memory rawFeeAssets;
        uint256[4] memory fractionalRanks;
        bool[4] memory awarded;
        uint256 assigned;

        for (uint256 i = 0; i < count; i++) {
            uint256 raw = result.allocations[i].feeAssets;
            rawFeeAssets[i] = raw;
            uint256 normalized = Math.mulDiv(raw, cap, uncapped);
            result.allocations[i].feeAssets = normalized;
            fractionalRanks[i] = mulmod(raw, cap, uncapped);
            assigned += normalized;
        }

        // The sum of proportional floors is short by fewer than `count` units, so this loop
        // executes at most MAX_FIXED_FEE_RECIPIENTS - 1 times.
        uint256 unassigned = cap - assigned;
        for (uint256 award = 0; award < unassigned; award++) {
            uint256 selected;
            uint256 highestRank;
            bool found;
            for (uint256 i = 0; i < count; i++) {
                if (awarded[i] || result.allocations[i].feeAssets == rawFeeAssets[i]) continue;
                uint256 rank = fractionalRanks[i];
                if (!found || rank >= highestRank) {
                    selected = i;
                    highestRank = rank;
                    found = true;
                }
            }
            result.allocations[selected].feeAssets += 1;
            awarded[selected] = true;
        }

        result.fixedFeeAssets = cap;
        for (uint256 i = 0; i < count; i++) {
            nextRemainders[i] += (rawFeeAssets[i] - result.allocations[i].feeAssets) * BPS_DENOMINATOR;
        }
    }

    function _allocateEarn(FeePreview memory result) private pure {
        uint256 assigned = 0;
        uint256 lastNonzero = type(uint256).max;
        for (uint256 i = 0; i < result.allocationCount; i++) {
            if (result.allocations[i].feeAssets != 0) lastNonzero = i;
        }
        if (lastNonzero == type(uint256).max) return;

        for (uint256 i = 0; i < result.allocationCount; i++) {
            if (i == lastNonzero) {
                result.allocations[i].feeEarnShares = result.totalFeeEarnShares - assigned;
            } else if (result.allocations[i].feeAssets != 0) {
                uint256 feeEarnShares =
                    Math.mulDiv(result.totalFeeEarnShares, result.allocations[i].feeAssets, result.totalFeeAssets);
                result.allocations[i].feeEarnShares = feeEarnShares;
                assigned += feeEarnShares;
            }
        }
    }
}
