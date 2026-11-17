// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @notice A fixed-price pool in the DirectPropAMM shape: base priced in quote at `price` (quote units per base unit,
///         scaled by 1e18), paying out of its own inventory. Exact-output quotes round the input up.
contract FixedPricePool {
    using FixedPointMathLib for uint256;

    address public immutable BASE;
    address public immutable QUOTE;
    uint256 public price;

    constructor(address base, address quote, uint256 price_) {
        BASE = base;
        QUOTE = quote;
        price = price_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function quoteExactInput(bool baseToQuote, uint256 amountIn) public view returns (uint256, uint256, uint256) {
        uint256 out = baseToQuote ? amountIn.mulDiv(price, 1e18) : amountIn.mulDiv(1e18, price);
        return (out, price, block.timestamp);
    }

    function quoteExactOutput(bool baseToQuote, uint256 amountOut) public view returns (uint256, uint256, uint256) {
        uint256 amountIn = baseToQuote ? amountOut.mulDivUp(1e18, price) : amountOut.mulDivUp(price, 1e18);
        return (amountIn, price, block.timestamp);
    }

    function swapExactInput(
        bool baseToQuote,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes32,
        bytes32,
        uint256,
        uint256,
        uint256,
        uint256
    ) external returns (uint256 amountOut) {
        (amountOut,,) = quoteExactInput(baseToQuote, amountIn);
        require(amountOut >= minAmountOut, "slippage");
        _trade(baseToQuote, amountIn, amountOut, recipient);
    }

    function swapExactOutput(
        bool baseToQuote,
        uint256 amountOut,
        uint256 maxAmountIn,
        address recipient,
        bytes32,
        bytes32,
        uint256,
        uint256,
        uint256,
        uint256
    ) external returns (uint256 amountIn) {
        (amountIn,,) = quoteExactOutput(baseToQuote, amountOut);
        require(amountIn <= maxAmountIn, "slippage");
        _trade(baseToQuote, amountIn, amountOut, recipient);
    }

    function _trade(bool baseToQuote, uint256 amountIn, uint256 amountOut, address recipient) private {
        (address tokenIn, address tokenOut) = baseToQuote ? (BASE, QUOTE) : (QUOTE, BASE);
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(tokenOut, recipient, amountOut);
    }
}
