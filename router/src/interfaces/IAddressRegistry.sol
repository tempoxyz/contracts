// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev The Tempo virtual-address registry precompile (TIP-1022).
address constant ADDRESS_REGISTRY_ADDRESS = 0xfDC0000000000000000000000000000000000000;

/// @notice The part of Tempo's virtual-address registry (TIP-1022) a settler needs: a TIP-20 transfer
///         to a virtual address credits its registered master, which `resolveRecipient` returns.
interface IAddressRegistry {
    /// @notice `to` itself unless it is a virtual address; then its registered master, or a revert
    ///         when it has none, as the transfer would.
    function resolveRecipient(address to) external view returns (address effectiveRecipient);
}
