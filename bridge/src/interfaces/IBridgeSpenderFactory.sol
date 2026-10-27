// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IBridgeSpenderFactory as ISettlerFactory } from "zone-router/settlers/bridge/IBridgeSpender.sol";

/// @notice The subset of Bridge's `SpenderFactory` that the "TS" handler and the deploy scripts read to
///         stay inside a card program's governance: pause state, allowed settlement destinations, and
///         the program's spender clone (`getSpenderAddress`, from the Zone router's `BridgeSettler`
///         interface it extends, so a `BridgeSettler` takes this factory type as it is).
interface IBridgeSpenderFactory is ISettlerFactory {
    function paused() external view returns (bool);

    function isAuthorizedDestination(bytes32 spenderId, address destination) external view returns (bool);

    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @notice Public entrypoints of a Bridge spender clone (`SpenderDelegator`), routed to a handler by
///         the payload's 2-byte prefix.
interface IBridgeSpenderClone {
    function publicCall(bytes calldata data) external;

    function publicGetCall(bytes calldata data) external returns (bytes memory);
}
