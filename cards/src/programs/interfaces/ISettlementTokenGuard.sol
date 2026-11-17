// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice A contract that sizes money in a card program's settlement token (an issuer desk, a credit line), which the
///         program asks before that token changes.
interface ISettlementTokenGuard {
    /// @notice Why the program's settlement token cannot change now, as a CardProgram reason code; zero when it can.
    function settlementTokenInUse(address program) external view returns (uint8 reason);
}
