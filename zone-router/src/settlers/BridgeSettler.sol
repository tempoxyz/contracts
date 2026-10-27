// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ISpendSettler } from "../interfaces/ISpendSettler.sol";
import { IBridgeSpenderClone, IBridgeSpenderFactory, Spend } from "./bridge/IBridgeSpender.sol";
import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

/// @title BridgeSettler
/// @notice Settles a Zone router's Spend op through one Bridge card program's spender clone, with
///         the same `Spend` public spend uses.
/// @dev Specified in docs/zone-router/zone-router.md#bridgesettler. One deployment serves one Bridge
///      card program (`SPENDER_ID`), so one program's approval can never pay through another's. It has
///      no owner and holds no Zone code: the router authenticates the withdrawal, caps the input at
///      `maxInput` and returns unused input to the Zone. The router transfers `maxInput` to the
///      settler before calling `settle`; the settler pays the spend through the "TS" handler and hands
///      the rest straight back, keeping nothing. Tokens sent to the settler outside a `settle` call
///      are not accounted for and are not rescued: any later `settle` caller can spend them, but only
///      to pay a destination this program authorizes through its clone, and gets back what that spend
///      did not use. Like the router, it neither emits nor stores the Zone's sender commitment.
contract BridgeSettler is ISpendSettler {
    bytes2 private constant HANDLER = "TS";
    bytes2 private constant PUBLIC_SPEND = "PS";
    /// @dev The revert data of a failed `transfer` and `approve`: Solady's `TransferFailed()` and
    ///      `ApproveFailed()`, whose SafeTransferLib check `_tokenCall` repeats without the dependency.
    bytes4 private constant TRANSFER_FAILED = 0x90b8ec18;
    bytes4 private constant APPROVE_FAILED = 0x3e3f8f73;

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
            input = IEarnVault(spend.vault).earnShare();
        }
        if (input == address(0) || input != token) revert WrongInputToken(token);

        // The caller sent maxInput before this call; whatever else the settler holds is the baseline,
        // and nothing beyond it may stay behind.
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance < maxInput) revert InsufficientInput();
        uint256 baseline = balance - maxInput;

        // Checked here as well as in the handler, so a replaced handler cannot look settled.
        uint256 destinationBefore = IERC20Like(spend.token).balanceOf(spend.destination);

        address clone = FACTORY.getSpenderAddress(SPENDER_ID);
        _tokenCall(token, IERC20Like.approve.selector, clone, maxInput, APPROVE_FAILED);
        // Every entry point is nonReentrant; the lock is released only after settle returns.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        IBridgeSpenderClone(clone).publicCall(abi.encodePacked(HANDLER, PUBLIC_SPEND, abi.encode(spend)));
        _tokenCall(token, IERC20Like.approve.selector, clone, 0, APPROVE_FAILED);

        uint256 unused = IERC20Like(token).balanceOf(address(this)) - baseline;
        // A spend always consumes input, so a handler that moved nothing, or handed back more
        // than it was given, must not look settled.
        if (unused >= maxInput) revert NothingSettled();
        if (IERC20Like(spend.token).balanceOf(spend.destination) != destinationBefore + spend.amount) {
            revert DestinationNotPaid();
        }
        if (unused != 0) _tokenCall(token, IERC20Like.transfer.selector, msg.sender, unused, TRANSFER_FAILED);
        if (IERC20Like(token).balanceOf(address(this)) != baseline) revert ResidualBalance(token);

        emit SpendSettled(spend.ref, token, maxInput - unused, unused);
    }

    /// @dev Calls `approve` or `transfer` (`selector`) on `token` and reverts with `failure` alone
    ///      unless the call succeeds and returns `true`, or returns nothing from an address with code.
    function _tokenCall(address token, bytes4 selector, address to, uint256 amount, bytes4 failure) private {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), to)
            mstore(add(m, 0x24), amount)
            // A call that returns nothing leaves this word as it is, so it must not read as `true`.
            mstore(0x00, 0)
            let success := call(gas(), token, 0, m, 0x44, 0x00, 0x20)
            if iszero(and(eq(mload(0x00), 1), success)) {
                if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                    mstore(0x00, failure)
                    revert(0x00, 0x04)
                }
            }
        }
    }
}
