// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev Tempo's card records precompile (ASCII "CARD", TIP-1169).
address constant CARDS_ADDRESS = 0x4341524400000000000000000000000000000000;

/// @notice The subset of the card records precompile a savings facility reads: what an account's sweeps paid
///         into a facility for redemption, and who receives the cash.
interface ICards {
    /// @notice Shares of `token` that sweeps of `owner`'s account paid into `via` so far, and their recipient.
    function payoutOf(address owner, address token, address via) external view returns (address to, uint128 amount);
}
