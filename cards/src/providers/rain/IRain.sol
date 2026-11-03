// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The subset of Rain's `RainCollateralFactory` (vendor/rain) that `RainIssuer` reads.
interface IRainCollateralFactory {
    /// @notice The collateral contract the factory created `index`-th (0-based).
    function collateralProxies(uint256 index) external view returns (address);
}

/// @notice The subset of Rain's `RainCollateral` (vendor/rain) that `RainIssuer` reads.
interface IRainCollateral {
    function factory() external view returns (address);

    function owner() external view returns (address);

    function isAdmin(address account) external view returns (bool);
}
