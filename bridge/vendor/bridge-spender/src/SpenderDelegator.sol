// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISpenderHandler } from "./ISpenderHandler.sol";
import { IFactory } from "./lib/IFactory.sol";
import { SpenderBase } from "./spenders/SpenderBase.sol";
import { ERC1967Utils } from "openzeppelin-contracts/proxy/ERC1967/ERC1967Utils.sol";

contract SpenderDelegator is SpenderBase {

    constructor(IFactory factory_) SpenderBase(factory_) { }

    /// @notice Updates this proxy's ERC-1967 beacon slot to point to a new beacon.
    /// @dev Called via delegatecall during migration of legacy beacon proxies, so writes
    ///      take effect on the proxy's own storage. Only the authorized factory may call this.
    ///      ERC1967Utils validates that newBeacon has code and its implementation() is non-empty.
    function migrateBeacon(address newBeacon) external onlyFactory {
        ERC1967Utils.upgradeBeaconToAndCall(newBeacon, "");
    }

    /// -------------------------------------------------------------------
    /// External API
    /// -------------------------------------------------------------------

    function transferToDestination(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        _delegate(
            data, abi.encodeCall(ISpenderHandler.transferToDestination, (destination, data[2:]))
        );
    }

    function transferToDestinationStrict(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        _delegate(
            data,
            abi.encodeCall(ISpenderHandler.transferToDestinationStrict, (destination, data[2:]))
        );
    }

    function availableBalance(bytes calldata data) external override returns (uint256) {
        return abi.decode(
            _delegate(data, abi.encodeCall(ISpenderHandler.availableBalance, (data[2:]))), (uint256)
        );
    }

    function managerCall(bytes calldata data) external override onlyFactory {
        _delegate(data, abi.encodeCall(ISpenderHandler.managerCall, (data[2:])));
    }

    function governorCall(bytes calldata data) external override onlyFactory {
        _delegate(data, abi.encodeCall(ISpenderHandler.governorCall, (data[2:])));
    }

    function publicCall(bytes calldata data) external override {
        require(!FACTORY.paused(), FactoryPaused());
        _delegate(data, abi.encodeCall(ISpenderHandler.publicCall, (data[2:])));
    }

    function publicGetCall(bytes calldata data) external override returns (bytes memory) {
        bytes memory raw =
            _delegate(data, abi.encodeCall(ISpenderHandler.publicGetCall, (data[2:])));
        return abi.decode(raw, (bytes));
    }

    function _delegate(bytes calldata data, bytes memory callData)
        private
        returns (bytes memory result)
    {
        bool success;
        (success, result) = _implementation(data).delegatecall(callData);

        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function _implementation(bytes calldata data) private view returns (address) {
        return address(_getSpenderHandler(_prefix(data)));
    }

}
