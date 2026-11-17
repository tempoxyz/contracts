// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @dev Tempo's account reservations precompile (ASCII "RESV"), from T15 (TIP-1153).
address constant RESERVATIONS_ADDRESS = 0x5245535600000000000000000000000000000000;

/// @notice The subset of the account reservations precompile a card settlement reads: native holds on TIP-20
///         balances, their captured totals, and capped debt. Hold ids are scoped per owner.
interface IReservations {
    /// @notice A hold on `amount` of the owner's `token` balance in favor of `payee`. A captured hold keeps its
    ///         token and payee with `amount` zero.
    struct Hold {
        address token;
        address payee;
        uint128 amount;
        uint64 expiresAt;
    }

    function getHold(address owner, bytes32 id) external view returns (Hold memory);

    /// @notice What the hold's capture paid its payee, and how much of that the payee refunded.
    function captured(address owner, bytes32 id) external view returns (uint128 captured, uint128 refunded);

    /// @notice The owner's unpaid debt in `token` and who it is owed to (zero when none).
    function debtOf(address owner, address token) external view returns (address creditor, uint128 amount);
}
