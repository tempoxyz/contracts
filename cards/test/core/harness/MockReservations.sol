// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IReservations } from "../../../src/core/interfaces/IReservations.sol";

/// @notice Stands in for the account reservations precompile, which the test EVM's hardfork predates. Etched at
///         its address; tests write the state a hold, capture or debt leaves and move the tokens themselves.
contract MockReservations is IReservations {
    mapping(address => mapping(bytes32 => Hold)) private _holds;
    mapping(address => mapping(bytes32 => uint128)) private _captured;
    mapping(address => mapping(address => address)) private _creditors;
    mapping(address => mapping(address => uint128)) private _debts;

    function setHold(address owner, bytes32 id, Hold calldata hold) external {
        _holds[owner][id] = hold;
    }

    function setCaptured(address owner, bytes32 id, uint128 amount) external {
        _captured[owner][id] = amount;
    }

    function setDebt(address owner, address token, address creditor, uint128 amount) external {
        _creditors[owner][token] = creditor;
        _debts[owner][token] = amount;
    }

    function getHold(address owner, bytes32 id) external view returns (Hold memory) {
        return _holds[owner][id];
    }

    function captured(address owner, bytes32 id) external view returns (uint128, uint128) {
        return (_captured[owner][id], 0);
    }

    function debtOf(address owner, address token) external view returns (address, uint128) {
        return (_creditors[owner][token], _debts[owner][token]);
    }
}
