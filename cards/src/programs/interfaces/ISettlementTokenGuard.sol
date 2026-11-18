// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice A contract that sizes money in a card program's settlement token (credit lines, the issuer desk, merchant
///         reserves), which the issuer's treasury asks before that token changes.
interface ISettlementTokenGuard {
    /// @notice Why the program's settlement token cannot change now, as a reason code (4 open disputes, 5 sponsor
    ///         collateral, 6 a held settlement balance, 7 credit lines, 8 issuer debt, 9 merchant reserves); zero
    ///         when it can.
    function settlementTokenInUse(address program) external view returns (uint8 reason);
}
