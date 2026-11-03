// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The subset of Bridge's `SpenderFactory` that the "TS" handler, `BridgeProvider` and the deploy
///         scripts read to stay inside a card program's governance: pause state, handler routing, allowed
///         settlement destinations, and the program's spender clone.
interface IBridgeSpenderFactory {
    function getSpenderAddress(bytes32 spenderId) external view returns (address);

    function paused() external view returns (bool);

    function isAuthorizedDestination(bytes32 spenderId, address destination) external view returns (bool);

    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @notice The handler registered for `key`; reverts when it is disabled, or allowlisted without `user`.
    function getSpenderHandlerWithCheckedPermissions(bytes2 key, address user) external view returns (address);
}

/// @notice Public entrypoints of a Bridge spender clone (`SpenderDelegator`), routed to a handler by
///         the payload's 2-byte prefix.
interface IBridgeSpenderClone {
    function publicCall(bytes calldata data) external;

    function publicGetCall(bytes calldata data) external returns (bytes memory);
}
