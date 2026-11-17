// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ICards } from "../../../src/core/interfaces/ICards.sol";

/// @notice Stands in for the card records precompile, which the test EVM's hardfork predates. Etched at its
///         address; tests write the payout record a sweep leaves and move the shares themselves.
contract MockCards is ICards {
    mapping(address => mapping(address => mapping(address => address))) private _to;
    mapping(address => mapping(address => mapping(address => uint128))) private _amount;

    function setPayout(address owner, address token, address via, address to, uint128 amount) external {
        _to[owner][token][via] = to;
        _amount[owner][token][via] = amount;
    }

    function payoutOf(address owner, address token, address via) external view returns (address, uint128) {
        return (_to[owner][token][via], _amount[owner][token][via]);
    }
}
