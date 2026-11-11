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

/// @dev The `@custom:` specs are checked by solar-verify and state the rules of
///      docs/earn/architecture/fees.md. Spec arithmetic is over mathematical integers, so `a * b / d`
///      is the exact floor `Math.mulDiv` returns. The spec helpers at the end are never executed.
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

    /// @notice The target grows by simple annual interest, prorated by the second (fees.md, "High-water mark and
    ///         target").
    /// @custom:ensures target == targetFrom(base, annualRateBps, startedAt, timestamp)
    /// @custom:succeeds-if !targetGrows(base, annualRateBps, startedAt, timestamp)
    /// @custom:succeeds-if base <= type(uint128).max && annualRateBps <= BPS_DENOMINATOR && timestamp <= type(uint64).max
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

    /// @custom:ensures result == activeAssets * earnShareScale / earnShareSupply
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
    /// @custom:ensures result == ceilDiv(activeAssets * earnShareScale, earnShareSupply)
    function valuePerEarnShareUp(uint256 activeAssets, uint256 earnShareScale, uint256 earnShareSupply)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(activeAssets, earnShareScale, earnShareSupply, Math.Rounding.Ceil);
    }

    /// @notice Fees never exceed gross positive accrual, and the recipients' fee EarnShare sum exactly to the
    ///         total the vault mints (fees.md, "Fee calculation" and "Allocation").
    /// @custom:ensures result.activeAssets == input.activeAssets
    /// @custom:ensures result.allocationCount <= MAX_FIXED_FEE_RECIPIENTS + 1
    /// @custom:ensures result.totalFeeEarnShares == allocatedFeeEarnShares(result)
    /// @custom:ensures result.totalFeeAssets <= allocatedFeeAssets(result)
    /// @custom:ensures result.totalFeeAssets <= result.positiveAccrualAssets
    /// @custom:ensures !priced(input) ==> chargesNothing(result)
    /// @custom:ensures priced(input) ==> result.allocationCount == allocationCountFor(config)
    /// @custom:ensures priced(input) ==> result.preFeeValuePerEarnShare == preFeeValue(input)
    /// @custom:ensures priced(input) ==> result.positiveAccrualAssets == positiveAccrual(input, preFeeValue(input))
    /// @custom:ensures priced(input) ==> result.targetValuePerEarnShare == targetValue(input, config)
    /// @custom:ensures !config.excess.enabled ==> result.excessFeeAssets == 0
    /// @custom:ensures priced(input) ==> result.totalFeeAssets == cappedTotalFeeAssets(result)
    /// @custom:ensures priced(input) ==> result.totalFeeEarnShares == feeEarnSharesFor(result, input)
    /// @custom:ensures priced(input) ==> result.postFeeValuePerEarnShare == postFeeValue(input, result)
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
        /// @custom:invariant i <= MAX_FIXED_FEE_RECIPIENTS && (i <= fixedCount || i == 0)
        /// @custom:invariant result.allocationCount == i && result.fixedFeeAssets == sumFeeAssets(result, i)
        /// @custom:invariant result.totalFeeEarnShares == 0 && noFeeEarnShares(result)
        /// @custom:invariant result.excessFeeAssets == 0 && result.totalFeeAssets == 0
        /// @custom:invariant result.activeAssets == input.activeAssets && result.postFeeValuePerEarnShare == 0
        /// @custom:invariant result.preFeeValuePerEarnShare == preFeeValue(input)
        /// @custom:invariant result.positiveAccrualAssets == positiveAccrual(input, preFeeValue(input))
        /// @custom:invariant result.targetValuePerEarnShare == targetValue(input, config)
        for (uint256 i = 0; i < fixedCount && i < MAX_FIXED_FEE_RECIPIENTS; i++) {
            (uint256 feeAssets, uint256 remainder) =
                _withRemainder(result.positiveAccrualAssets, config.fixedFees[i].rateBps, remainders[i]);
            nextRemainders[i] = remainder;
            result.fixedFeeAssets += feeAssets;
            result.allocations[result.allocationCount++] = FeeAllocation(config.fixedFees[i].account, feeAssets, 0);
        }
        /// @custom:assert result.allocationCount == min(fixedCount, MAX_FIXED_FEE_RECIPIENTS)
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

        /// @custom:assert result.fixedFeeAssets + result.excessFeeAssets == allocatedFeeAssets(result)
        /// @custom:assert result.totalFeeEarnShares == 0 && noFeeEarnShares(result)
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

    /// @notice Adds `value * rateBps` basis-point units to a carried remainder and returns the whole units.
    /// @custom:ensures quotient * BPS_DENOMINATOR + remainder == value * rateBps + oldRemainder
    /// @custom:ensures remainder < BPS_DENOMINATOR
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

    /// @notice Scales fixed fees above the accrual down to it by largest remainder; each unpaid whole unit
    ///         returns to its recipient's remainder (fees.md, "Fee calculation", step 3).
    /// @custom:requires result.allocationCount <= MAX_FIXED_FEE_RECIPIENTS
    /// @custom:requires result.fixedFeeAssets == allocatedFeeAssets(result)
    /// @custom:requires result.totalFeeEarnShares == 0 && noFeeEarnShares(result)
    /// @custom:ensures result.fixedFeeAssets == allocatedFeeAssets(result)
    /// @custom:ensures result.fixedFeeAssets == min(old(result.fixedFeeAssets), result.positiveAccrualAssets)
    /// @custom:ensures result.totalFeeEarnShares == 0 && noFeeEarnShares(result)
    /// @custom:ensures sameExceptFeeAssets(result, old(result))
    /// @custom:ensures forall uint256 k :: k < 5 ==> result.allocations[k].account == old(result.allocations[k].account)
    /// @custom:ensures forall uint256 k :: k < 5 ==> result.allocations[k].feeAssets <= old(result.allocations[k].feeAssets)
    /// @custom:ensures forall uint256 k :: k < 5 ==> nextRemainders[k] == old(nextRemainders[k]) + unpaidUnits(result, old(result), k)
    function _capFixedFeeAssets(FeePreview memory result, uint256[5] memory nextRemainders) private pure {
        uint256 uncapped = result.fixedFeeAssets;
        uint256 cap = result.positiveAccrualAssets;
        if (uncapped <= cap) return;

        uint256 count = result.allocationCount;
        uint256[4] memory rawFeeAssets;
        uint256[4] memory fractionalRanks;
        bool[4] memory awarded;
        uint256 assigned;

        /// @custom:invariant i <= count && count == result.allocationCount && count <= MAX_FIXED_FEE_RECIPIENTS
        /// @custom:invariant assigned == sumFeeAssets(result, i) && assigned <= cap
        /// @custom:invariant sumFirst(rawFeeAssets, i) + sumFeeAssets(result, count) - sumFeeAssets(result, i) == uncapped
        /// @custom:invariant assigned * uncapped <= cap * sumFirst(rawFeeAssets, i)
        /// @custom:invariant forall uint256 k :: k < i ==> rawFeeAssets[k] == old(result.allocations[k].feeAssets)
        /// @custom:invariant forall uint256 k :: k < i ==> result.allocations[k].feeAssets <= rawFeeAssets[k]
        /// @custom:invariant forall uint256 k :: k >= i ==> result.allocations[k].feeAssets == old(result.allocations[k].feeAssets)
        /// @custom:invariant forall uint256 k :: result.allocations[k].account == old(result.allocations[k].account)
        /// @custom:invariant forall uint256 k :: !awarded[k]
        /// @custom:invariant forall uint256 k :: nextRemainders[k] == old(nextRemainders[k])
        /// @custom:invariant result.totalFeeEarnShares == 0 && noFeeEarnShares(result)
        /// @custom:invariant sameExceptFeeAssets(result, old(result))
        /// @custom:invariant uncapped == result.fixedFeeAssets && cap == result.positiveAccrualAssets
        for (uint256 i = 0; i < count; i++) {
            uint256 raw = result.allocations[i].feeAssets;
            rawFeeAssets[i] = raw;
            uint256 normalized = Math.mulDiv(raw, cap, uncapped);
            result.allocations[i].feeAssets = normalized;
            fractionalRanks[i] = mulmod(raw, cap, uncapped);
            /// @custom:assert normalized * uncapped <= raw * cap
            assigned += normalized;
        }

        // The sum of proportional floors is short by fewer than `count` units, so this loop
        // executes at most MAX_FIXED_FEE_RECIPIENTS - 1 times.
        uint256 unassigned = cap - assigned;
        /// @custom:invariant award <= unassigned && assigned + unassigned == cap
        /// @custom:invariant count == result.allocationCount && count <= MAX_FIXED_FEE_RECIPIENTS && count >= 1
        /// @custom:invariant sumFeeAssets(result, count) == assigned + award
        /// @custom:invariant forall uint256 k :: k < count ==> rawFeeAssets[k] == old(result.allocations[k].feeAssets)
        /// @custom:invariant forall uint256 k :: k >= count ==> result.allocations[k].feeAssets == old(result.allocations[k].feeAssets)
        /// @custom:invariant forall uint256 k :: result.allocations[k].account == old(result.allocations[k].account)
        /// @custom:invariant forall uint256 k :: nextRemainders[k] == old(nextRemainders[k])
        /// @custom:invariant result.totalFeeEarnShares == 0 && noFeeEarnShares(result)
        /// @custom:invariant sameExceptFeeAssets(result, old(result))
        /// @custom:invariant cap == result.positiveAccrualAssets
        for (uint256 award = 0; award < unassigned; award++) {
            uint256 selected;
            uint256 highestRank;
            bool found;
            /// @custom:invariant i <= count && selected < count
            /// @custom:invariant found ==> (!awarded[selected] && result.allocations[selected].feeAssets != rawFeeAssets[selected])
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
        /// @custom:invariant i <= count && count == result.allocationCount && count <= MAX_FIXED_FEE_RECIPIENTS
        /// @custom:invariant forall uint256 k :: k < count ==> rawFeeAssets[k] == old(result.allocations[k].feeAssets)
        /// @custom:invariant forall uint256 k :: k < i ==> nextRemainders[k] == old(nextRemainders[k]) + unpaidUnits(result, old(result), k)
        /// @custom:invariant forall uint256 k :: k >= i ==> nextRemainders[k] == old(nextRemainders[k])
        /// @custom:invariant forall uint256 k :: k < i ==> result.allocations[k].feeAssets <= rawFeeAssets[k]
        for (uint256 i = 0; i < count; i++) {
            nextRemainders[i] += (rawFeeAssets[i] - result.allocations[i].feeAssets) * BPS_DENOMINATOR;
        }
    }

    /// @notice Converts the aggregate fee EarnShare once: each nonzero allocation gets its proportional share
    ///         rounded down, and the last nonzero one the rest (fees.md, "Allocation").
    /// @custom:requires result.allocationCount <= MAX_FIXED_FEE_RECIPIENTS + 1 && noFeeEarnShares(result)
    /// @custom:requires result.totalFeeAssets != 0 && result.totalFeeAssets <= allocatedFeeAssets(result)
    /// @custom:ensures result.totalFeeEarnShares == allocatedFeeEarnShares(result)
    /// @custom:ensures sameExceptFeeEarnShares(result, old(result))
    /// @custom:ensures forall uint256 k :: (k < result.allocationCount && k != lastNonzeroFee(result)) ==> isProRata(result, k)
    function _allocateEarn(FeePreview memory result) private pure {
        uint256 assigned = 0;
        uint256 lastNonzero = type(uint256).max;
        /// @custom:invariant i <= result.allocationCount
        /// @custom:invariant lastNonzero == type(uint256).max || (lastNonzero < i && result.allocations[lastNonzero].feeAssets != 0)
        /// @custom:invariant forall uint256 k :: (k < i && (lastNonzero == type(uint256).max || k > lastNonzero)) ==> result.allocations[k].feeAssets == 0
        for (uint256 i = 0; i < result.allocationCount; i++) {
            if (result.allocations[i].feeAssets != 0) lastNonzero = i;
        }
        if (lastNonzero == type(uint256).max) return;

        /// @custom:invariant i <= result.allocationCount && lastNonzero == lastNonzeroFee(result)
        /// @custom:invariant lastNonzero < result.allocationCount && result.allocations[lastNonzero].feeAssets != 0
        /// @custom:invariant forall uint256 k :: (k >= i && k <= MAX_FIXED_FEE_RECIPIENTS) ==> result.allocations[k].feeEarnShares == 0
        /// @custom:invariant i <= lastNonzero ==> sumFeeEarnShares(result, i) == assigned
        /// @custom:invariant i > lastNonzero ==> sumFeeEarnShares(result, i) == result.totalFeeEarnShares
        /// @custom:invariant forall uint256 k :: (k < i && k != lastNonzero) ==> isProRata(result, k)
        /// @custom:invariant sameExceptFeeEarnShares(result, old(result))
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

    // ---------------------------------------------------------------- spec helpers, never executed

    /// @custom:spec Whether the input has a supply and a scale to price fees against.
    function priced(Input memory input) internal pure returns (bool) {
        return input.earnShareSupply != 0 && input.earnShareScale != 0;
    }

    /// @custom:spec `ceil(numerator / denominator)`.
    function ceilDiv(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        return (numerator + denominator - 1) / denominator;
    }

    /// @custom:spec The smaller of `a` and `b`.
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @custom:spec Whether `targetAt` grows the base at all.
    function targetGrows(uint256 base, uint256 annualRateBps, uint256 startedAt, uint256 timestamp)
        internal
        pure
        returns (bool)
    {
        return base != 0 && annualRateBps != 0 && timestamp > startedAt;
    }

    /// @custom:spec `target(t) = base + base * annualRateBps / 10,000 * (t - startedAt) / 365 days` (fees.md).
    function targetFrom(uint256 base, uint256 annualRateBps, uint256 startedAt, uint256 timestamp)
        internal
        pure
        returns (uint256)
    {
        return EarnFeeMath.targetGrows(base, annualRateBps, startedAt, timestamp)
            ? base + EarnFeeMath.annualGrowth(base, annualRateBps) * (timestamp - startedAt) / EarnFeeMath.YEAR
            : base;
    }

    /// @custom:spec One year of simple growth at `annualRateBps`, rounded down.
    function annualGrowth(uint256 base, uint256 annualRateBps) internal pure returns (uint256) {
        return base * annualRateBps / BPS_DENOMINATOR;
    }

    /// @custom:spec The excess fee's target value per EarnShare now, or 0 without an excess fee.
    function targetValue(Input memory input, FeeConfig memory config) internal pure returns (uint256) {
        return config.excess.enabled
            ? EarnFeeMath.targetFrom(
                input.targetBase, config.excess.annualTargetRateBps, input.targetStartedAt, input.timestamp
            )
            : 0;
    }

    /// @custom:spec Value per EarnShare before fees, rounded down.
    function preFeeValue(Input memory input) internal pure returns (uint256) {
        return input.activeAssets * input.earnShareScale / input.earnShareSupply;
    }

    /// @custom:spec Gross positive accrual: value per EarnShare above the high-water mark, times supply.
    function positiveAccrual(Input memory input, uint256 valuePerShare) internal pure returns (uint256) {
        return valuePerShare > input.highWaterMark
            ? (valuePerShare - input.highWaterMark) * input.earnShareSupply / input.earnShareScale
            : 0;
    }

    /// @custom:spec One allocation per configured fixed fee (at most four), then one for an excess fee.
    function allocationCountFor(FeeConfig memory config) internal pure returns (uint256) {
        return EarnFeeMath.min(config.fixedFeeCount, MAX_FIXED_FEE_RECIPIENTS) + (config.excess.enabled ? 1 : 0);
    }

    /// @custom:spec Aggregate fees, capped at gross positive accrual.
    function cappedTotalFeeAssets(FeePreview memory fees) internal pure returns (uint256) {
        return EarnFeeMath.min(fees.fixedFeeAssets + fees.excessFeeAssets, fees.positiveAccrualAssets);
    }

    /// @custom:spec Fee EarnShare minted for `fees.totalFeeAssets` so holders keep the rest of the active assets.
    function feeEarnSharesFor(FeePreview memory fees, Input memory input) internal pure returns (uint256) {
        return (fees.totalFeeAssets != 0 && fees.totalFeeAssets < input.activeAssets)
            ? fees.totalFeeAssets * input.earnShareSupply / (input.activeAssets - fees.totalFeeAssets)
            : 0;
    }

    /// @custom:spec Value per EarnShare after the fee EarnShare is minted, rounded up.
    function postFeeValue(Input memory input, FeePreview memory fees) internal pure returns (uint256) {
        return EarnFeeMath.ceilDiv(
            input.activeAssets * input.earnShareScale, input.earnShareSupply + fees.totalFeeEarnShares
        );
    }

    /// @custom:spec A preview that charges nothing and reports no valuation.
    function chargesNothing(FeePreview memory fees) internal pure returns (bool) {
        return fees.allocationCount == 0 && fees.totalFeeAssets == 0 && fees.totalFeeEarnShares == 0
            && fees.positiveAccrualAssets == 0 && fees.fixedFeeAssets == 0 && fees.excessFeeAssets == 0
            && fees.preFeeValuePerEarnShare == 0 && fees.postFeeValuePerEarnShare == 0
            && fees.targetValuePerEarnShare == 0;
    }

    /// @custom:spec Fee assets of the first `count` allocations.
    function sumFeeAssets(FeePreview memory fees, uint256 count) internal pure returns (uint256) {
        return (count > 0 ? fees.allocations[0].feeAssets : 0) + (count > 1 ? fees.allocations[1].feeAssets : 0)
            + (count > 2 ? fees.allocations[2].feeAssets : 0) + (count > 3 ? fees.allocations[3].feeAssets : 0)
            + (count > 4 ? fees.allocations[4].feeAssets : 0);
    }

    /// @custom:spec Fee EarnShare of the first `count` allocations.
    function sumFeeEarnShares(FeePreview memory fees, uint256 count) internal pure returns (uint256) {
        return (count > 0 ? fees.allocations[0].feeEarnShares : 0) + (count > 1 ? fees.allocations[1].feeEarnShares : 0)
            + (count > 2 ? fees.allocations[2].feeEarnShares : 0) + (count > 3 ? fees.allocations[3].feeEarnShares : 0)
            + (count > 4 ? fees.allocations[4].feeEarnShares : 0);
    }

    /// @custom:spec Fee assets of every allocation.
    function allocatedFeeAssets(FeePreview memory fees) internal pure returns (uint256) {
        return EarnFeeMath.sumFeeAssets(fees, fees.allocationCount);
    }

    /// @custom:spec Fee EarnShare of every allocation.
    function allocatedFeeEarnShares(FeePreview memory fees) internal pure returns (uint256) {
        return EarnFeeMath.sumFeeEarnShares(fees, fees.allocationCount);
    }

    /// @custom:spec No allocation slot holds fee EarnShare yet.
    function noFeeEarnShares(FeePreview memory fees) internal pure returns (bool) {
        return fees.allocations[0].feeEarnShares == 0 && fees.allocations[1].feeEarnShares == 0
            && fees.allocations[2].feeEarnShares == 0 && fees.allocations[3].feeEarnShares == 0
            && fees.allocations[4].feeEarnShares == 0;
    }

    /// @custom:spec Sum of the first `count` of `values`.
    function sumFirst(uint256[4] memory values, uint256 count) internal pure returns (uint256) {
        return (count > 0 ? values[0] : 0) + (count > 1 ? values[1] : 0) + (count > 2 ? values[2] : 0)
            + (count > 3 ? values[3] : 0);
    }

    /// @custom:spec Basis-point units owed back to allocation `k`'s remainder for whole units the cap cut.
    function unpaidUnits(FeePreview memory fees, FeePreview memory before, uint256 k) internal pure returns (uint256) {
        return k < fees.allocationCount
            ? (before.allocations[k].feeAssets - fees.allocations[k].feeAssets) * BPS_DENOMINATOR
            : 0;
    }

    /// @custom:spec Allocation `k` holds its proportional share of the fee EarnShare, rounded down.
    function isProRata(FeePreview memory fees, uint256 k) internal pure returns (bool) {
        return fees.allocations[k].feeEarnShares
            == fees.totalFeeEarnShares * fees.allocations[k].feeAssets / fees.totalFeeAssets;
    }

    /// @custom:spec The last allocation with nonzero fee assets, in configured order (`type(uint256).max` if none).
    function lastNonzeroFee(FeePreview memory fees) internal pure returns (uint256) {
        uint256 count = fees.allocationCount;
        return (count > 4 && fees.allocations[4].feeAssets != 0)
            ? 4
            : (count > 3 && fees.allocations[3].feeAssets != 0)
                ? 3
                : (count > 2 && fees.allocations[2].feeAssets != 0)
                    ? 2
                    : (count > 1 && fees.allocations[1].feeAssets != 0)
                        ? 1
                        : (count > 0 && fees.allocations[0].feeAssets != 0) ? 0 : type(uint256).max;
    }

    /// @custom:spec `fees` equals `before` except in the allocations' fee assets and the fixed fee total.
    function sameExceptFeeAssets(FeePreview memory fees, FeePreview memory before) internal pure returns (bool) {
        return fees.activeAssets == before.activeAssets && fees.positiveAccrualAssets == before.positiveAccrualAssets
            && fees.excessFeeAssets == before.excessFeeAssets && fees.totalFeeAssets == before.totalFeeAssets
            && fees.totalFeeEarnShares == before.totalFeeEarnShares
            && fees.preFeeValuePerEarnShare == before.preFeeValuePerEarnShare
            && fees.postFeeValuePerEarnShare == before.postFeeValuePerEarnShare
            && fees.targetValuePerEarnShare == before.targetValuePerEarnShare
            && fees.allocationCount == before.allocationCount;
    }

    /// @custom:spec `fees` equals `before` except in the allocations' fee EarnShare.
    function sameExceptFeeEarnShares(FeePreview memory fees, FeePreview memory before) internal pure returns (bool) {
        return EarnFeeMath.sameExceptFeeAssets(fees, before) && fees.fixedFeeAssets == before.fixedFeeAssets
            && EarnFeeMath.sameAllocationAssets(fees, before, 0) && EarnFeeMath.sameAllocationAssets(fees, before, 1)
            && EarnFeeMath.sameAllocationAssets(fees, before, 2) && EarnFeeMath.sameAllocationAssets(fees, before, 3)
            && EarnFeeMath.sameAllocationAssets(fees, before, 4);
    }

    /// @custom:spec Allocation `k` has the same recipient and fee assets in `fees` and `before`.
    function sameAllocationAssets(FeePreview memory fees, FeePreview memory before, uint256 k)
        internal
        pure
        returns (bool)
    {
        return fees.allocations[k].account == before.allocations[k].account
            && fees.allocations[k].feeAssets == before.allocations[k].feeAssets;
    }
}
