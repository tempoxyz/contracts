// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { SpenderStatus } from "./ISpenderHandler.sol";

interface SpenderFactoryErrorsAndEvents {

    // ============ Errors ============

    /// @notice Thrown when destination is the zero address
    error InvalidDestination();
    /// @notice Thrown when the spender ID does not have a known address
    error UnknownSpender();
    /// @notice Thrown when spender address is the zero address
    error InvalidSpenderAddress();
    /// @notice Thrown when destination is not allowed
    error NotAuthorizedDestination();
    /// @notice Thrown when manager address is zero
    error InvalidManager();
    /// @notice Thrown when governor address is zero
    error InvalidGovernor();
    /// @notice Thrown when spender is already registered
    error SpenderAlreadyRegistered();
    /// @notice Thrown when more than 10 destinations are provided
    error TooManyDestinations();
    /// @notice Thrown when the spenderHandler is disabled
    error SpenderHandlerDisabled();
    /// @notice Thrown when spenderHandler is not allowed for this contract
    error SpenderHandlerNotAllowed();

    // ============ Events ============

    /// @notice Emitted when a new spender is created
    /// @param spenderId Unique identifier for the spender
    /// @param spender Address of the deployed spender contract
    event SpenderCreated(bytes32 indexed spenderId, address indexed spender);

    /// @notice Emitted when a spender's destination is updated
    /// @param spenderId Unique identifier for the spender
    /// @param destination Updated destination address
    /// @param allowed Whether the destination is allowed
    event DestinationUpdated(bytes32 indexed spenderId, address indexed destination, bool allowed);

    /// @notice Emitted when a global value is updated
    event GlobalValueUpdated(bytes32 indexed key, bytes previousValue, bytes newValue);

    /// @notice Emitted when a spender handler implementation is updated
    event SpenderHandlerUpdated(bytes2 indexed key, address oldValue, address newValue);

    /// @notice Emitted when a spender handler status is updated
    event SpenderHandlerStatusUpdated(
        bytes2 indexed key, SpenderStatus oldStatus, SpenderStatus newStatus
    );

    /// @notice Emitted when a contract is added or removed from a spender handler's allowlist
    event SpenderHandlerAllowlistModified(bytes2 indexed key, bytes32 spenderId, bool allowed);

}
