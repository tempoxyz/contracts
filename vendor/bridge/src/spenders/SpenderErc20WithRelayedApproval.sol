// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFactory } from "../lib/IFactory.sol";
import { SpenderBase } from "./SpenderBase.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "openzeppelin-contracts/token/ERC20/extensions/IERC20Permit.sol";
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @notice EIP-7597 permit interface: accepts a pre-packed bytes signature instead of v/r/s.
interface IERC7597Permit {

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes calldata signature
    ) external;

}

contract SpenderErc20WithRelayedApproval is SpenderBase {

    constructor(IFactory factory_) SpenderBase(factory_) { }

    // EP data layout: from(20) + token(20) + amount(32) + deadline(32) + sig_type(1) +
    // sig_bytes EIP-2612: sig_bytes = v(1) + r(32) + s(32) = 65  → total data length 170
    //   EIP-7597: sig_bytes = raw signature (variable)    → total data length 106+
    uint256 private constant EP_EIP2612_DATA_LENGTH = 170;
    uint256 private constant EP_MIN_DATA_LENGTH = 106; // common header + sig_type + ≥1 sig byte
    uint256 private constant BALANCE_LEN = 40; // 20 + 20

    bytes1 public constant EIP2612_BYTE = 0x01;
    bytes1 public constant EIP7597_BYTE = 0x02;

    /// @notice Thrown when the EP sig_type byte is unrecognised
    error SigTypeUnknown(bytes1 sigType);

    function transferToDestination(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        require(data.length >= EP_MIN_DATA_LENGTH, DataIncorrectLength());

        address from = _readAddress(data, 0);
        address token = _readAddress(data, 20);
        uint256 amount = _readUint256(data, 40);
        uint256 deadline = _readUint256(data, 72);
        bytes1 sigType = bytes1(data[104:105]);

        require(amount > 0, InvalidAmount());
        // Intentional: permit failure is swallowed and the transfer proceeds using whatever
        // allowance already exists. This prevents a griefing attack where a third party
        // front-runs the same permit signature, consuming it before this call lands. If the
        // permit was already applied, the allowance is still present and the transfer succeeds.
        _applyPermitIfNeeded(token, from, amount, deadline, sigType, data);
        uint256 before = IERC20(token).balanceOf(destination);
        SafeTransferLib.safeTransferFrom(token, from, destination, amount);
        require(IERC20(token).balanceOf(destination) == before + amount, DestinationNotCredited());
        emit TransferExecuted(from, destination, token, amount);
    }

    function transferToDestinationStrict(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        require(data.length >= EP_MIN_DATA_LENGTH, DataIncorrectLength());
        address from = _readAddress(data, 0);
        address token = _readAddress(data, 20);
        uint256 amount = _readUint256(data, 40);
        uint256 deadline = _readUint256(data, 72);
        bytes1 sigType = bytes1(data[104:105]);
        require(amount > 0, InvalidAmount());
        require(IERC20(token).balanceOf(from) >= amount, InsufficientBalance());
        // Intentional: strict requires the supplied permit to execute successfully. Unlike the
        // regular path this is NOT a griefing concern — callers choose strict explicitly for
        // its upfront validity guarantees. A consumed, expired, or otherwise invalid permit
        // is treated as a hard failure here rather than silently falling back to the existing
        // allowance.
        _applyPermit(token, from, amount, deadline, sigType, data);
        require(IERC20(token).allowance(from, address(this)) >= amount, InsufficientAllowance());
        uint256 before = IERC20(token).balanceOf(destination);
        SafeTransferLib.safeTransferFrom(token, from, destination, amount);
        require(IERC20(token).balanceOf(destination) == before + amount, DestinationNotCredited());
        emit TransferExecuted(from, destination, token, amount);
    }

    function availableBalance(bytes calldata data) external view returns (uint256) {
        (address from, address token) = decodeErc20Balance(data);
        return Math.min(IERC20(token).balanceOf(from), IERC20(token).allowance(from, address(this)));
    }

    // ============ Internal Functions ============
    function _applyPermit(
        address token,
        address from,
        uint256 amount,
        uint256 deadline,
        bytes1 sigType,
        bytes calldata data
    ) private {
        if (sigType == EIP2612_BYTE) {
            require(data.length == EP_EIP2612_DATA_LENGTH, DataIncorrectLength());
            uint8 v = _readUint8(data, 105);
            bytes32 r = _readBytes32(data, 106);
            bytes32 s = _readBytes32(data, 138);
            IERC20Permit(token).permit(from, address(this), amount, deadline, v, r, s);
        } else if (sigType == EIP7597_BYTE) {
            bytes calldata sig = data[105:];
            IERC7597Permit(token).permit(from, address(this), amount, deadline, sig);
        } else {
            revert SigTypeUnknown(sigType);
        }
    }

    /// @dev Like _applyPermit but wraps each permit call in try/catch so that a front-runner
    ///      who pre-submitted the same signature cannot block the transfer. If the permit call
    ///      fails the existing allowance (set by the pre-submission) is used instead.
    function _applyPermitIfNeeded(
        address token,
        address from,
        uint256 amount,
        uint256 deadline,
        bytes1 sigType,
        bytes calldata data
    ) private {
        if (sigType == EIP2612_BYTE) {
            require(data.length == EP_EIP2612_DATA_LENGTH, DataIncorrectLength());
            uint8 v = _readUint8(data, 105);
            bytes32 r = _readBytes32(data, 106);
            bytes32 s = _readBytes32(data, 138);
            try IERC20Permit(token).permit(from, address(this), amount, deadline, v, r, s) { }
                catch { }
        } else if (sigType == EIP7597_BYTE) {
            bytes calldata sig = data[105:];
            try IERC7597Permit(token).permit(from, address(this), amount, deadline, sig) { }
                catch { }
        } else {
            revert SigTypeUnknown(sigType);
        }
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

    function _readAddress(bytes calldata data, uint256 offset)
        private
        pure
        returns (address value)
    {
        assembly {
            value := shr(96, calldataload(add(data.offset, offset)))
        }
    }

    function _readUint8(bytes calldata data, uint256 offset) private pure returns (uint8 value) {
        assembly {
            value := shr(248, calldataload(add(data.offset, offset)))
        }
    }

    function _readBytes32(bytes calldata data, uint256 offset)
        private
        pure
        returns (bytes32 value)
    {
        assembly {
            value := calldataload(add(data.offset, offset))
        }
    }

    function _readUint256(bytes calldata data, uint256 offset)
        private
        pure
        returns (uint256 value)
    {
        assembly {
            value := calldataload(add(data.offset, offset))
        }
    }

}
