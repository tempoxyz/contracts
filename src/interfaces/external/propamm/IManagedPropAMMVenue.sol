// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Narrow declarations of the published Tempo PropAMM managed pool (`ManagedDirectPropAMM`): one pool
///         holding many pairs, each priced like one single-pair pool. Every swap and quote names a pair, a swap
///         names the access list its taker trades under, and a swap pays its taker.
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

    /// @notice One swap on a pair. For an exact input, `amount` is the input and `limit` the minimum output; for
    ///         an exact output, `amount` is the output and `limit` the maximum input. `sponsorId` names the
    ///         access list the taker trades under (0: the pair's home list).
    struct SwapParams {
        uint16 pairIndex;
        bool baseToQuote;
        bool exactInput;
        uint256 amount;
        uint256 limit;
        uint64 sponsorId;
        bytes32 customerId;
        bytes32 tradeId;
        uint256 deadline;
        uint256 expectedOraclePrice;
        uint256 oraclePriceToleranceBps;
        uint256 minimumOracleUpdatedAt;
    }

    /// @notice The factory that created the pool; zero for a standalone pool, which no Settler settles.
    function factory() external view returns (address);

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
}

/// @notice Narrow declaration of the managed pools' factory (`PoolFactory`).
interface IManagedPropAMMPoolFactory {
    /// @notice The Settler every pool this factory creates starts on.
    function defaultSettler() external view returns (address);
}

/// @notice Narrow declaration of the managed pools' `Settler`, the entry point for a swap on a pool its factory
///         created. Its caller is the swap's taker for access, fees, rounding credit and payout: it approves
///         the Settler, which moves the input from the caller straight into the pool and never holds a balance.
interface IManagedPropAMMSettler {
    /// @notice Swaps on `pool` as the caller, which funds the input and receives the output.
    /// @return result The output of an exact-input swap, or the input of an exact-output swap.
    function swap(address pool, IManagedPropAMMVenue.SwapParams calldata params) external returns (uint256 result);
}
