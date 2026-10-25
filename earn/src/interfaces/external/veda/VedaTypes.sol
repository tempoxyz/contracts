// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev BoringOnChainQueue.OnChainWithdraw, field-for-field.
struct OnChainWithdraw {
    uint96 nonce;
    address user;
    address assetOut;
    uint128 amountOfShares;
    uint128 amountOfAssets;
    uint40 creationTime;
    uint24 secondsToMaturity;
    uint24 secondsToDeadline;
}

/// @notice Typed Veda queue terms encoded into the generic async-engine request data.
struct VedaRedeemRequest {
    address assetOut;
    uint16 discountBps;
    uint24 secondsToDeadline;
    uint128 minQueuedAssets;
}
