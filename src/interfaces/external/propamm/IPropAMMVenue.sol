// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Narrow declarations of the published Tempo PropAMM protocol.
interface IPropAMMPriceOracle {
    function decimals() external view returns (uint8);
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
}

interface IPropAMMVenue {
    function quoteExactInputFor(
        address taker,
        address recipient,
        bytes32 customerId,
        bool baseToQuote,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 price, uint256 updatedAt, uint256 creditAfter);
    function quoteExactOutputFor(
        address taker,
        address recipient,
        bytes32 customerId,
        bool baseToQuote,
        uint256 amountOut
    ) external view returns (uint256 amountIn, uint256 price, uint256 updatedAt, uint256 creditAfter);
    function baseToken() external view returns (address);
    function quoteToken() external view returns (address);
    function oracle() external view returns (address);
    function paused() external view returns (bool);
    function takerAllowed(address taker) external view returns (bool);
    function recipientAllowed(address recipient) external view returns (bool);
    function resolveRecipient(address recipient) external view returns (address);
    function swapExactInput(
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountOut);
    function swapExactOutput(
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        bytes32 customerId,
        bytes32 tradeId,
        uint256 deadline,
        uint256 expectedOraclePrice,
        uint256 oraclePriceToleranceBps,
        uint256 minimumOracleUpdatedAt
    ) external returns (uint256 amountIn);
}
