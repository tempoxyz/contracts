// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFactory } from "../lib/IFactory.sol";
import { SpenderBase } from "./SpenderBase.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";
import { IAllowanceTransfer } from "permit2/interfaces/IAllowanceTransfer.sol";

contract SpenderPermit2 is SpenderBase {

    uint256 private constant TRANSFER_LEN = 72; // 20 + 20 + 32
    uint256 private constant BALANCE_LEN = 40; // 20 + 20

    error Permit2AddressZero();
    error AmountTooLargeForPermit2();
    error InsufficientErc20AllowanceToPermit2();
    error InsufficientPermit2Allowance();
    error ExpiredPermit2Allowance();
    error NotAContract();

    address public immutable PERMIT2;

    constructor(IFactory factory_, address permit2_) SpenderBase(factory_) {
        require(permit2_ != address(0), Permit2AddressZero());
        PERMIT2 = permit2_;
    }

    function transferToDestination(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        (address from, address token, uint256 amount) = decodePermit2Transfer(data);
        _transferToDestination(destination, from, token, amount);
    }

    function transferToDestinationStrict(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        (address from, address token, uint256 amount) = decodePermit2Transfer(data);
        require(IERC20(token).balanceOf(from) >= amount, InsufficientBalance());
        require(
            IERC20(token).allowance(from, PERMIT2) >= amount, InsufficientErc20AllowanceToPermit2()
        );
        (uint160 permit2Amount, uint48 expiration,) =
            IAllowanceTransfer(PERMIT2).allowance(from, token, address(this));
        require(expiration >= block.timestamp, ExpiredPermit2Allowance());
        require(uint256(permit2Amount) >= amount, InsufficientPermit2Allowance());
        _transferToDestination(destination, from, token, amount);
    }

    function availableBalance(bytes calldata data) external view override returns (uint256) {
        (address from, address token) = decodePermit2Balance(data);
        (uint160 permit2Amount, uint48 expiration,) =
            IAllowanceTransfer(PERMIT2).allowance(from, token, address(this));
        uint256 approvedByPermit2 = Math.min(
            IERC20(token).balanceOf(from),
            expiration >= block.timestamp ? uint256(permit2Amount) : 0
        );
        uint256 approvedToPermit2 =
            Math.min(IERC20(token).balanceOf(from), IERC20(token).allowance(from, PERMIT2));
        return Math.min(approvedByPermit2, approvedToPermit2);
    }

    // ============ Internal Functions ============

    function _transferToDestination(
        address destination,
        address from,
        address token,
        uint256 amount
    ) private {
        require(amount > 0, InvalidAmount());
        require(amount <= type(uint160).max, AmountTooLargeForPermit2());
        // Permit2 uses Solmate SafeTransferLib internally, which does not check extcodesize and
        // treats a no-revert empty-returndata CALL as success. Reject no-code tokens explicitly
        // so a zero-code address cannot produce a TransferExecuted event without moving tokens.
        require(token.code.length > 0, NotAContract());
        uint256 before = IERC20(token).balanceOf(destination);
        // forge-lint: disable-next-line(unsafe-typecast)
        IAllowanceTransfer(PERMIT2).transferFrom(from, destination, uint160(amount), token);
        require(IERC20(token).balanceOf(destination) == before + amount, DestinationNotCredited());
        emit TransferExecuted(from, destination, token, amount);
    }

    function decodePermit2Transfer(bytes calldata data)
        internal
        pure
        returns (address from, address token, uint256 amount)
    {
        require(data.length == TRANSFER_LEN, DataIncorrectLength());
        from = address(bytes20(data[0:20]));
        token = address(bytes20(data[20:40]));
        amount = uint256(bytes32(data[40:72]));
    }

    function decodePermit2Balance(bytes calldata data)
        internal
        pure
        returns (address from, address token)
    {
        require(data.length == BALANCE_LEN, DataIncorrectLength());
        from = address(bytes20(data[0:20]));
        token = address(bytes20(data[20:40]));
    }

}
