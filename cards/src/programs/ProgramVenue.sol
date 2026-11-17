// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";

/// @dev The conversion venue a card program trades through.
interface IProgramConversion {
    function conversion() external view returns (address);
}

/// @dev What a contract uses of a program's conversion venue: quotes after cost, and swaps from the caller.
interface ILineVenue {
    function quoteIn(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
    function quoteOut(address tokenIn, address tokenOut, uint256 amountOut) external view returns (uint256);
    function swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 out);
    function swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, uint256 maxIn, address recipient)
        external
        returns (uint256 spent);
}

/// @title ProgramVenue
/// @notice Values, buys and sells through a card program's conversion venue, for collateral and lines held in a
///         token other than the one they are owed in: what an amount fetches, what an amount costs, and the swaps.
// Called from callers' bounded liquidation, collection and pledge loops.
// forge-lint: disable-start(calls-loop)
library ProgramVenue {
    /// @notice The program's conversion venue, zero when it has none.
    function venueOf(address program) internal view returns (ILineVenue v) {
        (bool ok, bytes memory data) = program.staticcall(abi.encodeCall(IProgramConversion.conversion, ()));
        if (ok && data.length >= 32) v = ILineVenue(abi.decode(data, (address)));
    }

    /// @notice What `amount` of `tokenIn` sells for in `tokenOut` now, after the venue's cost.
    function quoteIn(ILineVenue venue, address tokenIn, address tokenOut, uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (tokenIn == tokenOut || amount == 0) return amount;
        return venue.quoteIn(tokenIn, tokenOut, amount);
    }

    /// @notice The `tokenIn` that buys exactly `amount` of `tokenOut` now, after the venue's cost.
    function quoteOut(ILineVenue venue, address tokenIn, address tokenOut, uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (tokenIn == tokenOut || amount == 0) return amount;
        return venue.quoteOut(tokenIn, tokenOut, amount);
    }

    /// @notice Buys exactly `amount` of `tokenOut` for `recipient` with up to `budget` of `tokenIn` this contract
    ///         holds, returning what is left to `payer`.
    // forge-lint: disable-next-item(reentrancy-no-eth)
    function buy(
        ILineVenue venue,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 budget,
        address recipient,
        address payer
    ) internal {
        SafeTransferLib.safeApprove(tokenIn, address(venue), budget);
        uint256 spent = venue.swapExactOut(tokenIn, tokenOut, amount, budget, recipient);
        SafeTransferLib.safeApprove(tokenIn, address(venue), 0);
        if (budget > spent) SafeTransferLib.safeTransfer(tokenIn, payer, budget - spent);
    }

    /// @notice Sells `amount` of `tokenIn` this contract holds for `tokenOut`, paid to `recipient`, and returns what
    ///         it got.
    // forge-lint: disable-next-item(reentrancy-no-eth)
    function sell(ILineVenue venue, address tokenIn, address tokenOut, uint256 amount, address recipient)
        internal
        returns (uint256 out)
    {
        SafeTransferLib.safeApprove(tokenIn, address(venue), amount);
        out = venue.swapExactIn(tokenIn, tokenOut, amount, 0, recipient);
        SafeTransferLib.safeApprove(tokenIn, address(venue), 0);
    }

    /// @notice Redeems `shares` of `vault` this contract holds and pays `recipient` in `token`, selling through the
    ///         venue when the vault's asset differs, and returns what `recipient` received.
    // forge-lint: disable-next-item(reentrancy-no-eth)
    function redeemTo(ILineVenue venue, IEarnVault vault, uint256 shares, address token, address recipient)
        internal
        returns (uint256)
    {
        SafeTransferLib.safeApprove(vault.earnShare(), address(vault), shares);
        address asset = vault.asset();
        if (asset == token) return vault.redeem(shares, recipient, vault.previewRedeem(shares));
        uint256 redeemed = vault.redeem(shares, address(this), vault.previewRedeem(shares));
        return sell(venue, asset, token, redeemed, recipient);
    }
}
// forge-lint: disable-end(calls-loop)
