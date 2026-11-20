// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Narrow declarations of the published Tempo PropAMM managed pool (`ManagedDirectPropAMM`): one pool
///         holding many pairs, each priced like one single-pair pool. Every swap and quote names a pair, a swap
///         names the access list its caller trades under, and a swap pays its caller.
interface IManagedPropAMMVenue {
    /// @notice A pair's access mode. `None` is read only for an unknown or removed pair; a live pair is `Closed`
    ///         (nobody trades), `Listed` (the accounts on a list the pair admits) or `Open` (everyone not denied).
    enum AccessMode {
        None,
        Closed,
        Listed,
        Open
    }

    /// @notice A pair's configuration. An unknown or removed pair reads all zero, and its index is never reused.
    /// @dev `priceScale` is `10 ** (baseDecimals + oracleDecimals - quoteDecimals)`.
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
        AccessMode access;
    }

    /// @notice The pair's configuration; all zero for an unknown or removed pair.
    function pair(uint16 pairIndex) external view returns (Pair memory);

    /// @notice The live pair's optional fee hook and its enabled stages. Reverts `UnknownPair` otherwise.
    function pairHook(uint16 pairIndex) external view returns (address hook, uint8 flags);

    /// @notice The pool-wide pause.
    function paused() external view returns (bool);

    /// @notice Whether the pair's access check admits `taker` now for a swap under `sponsorId` (0: the pair's home
    ///         list). Covers only list access, not the pause, the oracle, inventory or token policy.
    function takerAllowed(uint16 pairIndex, address taker, uint64 sponsorId) external view returns (bool);

    /// @notice Quotes the exact execution of `taker`'s exact-input swap for `customerId` on the pair, including
    ///         the route's accrued rounding credit and any hook fee. Checks no access, pause or inventory.
    function quoteExactInputFor(uint16 pairIndex, address taker, bytes32 customerId, bool baseToQuote, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 price, uint256 updatedAt, uint256 creditAfter);

    /// @notice Quotes the exact execution of `taker`'s exact-output swap for `customerId` on the pair, including
    ///         the route's accrued rounding credit and any hook fee. Checks no access, pause or inventory.
    function quoteExactOutputFor(
        uint16 pairIndex,
        address taker,
        bytes32 customerId,
        bool baseToQuote,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 price, uint256 updatedAt, uint256 creditAfter);

    /// @notice Swaps an exact input on the pair, pulling it from the caller and paying the output to the caller.
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

    /// @notice Swaps for an exact output on the pair, pulling the input from the caller and paying the output to
    ///         the caller.
    function swapExactOutput(
        uint16 pairIndex,
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        uint64 sponsorId,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountIn);
}
