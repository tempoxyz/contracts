// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISpenderHandler, SpenderStatus } from "../ISpenderHandler.sol";

struct SpenderFactoryStorage {
    // allowed payment destinations per spender
    mapping(bytes32 spenderId => mapping(address destination => bool allowed))
        allowedSpenderDestinations;

    // maps spenderId to the spender proxy address
    mapping(bytes32 spenderId => address spenderAddress) spenderAddresses;

    // SpenderDelegator address used as the implementation for all spender clones
    address delegator;

    // maps a 2 byte identifier to spender handler configs
    mapping(bytes2 prefix => HandlerConfig config) handlerConfigs;
}

struct HandlerConfig {
    ISpenderHandler handler;
    // Specifies if/who can use the handler
    SpenderStatus status;
    // allowlist defines which contracts are allowed to use this handler.
    // Only applies if the handler status is Gated
    mapping(address delegateContract => bool allowed) allowlist;
}

library SpenderFactoryStorageLib {

    ///@custom:storage-location eip7201:SpenderFactory.storage
    bytes32 constant SPENDER_FACTORY_STORAGE_SLOT =
        0x3a1d31ddece20a215512718af6a22057b4c95c9239813210433662484f555000;

    function getStorage() internal pure returns (SpenderFactoryStorage storage $) {
        assembly {
            $.slot := SPENDER_FACTORY_STORAGE_SLOT
        }
    }

}
