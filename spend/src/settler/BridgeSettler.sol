// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ISpendSettler } from "tempo-router/interfaces/ISpendSettler.sol";

import { Spend } from "../SpenderTempoSpend.sol";
import { IBridgeSpenderClone, IBridgeSpenderFactory } from "../interfaces/IBridgeSpenderFactory.sol";
import { ITempoEarnVault } from "../interfaces/ITempoEarnVault.sol";

/// @title BridgeSettler
/// @notice Settles a Zone router's Spend op through one Bridge card program's spender clone, with
///         the same `Spend` public spend uses.
/// @dev One deployment serves one Bridge card program (`SPENDER_ID`), so one program's approval can
///      never pay through another's. It has no owner and holds no Zone code: the router
///      authenticates the withdrawal, caps the input at `maxInput` and returns unused input to the
///      Zone. The router transfers `maxInput` to the settler before calling `settle`; the settler
///      pays the spend through the "TS" handler and hands the rest straight back, keeping nothing.
///      Tokens sent to the settler outside a `settle` call are not accounted for and are not
///      rescued: any later `settle` caller can spend them, but only to pay a destination this
///      program authorizes through its clone, and gets back what that spend did not use. Like the
///      router, it neither emits nor stores the Zone's sender commitment.
contract BridgeSettler is ISpendSettler {
    bytes2 private constant HANDLER = "TS";

    IBridgeSpenderFactory public immutable FACTORY;
    bytes32 public immutable SPENDER_ID;

    uint256 private _locked = 1;

    error DestinationNotPaid();
    error InsufficientInput();
    error InvalidAmount();
    error NothingSettled();
    error Reentrancy();
    error ResidualBalance(address token);
    error WrongInputToken(address token);
    error WrongProgram(bytes32 spenderId);
    error ZeroAddress();

    /// @dev Carries no cardholder address and no Zone sender commitment; the router emits the Zone side.
    event SpendSettled(bytes32 indexed ref, address inputToken, uint256 inputConsumed, uint256 inputReturned);

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(IBridgeSpenderFactory factory_, bytes32 spenderId_) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        SPENDER_ID = spenderId_;
    }

    /// @inheritdoc ISpendSettler
    /// @dev `data` is `abi.encode(Spend)`. Expects the caller to have transferred `maxInput` to it
    ///      first, and returns what the spend did not use in the same call, so the caller never loses
    ///      more than `maxInput`.
    function settle(address token, uint256 maxInput, bytes calldata data) external override nonReentrant {
        Spend memory spend = abi.decode(data, (Spend));
        if (spend.spenderId != SPENDER_ID) revert WrongProgram(spend.spenderId);
        if (maxInput == 0 || maxInput > type(uint128).max) revert InvalidAmount();
        // One withdrawal carries one token: a stablecoin spend's token, or the shares of the vault that
        // funds all of it. A spend split between both cannot come from one Zone withdrawal.
        address input;
        if (spend.fromVault == 0) {
            input = spend.token;
        } else if (spend.fromVault == spend.amount && spend.vault != address(0)) {
            input = ITempoEarnVault(spend.vault).earnShare();
        }
        if (input == address(0) || input != token) revert WrongInputToken(token);

        // The caller sent maxInput before this call; whatever else the settler holds is the baseline,
        // and nothing beyond it may stay behind.
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < maxInput) revert InsufficientInput();
        uint256 baseline = balance - maxInput;

        // Checked here as well as in the handler, so a replaced handler cannot look settled.
        uint256 destinationBefore = IERC20(spend.token).balanceOf(spend.destination);

        address clone = _clone();
        SafeTransferLib.safeApprove(token, clone, maxInput);
        IBridgeSpenderClone(clone).publicCall(abi.encodePacked(HANDLER, bytes2("PS"), abi.encode(spend)));
        SafeTransferLib.safeApprove(token, clone, 0);

        uint256 unused = IERC20(token).balanceOf(address(this)) - baseline;
        // A spend always consumes input, so a handler that moved nothing, or handed back more
        // than it was given, must not look settled.
        if (unused >= maxInput) revert NothingSettled();
        if (IERC20(spend.token).balanceOf(spend.destination) != destinationBefore + spend.amount) {
            revert DestinationNotPaid();
        }
        if (unused != 0) SafeTransferLib.safeTransfer(token, msg.sender, unused);
        if (IERC20(token).balanceOf(address(this)) != baseline) revert ResidualBalance(token);

        emit SpendSettled(spend.ref, token, maxInput - unused, unused);
    }

    function _clone() private view returns (address) {
        return FACTORY.getSpenderAddress(SPENDER_ID);
    }
}
