// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ICardAuth
/// @notice What companion contracts (sources, the issuer treasury, the issuer desk, merchant reserves) read from a card
///         authorization contract.
interface ICardAuth {
    /// @notice The program's issuer (its rotatable root).
    function ISSUER() external view returns (address);
    /// @notice Where captures and payments for the program land.
    function SETTLEMENT_ACCOUNT() external view returns (address);
    /// @notice The token the program settles in.
    function settlementToken() external view returns (address);
    /// @notice Whether `operator` holds every role bit in `roles` (the issuer holds them all).
    function hasRoles(address operator, uint8 roles) external view returns (bool);
    /// @notice Counts `value` settlement units against `operator`'s cumulative cap; reverts past it. Only the
    ///         program's companion contracts call it, for the operator that called them.
    function useOperatorCap(address operator, uint256 value) external;
    /// @notice A purchase's settlement units captured and refunded so far, and whether it is still open.
    function purchaseOf(address owner, bytes32 ref) external view returns (uint64 captured, uint64 refunded, bool open);
}
