// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISpenderHandler {

    /// @notice Transfers to the specified destination
    /// @dev
    /// This is the single external entrypoint used by the factory.
    /// The underlying transfer mechanism is delegated to `_pull`, which is
    /// implemented by the concrete subclass.
    ///
    /// @param destination Recipient of the tokens.
    /// @param data Serialized data with the transfer instructions.
    function transferToDestination(address destination, bytes calldata data) external;

    /// @notice Like transferToDestination, but validates balance and allowances first.
    /// @dev Reverts with specific errors instead of the opaque TransferFromFailed.
    ///      Costs extra gas — use for debugging or when actionable revert reasons are needed.
    function transferToDestinationStrict(address destination, bytes calldata data) external;

    /// @notice Returns the balance available to be pulled.
    ///         While this is used as a "view" function, it is not marked as "view"
    ///         to allow delegatecall to be used within implementations.
    ///
    /// @param data The serialized data
    /// @return _ The token balance of `account`.
    function availableBalance(bytes calldata data) external returns (uint256);

    /// @notice A manager function that can only be called by the factory (on behalf of a manager).
    function managerCall(bytes calldata data) external;

    /// @notice A governor function that can only be called by the factory (on behalf of a
    /// governor).
    function governorCall(bytes calldata data) external;

    /// @notice A function meant to be called by anyone.
    ///         Each spender can choose whether this has any use.
    function publicCall(bytes calldata data) external;

    /// @notice A read-only function meant to be called by anyone.
    ///         Not marked `view` to allow delegatecall in implementations.
    ///         Each spender can choose whether this has any use.
    function publicGetCall(bytes calldata data) external returns (bytes memory);

}

enum SpenderStatus {
    Disabled,
    Enabled,
    Gated
}
