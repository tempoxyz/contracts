// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISpenderHandler } from "../ISpenderHandler.sol";
import { IFactory } from "../lib/IFactory.sol";

/// -----------------------------------------------------------------------
/// @title SpenderBase
/// @notice Abstract base contract for pull payment flows.
/// @dev
/// This contract centralizes:
///  - factory-only access control
///  - the public transfer entrypoint shared across implementations
///
/// Concrete subclasses implement `_pull`, which defines *how* funds are
/// transferred:
///  - Classic ERC20 allowance (`transferFrom`)
///  - Permit2 allowance (`transferFrom`)
///  - Any future mechanism (vaults, escrow, hooks, etc.)
/// -----------------------------------------------------------------------
abstract contract SpenderBase is ISpenderHandler {

    /// -------------------------------------------------------------------
    /// Errors
    /// -------------------------------------------------------------------
    /// @notice Thrown when a non-factory caller invokes a restricted method.
    error NotFactory();

    /// @notice Thrown when the factory is a 0 address.
    error FactoryAddressZero();
    /// @notice Thrown when a call is attempted while the factory is paused.
    error FactoryPaused();

    /// @notice Thrown when the passed data is too short.
    error DataIncorrectLength();

    /// @notice Thrown when the passed prefix is unknown
    error PrefixUnknown(bytes2 prefix);

    /// @notice Thrown by strict transfer when `from` has insufficient token balance.
    error InsufficientBalance();
    /// @notice Thrown by strict transfer when `from` has insufficient allowance to this
    /// contract.
    error InsufficientAllowance();
    /// @notice Thrown when the transfer amount is zero.
    error InvalidAmount();
    /// @notice Thrown when destination balance did not increase by the expected amount after
    /// transfer. Guards against tokens (e.g. TIP-20 with a blocking receive policy) that return
    /// true from transferFrom but route funds to a policy guard instead of the destination.
    error DestinationNotCredited();

    /// -------------------------------------------------------------------
    /// Events
    /// -------------------------------------------------------------------
    ///@notice Emitted when a transfer is executed
    ///@param from Address of the sender
    ///@param destination Address of the destination
    ///@param token Address of the token
    ///@param totalAmount Total amount of the transfer
    event TransferExecuted(address from, address destination, address token, uint256 totalAmount);

    /// -------------------------------------------------------------------
    /// Immutables
    /// -------------------------------------------------------------------

    /// @notice Factory contract authorized to trigger transfers.
    /// @dev Set once at construction time and cannot be changed.
    IFactory public immutable FACTORY;

    /// -------------------------------------------------------------------
    /// Constructor
    /// -------------------------------------------------------------------

    /// @param factory_ Address of the factory that deploys or owns this spender.
    constructor(IFactory factory_) {
        require(address(factory_) != address(0), FactoryAddressZero());

        FACTORY = factory_;
    }

    function managerCall(bytes calldata) external virtual override onlyFactory {
        revert("This contract does not support manager calls");
    }

    function governorCall(bytes calldata) external virtual override onlyFactory {
        revert("This contract does not support governor calls");
    }

    /// a default implementation of publicCall that reverts
    function publicCall(bytes calldata) external virtual override {
        revert("This contract does not support public calls");
    }

    /// a default implementation of publicGetCall that reverts
    function publicGetCall(bytes calldata) external virtual override returns (bytes memory) {
        revert("This contract does not support public get calls");
    }

    /// -------------------------------------------------------------------
    /// Modifiers
    /// -------------------------------------------------------------------

    /// @notice Restricts function access to the factory.
    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    function _onlyFactory() internal view {
        if (msg.sender != address(FACTORY)) {
            revert NotFactory();
        }
    }

    /// -------------------------------------------------------------------
    /// Internal Utilities - To be used by inheritors
    /// -------------------------------------------------------------------

    /// @notice Gets the spender function handler
    ///         Raises if none is found
    function _getSpenderHandler(bytes2 prefix) internal view returns (ISpenderHandler) {
        ISpenderHandler handler =
            FACTORY.getSpenderHandlerWithCheckedPermissions(prefix, address(this));

        require(address(handler) != address(0), PrefixUnknown(prefix));

        return handler;
    }

    /// @notice Returns the 2-byte prefix without decoding the rest.
    ///         Use this to dispatch before calling a typed decode function.
    function _prefix(bytes calldata data) internal pure returns (bytes2) {
        require(data.length >= 2, DataIncorrectLength());
        return bytes2(data[0:2]);
    }

}
