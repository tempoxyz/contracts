// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The Zone Portal's deposit fees, which a router checks before returning change to the Zone.
interface IZonePortalFees {
    /// @notice The fee the Portal deducts from each deposit.
    function calculateDepositFee() external view returns (uint128 fee);

    /// @notice The bounce-back reserve a deposit must also cover: one below the deposit fee plus this reverts.
    function calculateBouncebackFee() external view returns (uint128 fee);
}
