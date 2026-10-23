// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Narrow declarations of the published Tempo PropAMM `ManagedDirectPropAMM`: one pool holding many
///         pairs, each priced like one `DirectPropAMM`, with per-pair taker lists and no recipient.
interface IManagedPropAMMVenue {
    /// @notice A pair's configuration. `access` is `None` (0) for a removed or unknown pair, `Closed` (1),
    ///         `Listed` (2), or `Open` (3).
    struct Pair {
        address base;
        address quote;
        address oracle;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint8 oracleDecimals;
        uint256 priceScale;
        uint256 maxOracleAge;
        uint256 maxPriceDeviationBps;
        uint8 access;
    }

    function pair(uint16 pairIndex) external view returns (Pair memory);
    function paused() external view returns (bool);
    function takerAllowed(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (bool);
    /// @dev Pays the output to the caller.
    function swapExactInput(
        uint16 pairIndex,
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        uint64 sponsorId,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountOut);
}
