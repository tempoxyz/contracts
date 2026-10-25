// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import {
    DepositPayload,
    IWithdrawalReceiver,
    IZoneFactory,
    IZonePortal,
    ZONE_FACTORY_ADDRESS,
    ZONE_MESSENGER_ADDRESS,
    ZoneInfo
} from "tempo-zones/interfaces/IZone.sol";

import { Spend } from "./SpenderTempoSpend.sol";
import { IBridgeSpenderClone, IBridgeSpenderFactory } from "./interfaces/IBridgeSpenderFactory.sol";

/// @title ZoneSpendReceiver
/// @notice Receives private card spend from one Zone and settles it through the card program's
///         Bridge spender clone, with the same `Spend` public spend uses.
/// @dev One deployment serves one Bridge card program (`SPENDER_ID`) and one Zone. It holds only
///      Zone plumbing: the clone has no fallback to take the withdrawal callback, and a
///      closed-loop Zone requires unused input to come back. It pays the spend from the withdrawn
///      input through the "TS" handler and returns the rest to the Zone encrypted. It has no
///      owner. Bridge matches each settlement to the Zone withdrawal it sent by `senderTag`.
contract ZoneSpendReceiver is IWithdrawalReceiver {
    bytes2 private constant HANDLER = "TS";

    /// @notice Where unused input goes: an encrypted deposit back into the source Zone.
    struct ZoneReturn {
        uint256 keyIndex;
        DepositPayload encrypted;
        /// @dev Public Tempo address that receives the return if the Zone rejects it.
        address refundRecipient;
        /// @dev Most the portal may keep as its deposit fee. The Zone admin sets the fee, so a
        ///      higher fee at deposit time reverts instead of taking the change or refund.
        uint128 maxDepositFee;
    }

    IBridgeSpenderFactory public immutable FACTORY;
    bytes32 public immutable SPENDER_ID;
    uint32 public immutable ZONE_ID;

    uint256 private _locked = 1;

    error DepositFeeTooHigh(uint128 fee);
    error DestinationNotPaid();
    error InvalidAmount();
    error InvalidSourcePortal();
    error InvalidZone();
    error NothingSettled();
    error NotProgramDestination(address caller);
    error NotZoneMessenger();
    error ProgramPaused();
    error Reentrancy();
    error ResidualBalance(address token);
    error WrongSourceZone(uint32 zoneId);
    error ZeroAddress();

    /// @dev Carries no cardholder address. `senderTag` is the Zone's commitment to the withdrawal's
    ///      sender and transaction, which Bridge can recompute for the withdrawals it sent.
    event PrivateSpendSettled(
        bytes32 indexed senderTag, bytes32 indexed ref, address inputToken, uint256 inputConsumed, uint256 inputReturned
    );
    event PrivateRefundCredited(address indexed token, uint256 amount);

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(IBridgeSpenderFactory factory_, bytes32 spenderId_, uint32 zoneId_) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        if (zoneId_ == 0) revert InvalidZone();
        FACTORY = factory_;
        SPENDER_ID = spenderId_;
        ZONE_ID = zoneId_;
    }

    /// @inheritdoc IWithdrawalReceiver
    /// @dev `callbackData` is `abi.encode(Spend, ZoneReturn)`. Any revert makes the portal bounce
    ///      the input back into the Zone.
    function onWithdrawalReceived(
        uint32 sourceZoneId,
        address sourcePortal,
        bytes32 senderTag,
        address token,
        uint128 amount,
        bytes calldata callbackData
    ) external override nonReentrant returns (bytes4) {
        if (msg.sender != ZONE_MESSENGER_ADDRESS) {
            revert NotZoneMessenger();
        }
        if (sourceZoneId != ZONE_ID) revert WrongSourceZone(sourceZoneId);
        if (sourcePortal != _portal()) revert InvalidSourcePortal();

        (Spend memory spend, ZoneReturn memory ret) = abi.decode(callbackData, (Spend, ZoneReturn));
        // The messenger transferred `amount` in before calling; nothing may stay behind.
        uint256 inputBefore = IERC20(token).balanceOf(address(this)) - amount;

        // Checked here as well as in the handler, so a replaced handler cannot look settled.
        uint256 destinationBefore = IERC20(spend.token).balanceOf(spend.destination);

        address clone = _clone();
        SafeTransferLib.safeApprove(token, clone, amount);
        IBridgeSpenderClone(clone).publicCall(abi.encodePacked(HANDLER, bytes2("PS"), abi.encode(spend)));
        SafeTransferLib.safeApprove(token, clone, 0);

        uint256 returned = IERC20(token).balanceOf(address(this)) - inputBefore;
        // A spend always consumes input, so a handler that moved nothing, or handed back more
        // than it was given, must not look settled.
        if (returned >= amount) revert NothingSettled();
        if (IERC20(spend.token).balanceOf(spend.destination) != destinationBefore + spend.amount) {
            revert DestinationNotPaid();
        }
        if (returned != 0) _depositToZone(sourcePortal, token, returned, ret);
        if (IERC20(token).balanceOf(address(this)) != inputBefore) revert ResidualBalance(token);

        emit PrivateSpendSettled(senderTag, spend.ref, token, amount - returned, returned);
        return IWithdrawalReceiver.onWithdrawalReceived.selector;
    }

    /// @notice Credits a stablecoin refund paid by the caller into the Zone without naming the
    ///         cardholder on Tempo.
    /// @dev Only one of the program's destinations may pay, and not while the factory is paused.
    ///      On a closed-loop Zone the receiver is a callback gateway, so anyone else could use it
    ///      to deposit without being admitted.
    function refundPrivate(address token, uint256 amount, ZoneReturn calldata ret) external nonReentrant {
        if (FACTORY.paused()) revert ProgramPaused();
        if (!FACTORY.isAuthorizedDestination(SPENDER_ID, msg.sender)) {
            revert NotProgramDestination(msg.sender);
        }
        if (amount == 0 || amount > type(uint128).max) revert InvalidAmount();
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        _depositToZone(_portal(), token, amount, ret);
        emit PrivateRefundCredited(token, amount);
    }

    function _clone() private view returns (address) {
        return FACTORY.getSpenderAddress(SPENDER_ID);
    }

    function _portal() private view returns (address portal) {
        ZoneInfo memory zone = IZoneFactory(ZONE_FACTORY_ADDRESS).zones(ZONE_ID);
        portal = zone.portal;
        if (portal == address(0) || !IZoneFactory(ZONE_FACTORY_ADDRESS).isZonePortal(portal)) {
            revert InvalidSourcePortal();
        }
    }

    function _depositToZone(address portal, address token, uint256 amount, ZoneReturn memory ret) private {
        uint128 fee = IZonePortal(portal).calculateDepositFee();
        if (fee > ret.maxDepositFee) revert DepositFeeTooHigh(fee);
        SafeTransferLib.safeApprove(token, portal, amount);
        IZonePortal(portal).depositEncrypted(token, uint128(amount), ret.keyIndex, ret.encrypted, ret.refundRecipient);
        SafeTransferLib.safeApprove(token, portal, 0);
    }
}
