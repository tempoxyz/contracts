// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISpendSettler
/// @notice A contract a ZoneRouter hands a Zone withdrawal to for its Spend op.
/// @dev The router transfers exactly `maxInput` of `token` to the settler, calls `settle`, and
///      measures what did not come back to its balance. It requires `0 < used <= maxInput` and returns
///      the rest to the source Zone, so a settler can never take more than the sender's `maxInput`.
interface ISpendSettler {
    /// @notice Pays from the `maxInput` of `token` the caller transferred to it before this call.
    /// @dev Reverts unless the payment it makes is complete. Transfers all unused input back to the
    ///      caller before returning; it must keep none of the input.
    function settle(address token, uint256 maxInput, bytes calldata data) external;
}
