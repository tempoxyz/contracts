// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The Zone outbox, at `0x1c00000000000000000000000000000000000002` in every Zone.
///         Bridge's Zone access key calls `requestWithdrawal` with `to` set to the program's
///         Spend-mode `ZoneRouter`.
interface IZoneOutbox {
    /// @notice Fee charged on top of `amount`, in the withdrawn token, to the caller or to a
    ///         sponsoring fee payer.
    function calculateWithdrawalFee(uint64 gasLimit) external view returns (uint128);

    function requestWithdrawal(
        address token,
        address to,
        uint128 amount,
        bytes32 memo,
        uint64 gasLimit,
        address fallbackRecipient,
        bytes calldata callbackData,
        bytes calldata revealTo
    ) external;
}
