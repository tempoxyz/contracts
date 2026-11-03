// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ISpender
/// @notice A contract a ZoneRouter hands a Zone withdrawal to for its Spend op.
/// @dev The router transfers exactly `maxInput` of `token` to the spender, calls `spendFrom`, and
///      measures what did not come back to its balance. It requires `0 < used <= maxInput` and returns
///      the rest to the source Zone, so a spender can never take more than the sender's `maxInput`.
///      A spender authenticates its caller as a router its release's factory deployed that lists it
///      (SpenderAuth), so `maxInput` is a router's measured transfer, not a claim on its balances. Its events,
///      like the router's `Spent`, prove a Zone spend only together with the source Portal's
///      `WithdrawalProcessed` in the same transaction. It must have no proxy or upgrade path: a Zone admin
///      checks its codehash against the released build before admitting a router that lists it.
interface ISpender {
    /// @notice Pays from the `maxInput` of `token` the caller transferred to it before this call.
    /// @dev Reverts unless the caller is a listed factory router and the payment it makes is complete.
    ///      Transfers all unused input back to the caller before returning; it must keep none of the input.
    function spendFrom(address token, uint256 maxInput, bytes calldata data) external;
}
