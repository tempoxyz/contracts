// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The subset of Rain's `RainCollateralFactory` (vendor/rain) that `RainCardProgram` reads.
interface IRainCollateralFactory {
    function getBeacon() external view returns (address);
}

/// @notice The subset of Rain's `RainCollateral` (vendor/rain) that `RainCardProgram` reads.
interface IRainCollateral {
    function factory() external view returns (address);

    function owner() external view returns (address);
}
