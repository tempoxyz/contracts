// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice Optional engine capability for fee-critical valuation freshness.
/// @dev Engines with timestamped or otherwise expiring NAV should advertise this interface through
///      ERC-165. Engines without an expiring valuation need not implement it.
interface IEarnEngineFeeValuation {
    /// @notice Whether the current NAV is fresh enough to crystallize irreversible fee claims.
    function isFeeValuationFresh() external view returns (bool);
}
