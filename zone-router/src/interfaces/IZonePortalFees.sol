// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The Zone Portal's deposit fee, which a router caps before returning change to the Zone.
interface IZonePortalFees {
    function calculateDepositFee() external view returns (uint128 fee);
}
