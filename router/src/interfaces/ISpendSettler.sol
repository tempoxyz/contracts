// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISpendSettler
/// @notice A contract a ZoneRouter hands a Zone withdrawal to for its Spend op.
/// @dev The router approves at most `maxInput` of `token` to the settler, calls `settle`, resets the
///      approval, and measures what left its balance. It requires `0 < used <= maxInput` and returns
///      the rest to the source Zone, so a settler can never take more than the sender's `maxInput`.
interface ISpendSettler {
    /// @notice Pays from the router's approved `token`, using at most `maxInput`.
    /// @dev Reverts unless the payment it makes is complete. Pulls what it uses from the caller and
    ///      leaves the rest with the caller; it must keep none of the input.
    function settle(address token, uint256 maxInput, bytes calldata data) external;
}
