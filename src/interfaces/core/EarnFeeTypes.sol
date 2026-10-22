// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

uint256 constant MAX_FIXED_FEE_RECIPIENTS = 4;
uint16 constant BPS_DENOMINATOR = 10_000;

struct FixedFeeRecipient {
    address account;
    uint16 rateBps;
}

struct ExcessReturnFee {
    bool enabled;
    address account;
    uint16 annualTargetRateBps;
    uint16 excessFeeRateBps;
}

struct FeeConfig {
    uint8 fixedFeeCount;
    FixedFeeRecipient[4] fixedFees;
    ExcessReturnFee excess;
}

struct FeeAllocation {
    address account;
    uint256 feeAssets;
    uint256 feeEarnShares;
}

struct FeePreview {
    uint256 activeAssets;
    uint256 positiveAccrualAssets;
    uint256 fixedFeeAssets;
    uint256 excessFeeAssets;
    uint256 totalFeeAssets;
    uint256 totalFeeEarnShares;
    uint256 preFeeValuePerEarnShare;
    uint256 postFeeValuePerEarnShare;
    uint256 targetValuePerEarnShare;
    uint8 allocationCount;
    FeeAllocation[5] allocations;
}
