// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFactory } from "../../src/lib/IFactory.sol";
import { SpenderBase } from "../../src/spenders/SpenderBase.sol";
import { IERC4626 } from "openzeppelin-contracts/interfaces/IERC4626.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";

/// -----------------------------------------------------------------------
/// @title SpenderErc4626
/// @notice Spender that pulls payments by redeeming ERC-4626 vault shares.
/// @dev
/// The user holds vault shares and approves this contract to transfer them.
/// On spend, the spender calls `vault.withdraw(amount, destination, from)`,
/// which burns the required shares from `from` (using this contract's
/// allowance) and delivers the exact underlying asset amount to `destination`.
///
/// The token address is passed explicitly and validated against `vault.asset()`
/// so the caller cannot route a vault whose underlying differs from the
/// intended payment token.
///
/// Data encoding:
///   Transfer: from (20) + token (20) + vault (20) + amount (32) = 92 bytes
///   Balance:  from (20) + token (20) + vault (20) = 60 bytes
///
/// `amount` is denominated in the vault's underlying asset (== token).
/// -----------------------------------------------------------------------
contract SpenderErc4626 is SpenderBase {

    uint256 private constant TRANSFER_LEN = 92; // 20 + 20 + 20 + 32
    uint256 private constant BALANCE_LEN = 60; // 20 + 20 + 20

    /// @notice Thrown when the vault's underlying asset does not match the token in the payload.
    error IncorrectAssetForVault();

    /// @notice Thrown when the vault address is the zero address.
    error InvalidVault();

    constructor(IFactory factory_) SpenderBase(factory_) { }

    function transferToDestination(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        (address from, address token, address vault, uint256 amount) = _decodeTransfer(data);
        _transferToDestination(destination, from, token, vault, amount);
    }

    function transferToDestinationStrict(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        (address from, address token, address vault, uint256 amount) = _decodeTransfer(data);
        require(IERC4626(vault).asset() == token, IncorrectAssetForVault());
        uint256 sharesNeeded = IERC4626(vault).previewWithdraw(amount);
        require(IERC4626(vault).balanceOf(from) >= sharesNeeded, InsufficientBalance());
        require(
            IERC4626(vault).allowance(from, address(this)) >= sharesNeeded, InsufficientAllowance()
        );
        _transferToDestination(destination, from, token, vault, amount);
    }

    function availableBalance(bytes calldata data) external view override returns (uint256) {
        (address from, address token, address vault) = _decodeBalance(data);
        require(vault != address(0), InvalidVault());
        IERC4626 vaultContract = IERC4626(vault);
        require(vaultContract.asset() == token, IncorrectAssetForVault());
        uint256 minShares =
            Math.min(vaultContract.balanceOf(from), vaultContract.allowance(from, address(this)));
        return Math.min(vaultContract.previewRedeem(minShares), vaultContract.maxWithdraw(from));
    }

    // ============ Internal Functions ============

    function _transferToDestination(
        address destination,
        address from,
        address token,
        address vault,
        uint256 amount
    ) private {
        require(vault != address(0), InvalidVault());
        require(IERC4626(vault).asset() == token, IncorrectAssetForVault());
        require(amount > 0, InvalidAmount());
        uint256 before = IERC20(token).balanceOf(destination);
        IERC4626(vault).withdraw(amount, destination, from);
        require(IERC20(token).balanceOf(destination) == before + amount, DestinationNotCredited());
        emit TransferExecuted(from, destination, token, amount);
    }

    function _decodeTransfer(bytes calldata data)
        internal
        pure
        returns (address from, address token, address vault, uint256 amount)
    {
        require(data.length == TRANSFER_LEN, DataIncorrectLength());
        from = address(bytes20(data[0:20]));
        token = address(bytes20(data[20:40]));
        vault = address(bytes20(data[40:60]));
        amount = uint256(bytes32(data[60:92]));
    }

    function _decodeBalance(bytes calldata data)
        internal
        pure
        returns (address from, address token, address vault)
    {
        require(data.length == BALANCE_LEN, DataIncorrectLength());
        from = address(bytes20(data[0:20]));
        token = address(bytes20(data[20:40]));
        vault = address(bytes20(data[40:60]));
    }

}
