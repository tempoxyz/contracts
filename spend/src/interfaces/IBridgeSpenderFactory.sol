// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The subset of Bridge's `SpenderFactory` that Tempo Spend reads to stay inside a card
///         program's governance: pause state, allowed settlement destinations, and the program's
///         spender clone.
interface IBridgeSpenderFactory {
    function paused() external view returns (bool);

    function isAuthorizedDestination(bytes32 spenderId, address destination)
        external
        view
        returns (bool);

    function getSpenderAddress(bytes32 spenderId) external view returns (address);

    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Public entrypoints of a Bridge spender clone (`SpenderDelegator`), routed to a handler by
///         the payload's 2-byte prefix.
interface IBridgeSpenderClone {
    function publicCall(bytes calldata data) external;

    function publicGetCall(bytes calldata data) external returns (bytes memory);
}
