// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFactory } from "../lib/IFactory.sol";
import { SpenderBase } from "./SpenderBase.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

contract SpenderErc20 is SpenderBase {

    uint256 private constant TRANSFER_LEN = 72; // 20 + 20 + 32
    uint256 private constant BALANCE_LEN = 40; // 20 + 20

    constructor(IFactory factory_) SpenderBase(factory_) { }

    function transferToDestination(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        (address from, address token, uint256 amount) = decodeErc20Transfer(data);
        _transferToDestination(destination, from, token, amount);
    }

    function transferToDestinationStrict(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        (address from, address token, uint256 amount) = decodeErc20Transfer(data);
        require(IERC20(token).balanceOf(from) >= amount, InsufficientBalance());
        require(IERC20(token).allowance(from, address(this)) >= amount, InsufficientAllowance());
        _transferToDestination(destination, from, token, amount);
    }

    function availableBalance(bytes calldata data) external view override returns (uint256) {
        (address from, address token) = decodeErc20Balance(data);
        return Math.min(IERC20(token).balanceOf(from), IERC20(token).allowance(from, address(this)));
    }

    // ============ Internal Functions ============

    function _transferToDestination(
        address destination,
        address from,
        address token,
        uint256 amount
    ) private {
        require(amount > 0, InvalidAmount());
        uint256 before = IERC20(token).balanceOf(destination);
        SafeTransferLib.safeTransferFrom(token, from, destination, amount);
        require(IERC20(token).balanceOf(destination) == before + amount, DestinationNotCredited());
        emit TransferExecuted(from, destination, token, amount);
    }

    function decodeErc20Transfer(bytes calldata data)
        internal
        pure
        returns (address from, address token, uint256 amount)
    {
        require(data.length == TRANSFER_LEN, DataIncorrectLength());
        from = address(bytes20(data[0:20]));
        token = address(bytes20(data[20:40]));
        amount = uint256(bytes32(data[40:72]));
    }

    function decodeErc20Balance(bytes calldata data)
        internal
        pure
        returns (address from, address token)
    {
        require(data.length == BALANCE_LEN, DataIncorrectLength());
        from = address(bytes20(data[0:20]));
        token = address(bytes20(data[20:40]));
    }

}
