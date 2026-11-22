// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @notice The two views a spender reads to authenticate its caller as a Zone router.
interface IZoneRouterFactoryRegistry {
    /// @notice Whether this factory deployed `router`.
    function isRouter(address router) external view returns (bool);
}

/// @notice A Zone router's fixed spender list.
interface IZoneRouterSpenders {
    /// @notice Whether `spender` is in the router's mode.
    function isSpender(address spender) external view returns (bool);
}

/// @title SpenderAuth
/// @notice Lets a spender accept `spendFrom` only from a router its release factory deployed and whose mode
///         lists it, so the caller's `maxInput` is a router's measured transfer rather than a claim.
library SpenderAuth {
    /// @notice Whether `caller` is a router `factory` deployed that lists `spender`.
    /// @dev The factory read comes first, so `isSpender` is only ever called on factory-deployed code.
    function isListedRouter(address factory, address caller, address spender) internal view returns (bool) {
        return IZoneRouterFactoryRegistry(factory).isRouter(caller) && IZoneRouterSpenders(caller).isSpender(spender);
    }
}
