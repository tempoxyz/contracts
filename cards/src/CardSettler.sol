// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { IEarnVault } from "tempo-earn/interfaces/core/IEarnVault.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";
import { IERC20Allowance } from "zone-router/interfaces/IERC20Allowance.sol";
import { ISpendSettler } from "zone-router/interfaces/ISpendSettler.sol";

import { CardSpend } from "./CardSpend.sol";
import { CardSpender } from "./CardSpender.sol";

/// @title CardSettler
/// @notice Settles a Zone router's Spend op through one program's `CardSpender`, with the same
///         `CardSpend` a public spend uses, for any card provider. Specified in docs/cards/design.md.
/// @dev The provider-agnostic counterpart of `BridgeSettler`: the same checks, with the program's
///      `CardSpender` in place of a Bridge spender clone. One deployment serves one spender, so one program's
///      approval can never pay through another's. It has no owner and holds no Zone code: the router
///      authenticates the withdrawal, caps the input at `maxInput` and returns unused input to the Zone.
///      Tokens sent to the settler outside a `settle` call are not accounted for and are not rescued: a
///      later `settle` caller can spend them, but only to a destination the program authorizes. Like the
///      router, it neither emits nor stores the Zone's sender commitment or a cardholder address.
contract CardSettler is ISpendSettler {
    /// @dev Solady's `TransferFailed()` and `ApproveFailed()`, as `BridgeSettler` reverts with them.
    bytes4 private constant TRANSFER_FAILED = 0x90b8ec18;
    bytes4 private constant APPROVE_FAILED = 0x3e3f8f73;

    CardSpender public immutable SPENDER;
    address public immutable PROGRAM;

    bool private transient _locked;

    error DestinationNotPaid();
    error InsufficientInput();
    error InvalidAmount();
    error NothingSettled();
    error Reentrancy();
    error ResidualBalance(address token);
    error WrongInputToken(address token);
    error WrongProgram(address program);
    error ZeroAddress();

    /// @dev Carries no cardholder address and no Zone sender commitment; the router emits the Zone side.
    event SpendSettled(bytes32 indexed ref, address inputToken, uint256 inputConsumed, uint256 inputReturned);

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(CardSpender spender_) {
        if (address(spender_) == address(0)) revert ZeroAddress();
        SPENDER = spender_;
        PROGRAM = address(spender_.PROGRAM());
    }

    /// @inheritdoc ISpendSettler
    /// @dev `data` is `abi.encode(CardSpend)`. Expects the caller to have transferred `maxInput` first,
    ///      and returns what the spend did not use in the same call.
    function settle(address token, uint256 maxInput, bytes calldata data) external override nonReentrant {
        CardSpend memory spend = abi.decode(data, (CardSpend));
        if (spend.program != PROGRAM) revert WrongProgram(spend.program);
        if (maxInput == 0 || maxInput > type(uint128).max) revert InvalidAmount();
        // One withdrawal carries one token: a stablecoin spend's token, or the shares of the vault that
        // funds all of it.
        address input;
        if (spend.fromVault == 0) {
            input = spend.token;
        } else if (spend.fromVault == spend.amount && spend.vault != address(0)) {
            input = IEarnVault(spend.vault).earnShare();
        }
        if (input == address(0) || input != token) revert WrongInputToken(token);

        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance < maxInput) revert InsufficientInput();
        uint256 baseline = balance - maxInput;
        uint256 destinationBefore = IERC20Like(spend.token).balanceOf(spend.destination);

        _approveSpender(token, maxInput);
        // forge-lint: disable-next-line(reentrancy-no-eth)
        SPENDER.spend(spend);

        uint256 unused = IERC20Like(token).balanceOf(address(this)) - baseline;
        if (unused >= maxInput) revert NothingSettled();
        if (IERC20Like(spend.token).balanceOf(spend.destination) != destinationBefore + spend.amount) {
            revert DestinationNotPaid();
        }
        if (unused != 0) _tokenCall(token, IERC20Like.transfer.selector, msg.sender, unused, TRANSFER_FAILED);
        if (IERC20Like(token).balanceOf(address(this)) != baseline) revert ResidualBalance(token);

        emit SpendSettled(spend.ref, token, maxInput - unused, unused);
    }

    /// @notice Sets the settler's standing approval of `token` to its spender before the first spend.
    ///         Permissionless: the settler holds no balance between spends.
    function warm(address token) external {
        _approveSpender(token, type(uint256).max);
    }

    /// @dev A standing maximum approval, topped up only when it falls below `amount` (TIP-1000).
    function _approveSpender(address token, uint256 amount) private {
        if (IERC20Allowance(token).allowance(address(this), address(SPENDER)) < amount) {
            _tokenCall(token, IERC20Like.approve.selector, address(SPENDER), type(uint256).max, APPROVE_FAILED);
        }
    }

    /// @dev `approve` or `transfer` on `token`, reverting with `failure` alone unless it returns `true`,
    ///      or returns nothing from an address with code.
    function _tokenCall(address token, bytes4 selector, address to, uint256 amount, bytes4 failure) private {
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, selector)
            mstore(add(m, 0x04), to)
            mstore(add(m, 0x24), amount)
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
