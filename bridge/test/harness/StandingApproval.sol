// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev True for no approval or a standing maximum one (which a token may have drawn down): the router's
///      approval to its Portal, the settler's to its clone and the clone's to an allowed vault are left
///      standing so spends do not create their allowance slots again (TIP-1000).
function isStandingOrNone(uint256 allowance) pure returns (bool) {
    return allowance == 0 || allowance > type(uint128).max;
}
