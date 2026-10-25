// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

import { EarnFeeMath } from "../../src/core/EarnFeeMath.sol";
import {
    ExcessReturnFee,
    BPS_DENOMINATOR,
    FeeConfig,
    FeePreview,
    FixedFeeRecipient
} from "../../src/interfaces/core/EarnFeeTypes.sol";

contract EarnFeeMathFuzzHarness {
    function preview(EarnFeeMath.Input memory input, FeeConfig memory config)
        external
        pure
        returns (FeePreview memory result, uint256[5] memory nextRemainders)
    {
        return EarnFeeMath.preview(input, config, [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)]);
    }

    function preview(EarnFeeMath.Input memory input, FeeConfig memory config, uint256[5] memory remainders)
        external
        pure
        returns (FeePreview memory result, uint256[5] memory nextRemainders)
    {
        return EarnFeeMath.preview(input, config, remainders);
    }

    function targetAt(uint256 base, uint256 annualRateBps, uint256 startedAt, uint256 timestamp)
        external
        pure
        returns (uint256)
    {
        return EarnFeeMath.targetAt(base, annualRateBps, startedAt, timestamp);
    }
}

contract EarnFeeMathFuzzTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant YEAR = 365 days;
    address private constant FIXED_ONE = address(0xF1);
    address private constant FIXED_TWO = address(0xF2);
    address private constant EXCESS = address(0xE1);

    EarnFeeMathFuzzHarness private harness;

    function setUp() public {
        harness = new EarnFeeMathFuzzHarness();
    }

    /// @dev Simultaneous fixed-fee remainder carry is normalized before fee shares are allocated.
    function testCarriedFixedFeesCannotExceedPositiveAccrual() public view {
        FeeConfig memory config;
        config.fixedFeeCount = 3;
        config.fixedFees[0] = FixedFeeRecipient({ account: address(1), rateBps: 3_334 });
        config.fixedFees[1] = FixedFeeRecipient({ account: address(2), rateBps: 3_333 });
        config.fixedFees[2] = FixedFeeRecipient({ account: address(3), rateBps: 3_333 });
        uint256[5] memory remainders = [uint256(6_666), 6_667, 6_667, 0, 0];

        (FeePreview memory result, uint256[5] memory nextRemainders) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: 2,
                earnShareSupply: 1,
                earnShareScale: 1,
                highWaterMark: 1,
                targetBase: 0,
                targetStartedAt: 0,
                timestamp: 0
            }),
            config,
            remainders
        );

        assertEq(result.positiveAccrualAssets, 1);
        assertEq(result.fixedFeeAssets, 1);
        assertEq(result.excessFeeAssets, 0);
        assertEq(result.totalFeeAssets, 1);
        assertEq(result.totalFeeEarnShares, 1);
        assertEq(result.allocationCount, 3);
        assertEq(result.allocations[0].feeAssets, 0);
        assertEq(result.allocations[1].feeAssets, 0);
        assertEq(result.allocations[2].feeAssets, 1);
        assertEq(result.allocations[0].feeEarnShares, 0);
        assertEq(result.allocations[1].feeEarnShares, 0);
        assertEq(result.allocations[2].feeEarnShares, 1);
        assertEq(nextRemainders[0], BPS_DENOMINATOR);
        assertEq(nextRemainders[1], BPS_DENOMINATOR);
        assertEq(nextRemainders[2], 0);

        for (uint256 i = 0; i < config.fixedFeeCount; i++) {
            assertEq(
                result.allocations[i].feeAssets * BPS_DENOMINATOR + nextRemainders[i],
                result.positiveAccrualAssets * config.fixedFees[i].rateBps + remainders[i]
            );
        }
    }

    /// @dev Equal target and pre-fee values charge no excess fee despite lossy asset conversion.
    function testPreviewDoesNotChargeExcessWhenTargetEqualsPreFeeValue() public view {
        FeeConfig memory config;
        config.excess = ExcessReturnFee({
            enabled: true, account: EXCESS, annualTargetRateBps: 0, excessFeeRateBps: uint16(BPS_DENOMINATOR)
        });

        (FeePreview memory result,) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: 5,
                earnShareSupply: 3,
                earnShareScale: 10,
                highWaterMark: 10,
                targetBase: 16,
                targetStartedAt: 0,
                timestamp: 0
            }),
            config
        );

        assertEq(result.preFeeValuePerEarnShare, 16);
        assertEq(result.targetValuePerEarnShare, 16);
        assertEq(result.positiveAccrualAssets, 1);
        assertEq(result.excessFeeAssets, 0);
        assertEq(result.totalFeeAssets, 0);
    }

    /// @dev Carried per-recipient rounding cannot make aggregate fees exceed current positive accrual.
    function testPreviewCapsAggregateWhenCarriedRoundingExceedsAccrual() public view {
        FeeConfig memory config;
        config.fixedFeeCount = 2;
        config.fixedFees[0] = FixedFeeRecipient({ account: FIXED_ONE, rateBps: 5_000 });
        config.fixedFees[1] = FixedFeeRecipient({ account: FIXED_TWO, rateBps: 5_000 });
        config.excess =
            ExcessReturnFee({ enabled: true, account: EXCESS, annualTargetRateBps: 0, excessFeeRateBps: 1_000 });
        uint256[5] memory remainders;
        remainders[0] = 5_000;
        remainders[1] = 5_000;

        (FeePreview memory result,) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: 1,
                earnShareSupply: 1,
                earnShareScale: 1,
                highWaterMark: 0,
                targetBase: 0,
                targetStartedAt: 0,
                timestamp: 0
            }),
            config,
            remainders
        );

        assertEq(result.positiveAccrualAssets, 1);
        assertEq(result.totalFeeAssets, 1);
        assertEq(result.totalFeeEarnShares, 0);
        assertEq(result.postFeeValuePerEarnShare, 1);
    }

    /// @dev Fee-share division residue belongs to the final recipient with a nonzero asset allocation.
    function testPreviewAllocatesRoundingResidueToLastNonzeroRecipient() public view {
        FeeConfig memory config;
        config.fixedFeeCount = 4;
        config.fixedFees[0] = FixedFeeRecipient({ account: address(1), rateBps: 100 });
        config.fixedFees[1] = FixedFeeRecipient({ account: address(2), rateBps: 100 });
        config.fixedFees[2] = FixedFeeRecipient({ account: address(3), rateBps: 100 });
        config.fixedFees[3] = FixedFeeRecipient({ account: address(4), rateBps: 110 });
        config.excess = ExcessReturnFee({ enabled: true, account: EXCESS, annualTargetRateBps: 0, excessFeeRateBps: 0 });

        (FeePreview memory result,) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: 2_000,
                earnShareSupply: 1_000,
                earnShareScale: 1_000,
                highWaterMark: 1_000,
                targetBase: 2_000,
                targetStartedAt: 1,
                timestamp: 1
            }),
            config
        );

        assertEq(result.allocationCount, 5);
        assertEq(result.totalFeeAssets, 41);
        assertEq(result.totalFeeEarnShares, 20);
        assertEq(result.allocations[0].feeEarnShares, 4);
        assertEq(result.allocations[1].feeEarnShares, 4);
        assertEq(result.allocations[2].feeEarnShares, 4);
        assertEq(result.allocations[3].feeEarnShares, 8);
        assertEq(result.allocations[4].feeAssets, 0);
        assertEq(result.allocations[4].feeEarnShares, 0);
    }

    /// @dev A fee equal to all active assets cannot mint shares against a zero post-fee denominator.
    function testPreviewDoesNotMintFeeSharesWhenFeesConsumeAllAssets() public view {
        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient({ account: FIXED_ONE, rateBps: uint16(BPS_DENOMINATOR) });

        (FeePreview memory result,) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: 100,
                earnShareSupply: 100,
                earnShareScale: 100,
                highWaterMark: 0,
                targetBase: 0,
                targetStartedAt: 0,
                timestamp: 0
            }),
            config
        );

        assertEq(result.positiveAccrualAssets, 100);
        assertEq(result.totalFeeAssets, 100);
        assertEq(result.totalFeeEarnShares, 0);
        assertEq(result.postFeeValuePerEarnShare, 100);
    }

    /// @dev Largest-remainder apportionment never grants more than a recipient's uncapped fee entitlement.
    function testFixedFeeCapUsesProportionalLargestRemainders() public view {
        FeeConfig memory config;
        config.fixedFeeCount = 4;
        config.fixedFees[0] = FixedFeeRecipient({ account: address(1), rateBps: 9_997 });
        config.fixedFees[1] = FixedFeeRecipient({ account: address(2), rateBps: 1 });
        config.fixedFees[2] = FixedFeeRecipient({ account: address(3), rateBps: 1 });
        config.fixedFees[3] = FixedFeeRecipient({ account: address(4), rateBps: 1 });
        uint256[5] memory remainders = [uint256(6), 9_998, 9_998, 9_998, 0];

        (FeePreview memory result, uint256[5] memory nextRemainders) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: 3,
                earnShareSupply: 1,
                earnShareScale: 1,
                highWaterMark: 1,
                targetBase: 0,
                targetStartedAt: 0,
                timestamp: 0
            }),
            config,
            remainders
        );

        uint256[4] memory expectedFeeAssets = [uint256(1), 0, 0, 1];
        uint256[4] memory expectedRemainders = [uint256(BPS_DENOMINATOR), BPS_DENOMINATOR, BPS_DENOMINATOR, 0];
        assertEq(result.fixedFeeAssets, 2);
        assertEq(result.totalFeeAssets, 2);
        assertEq(result.totalFeeEarnShares, 2);
        for (uint256 i = 0; i < config.fixedFeeCount; i++) {
            assertEq(result.allocations[i].feeAssets, expectedFeeAssets[i]);
            assertEq(result.allocations[i].feeEarnShares, expectedFeeAssets[i]);
            assertEq(nextRemainders[i], expectedRemainders[i]);
            assertEq(
                result.allocations[i].feeAssets * BPS_DENOMINATOR + nextRemainders[i],
                result.positiveAccrualAssets * config.fixedFees[i].rateBps + remainders[i]
            );
        }
    }

    /// @dev Capping preserves each fixed recipient's accrued entitlement across arbitrary whole-unit carry.
    function testFuzzFixedFeeCapPreservesRecipientEntitlement(
        uint96 positiveAccrual,
        uint32 firstRemainder,
        uint32 secondRemainder,
        uint32 thirdRemainder
    ) public view {
        positiveAccrual = uint96(bound(positiveAccrual, 1, 1e24));
        uint256[5] memory remainders;
        remainders[0] = bound(firstRemainder, 0, 3 * BPS_DENOMINATOR - 1);
        remainders[1] = bound(secondRemainder, 0, 3 * BPS_DENOMINATOR - 1);
        remainders[2] = bound(thirdRemainder, 0, 3 * BPS_DENOMINATOR - 1);

        FeeConfig memory config;
        config.fixedFeeCount = 3;
        config.fixedFees[0] = FixedFeeRecipient({ account: address(1), rateBps: 3_334 });
        config.fixedFees[1] = FixedFeeRecipient({ account: address(2), rateBps: 3_333 });
        config.fixedFees[2] = FixedFeeRecipient({ account: address(3), rateBps: 3_333 });

        (FeePreview memory result, uint256[5] memory nextRemainders) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: uint256(positiveAccrual) + 1,
                earnShareSupply: 1,
                earnShareScale: 1,
                highWaterMark: 1,
                targetBase: 0,
                targetStartedAt: 0,
                timestamp: 0
            }),
            config,
            remainders
        );

        uint256 allocatedAssets;
        uint256 allocatedEarnShares;
        for (uint256 i = 0; i < config.fixedFeeCount; i++) {
            allocatedAssets += result.allocations[i].feeAssets;
            allocatedEarnShares += result.allocations[i].feeEarnShares;
            assertEq(
                result.allocations[i].feeAssets * BPS_DENOMINATOR + nextRemainders[i],
                result.positiveAccrualAssets * config.fixedFees[i].rateBps + remainders[i]
            );
        }
        assertLe(result.fixedFeeAssets, result.positiveAccrualAssets);
        assertEq(result.totalFeeAssets, result.fixedFeeAssets);
        assertEq(allocatedAssets, result.totalFeeAssets);
        assertEq(allocatedEarnShares, result.totalFeeEarnShares);
    }

    function testFuzzPreviewFeesStayWithinPositiveAccrualAndAllocateExactly(
        uint256 activeAssets,
        uint256 earnShareSupply,
        uint256 highWaterMark,
        uint16 fixedRateOneBps,
        uint16 fixedRateTwoBps,
        uint16 annualTargetRateBps,
        uint16 excessFeeRateBps,
        uint32 elapsed
    ) public view {
        activeAssets = bound(activeAssets, 1e6, 1e36);
        earnShareSupply = bound(earnShareSupply, 1e6, 1e30);
        fixedRateOneBps = uint16(bound(fixedRateOneBps, 1, 1_250));
        fixedRateTwoBps = uint16(bound(fixedRateTwoBps, 1, 1_250));
        annualTargetRateBps = uint16(bound(annualTargetRateBps, 0, BPS_DENOMINATOR));
        excessFeeRateBps = uint16(bound(excessFeeRateBps, 1, BPS_DENOMINATOR));
        elapsed = uint32(bound(elapsed, 0, 10 * 365 days));

        uint256 preFeeValue = activeAssets * WAD / earnShareSupply;
        highWaterMark = bound(highWaterMark, 0, preFeeValue > type(uint128).max ? type(uint128).max : preFeeValue);

        FeeConfig memory config;
        config.fixedFeeCount = 2;
        config.fixedFees[0] = FixedFeeRecipient({ account: FIXED_ONE, rateBps: fixedRateOneBps });
        config.fixedFees[1] = FixedFeeRecipient({ account: FIXED_TWO, rateBps: fixedRateTwoBps });
        config.excess = ExcessReturnFee({
            enabled: true, account: EXCESS, annualTargetRateBps: annualTargetRateBps, excessFeeRateBps: excessFeeRateBps
        });

        (FeePreview memory result, uint256[5] memory nextRemainders) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: activeAssets,
                earnShareSupply: earnShareSupply,
                earnShareScale: WAD,
                highWaterMark: highWaterMark,
                targetBase: highWaterMark,
                targetStartedAt: 1,
                timestamp: 1 + elapsed
            }),
            config
        );

        assertLe(result.positiveAccrualAssets, activeAssets);
        assertLe(result.totalFeeAssets, result.positiveAccrualAssets);
        assertEq(result.totalFeeAssets, result.fixedFeeAssets + result.excessFeeAssets);
        uint256 postSupply = earnShareSupply + result.totalFeeEarnShares;
        uint256 expectedPostFeeValue = (activeAssets * WAD + postSupply - 1) / postSupply;
        assertEq(result.postFeeValuePerEarnShare, expectedPostFeeValue);

        uint256 allocatedAssets;
        uint256 allocatedEarnShares;
        for (uint256 i = 0; i < result.allocationCount; i++) {
            allocatedAssets += result.allocations[i].feeAssets;
            allocatedEarnShares += result.allocations[i].feeEarnShares;
        }
        assertEq(allocatedAssets, result.totalFeeAssets);
        assertEq(allocatedEarnShares, result.totalFeeEarnShares);
        for (uint256 i = 0; i < nextRemainders.length; i++) {
            assertLt(nextRemainders[i], BPS_DENOMINATOR);
        }
    }

    /// @dev Fuzzed target growth must match an independently calculated linear reference.
    function testFuzzTargetGrowthMatchesLinearReference(uint128 base, uint16 annualRateBps, uint32 elapsed)
        public
        view
    {
        annualRateBps = uint16(bound(annualRateBps, 0, BPS_DENOMINATOR));
        elapsed = uint32(bound(elapsed, 0, 100 * YEAR));

        uint256 annualGrowth = uint256(base) * annualRateBps / BPS_DENOMINATOR;
        uint256 expected = uint256(base) + annualGrowth * elapsed / YEAR;
        assertEq(harness.targetAt(base, annualRateBps, 100, 100 + elapsed), expected);
    }

    /// @dev Fuzzed fixed fees, dust carry, minted shares, and post-fee value must match a direct reference.
    function testFuzzFixedFeeAndRemainderMatchReference(uint128 activeAssets, uint16 rateBps, uint16 oldRemainder)
        public
        view
    {
        activeAssets = uint128(bound(activeAssets, 1, 1e30));
        rateBps = uint16(bound(rateBps, 0, BPS_DENOMINATOR));
        oldRemainder = uint16(bound(oldRemainder, 0, BPS_DENOMINATOR - 1));

        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient({ account: FIXED_ONE, rateBps: rateBps });
        uint256[5] memory remainders;
        remainders[0] = oldRemainder;

        (FeePreview memory result, uint256[5] memory nextRemainders) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: activeAssets,
                earnShareSupply: 1,
                earnShareScale: 1,
                highWaterMark: 0,
                targetBase: 0,
                targetStartedAt: 0,
                timestamp: 0
            }),
            config,
            remainders
        );

        uint256 numerator = uint256(activeAssets) * rateBps + oldRemainder;
        uint256 expectedFeeAssets = numerator / BPS_DENOMINATOR;
        uint256 expectedFeeEarnShares = expectedFeeAssets != 0 && expectedFeeAssets < activeAssets
            ? expectedFeeAssets / (uint256(activeAssets) - expectedFeeAssets)
            : 0;

        assertEq(result.positiveAccrualAssets, activeAssets);
        assertEq(result.fixedFeeAssets, expectedFeeAssets);
        assertEq(result.totalFeeAssets, expectedFeeAssets);
        assertEq(nextRemainders[0], numerator % BPS_DENOMINATOR);
        assertEq(result.allocationCount, 1);
        assertEq(result.allocations[0].account, FIXED_ONE);
        assertEq(result.allocations[0].feeAssets, expectedFeeAssets);
        assertEq(result.totalFeeEarnShares, expectedFeeEarnShares);
        assertEq(result.allocations[0].feeEarnShares, expectedFeeEarnShares);
        uint256 postSupply = 1 + expectedFeeEarnShares;
        assertEq(result.postFeeValuePerEarnShare, (uint256(activeAssets) + postSupply - 1) / postSupply);
    }

    /// @dev Symbolically proves that fixed-fee quotient and remainder preserve the full accrued entitlement.
    function proveFixedFeeRemainderConservation(uint16 oldRemainder) public view {
        vm.assume(oldRemainder < BPS_DENOMINATOR);

        uint256 activeAssets = 99;
        uint16 rateBps = 1_000;
        uint256 numerator = activeAssets * rateBps + oldRemainder;

        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient({ account: FIXED_ONE, rateBps: rateBps });
        uint256[5] memory remainders;
        remainders[0] = oldRemainder;

        (FeePreview memory result, uint256[5] memory nextRemainders) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: activeAssets,
                earnShareSupply: 1,
                earnShareScale: 1,
                highWaterMark: 0,
                targetBase: 0,
                targetStartedAt: 0,
                timestamp: 0
            }),
            config,
            remainders
        );

        assertEq(result.fixedFeeAssets * BPS_DENOMINATOR + nextRemainders[0], numerator);
        assertLt(nextRemainders[0], BPS_DENOMINATOR);
    }

    /// @dev Symbolically proves the fee-share result is the floor of the exact ratio across the carry boundary.
    function proveFeeShareConversionIsFloorAcrossCarryBoundary(uint16 oldRemainder) public view {
        vm.assume(oldRemainder < BPS_DENOMINATOR);

        uint256 activeAssets = 99;
        uint256 earnShareSupply = 100;

        FeeConfig memory config;
        config.fixedFeeCount = 1;
        config.fixedFees[0] = FixedFeeRecipient({ account: FIXED_ONE, rateBps: 1_000 });
        uint256[5] memory remainders;
        remainders[0] = oldRemainder;

        (FeePreview memory result,) = harness.preview(
            EarnFeeMath.Input({
                activeAssets: activeAssets,
                earnShareSupply: earnShareSupply,
                earnShareScale: 100,
                highWaterMark: 0,
                targetBase: 0,
                targetStartedAt: 0,
                timestamp: 0
            }),
            config,
            remainders
        );

        uint256 denominator = activeAssets - result.totalFeeAssets;
        uint256 numerator = result.totalFeeAssets * earnShareSupply;
        uint256 feeEarnShares = result.totalFeeEarnShares;

        assertLe(feeEarnShares * denominator, numerator);
        assertGt((feeEarnShares + 1) * denominator, numerator);
    }
}
