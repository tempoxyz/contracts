// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISpenderHandler } from "../ISpenderHandler.sol";
import { IFactory } from "../lib/IFactory.sol";
import { SpenderBase } from "./SpenderBase.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { Math } from "openzeppelin-contracts/utils/math/Math.sol";
import { IAllowanceTransfer } from "permit2/interfaces/IAllowanceTransfer.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

struct SpenderTEWFStorage {
    // maps the user wallet to the vault they want to use. If a 0 address,
    // it uses a stablecoin directly
    mapping(address wallet => address vault) userPreferences;
    mapping(address vault => bool allowed) allowedVaults;
}

library SpenderTEWFStorageLib {

    ///@custom:storage-location eip7201:TempoEarnWithFallback
    bytes32 constant SPENDER_TEWF_SLOT =
        0xa5d80f420d26a01a929d0ea3a1df4d9bb3f4a509e3625ebe01350815c94acc00;

    function getStorage() internal pure returns (SpenderTEWFStorage storage $) {
        assembly {
            $.slot := SPENDER_TEWF_SLOT
        }
    }

}

interface ITempoEarnVault {

    function withdrawExact(uint256 assets, address receiver, uint256 maxEarnShares)
        external
        returns (uint256 earnSharesBurned);
    function previewWithdraw(uint256 assets) external view returns (uint256 earnShares);
    function previewRedeem(uint256 earnShares) external view returns (uint256 assets);
    function asset() external view returns (address);
    function earnShare() external view returns (address);

}

// updating vault set
bytes2 constant UPDATE_VAULTS_PREFIX = "UV";
uint256 constant UPDATE_VAULTS_MESSAGE_LENGTH = 23; // 2 byte prefix + 1 byte boolean + 20 byte
// address

// message lengths
bytes2 constant UPDATE_PREFERENCE_PREFIX = "UP";
uint256 constant UPDATE_PREFERENCE_MESSAGE_LENGTH = 22; // 2 byte prefix + 20 byte address

// getter prefixes (used in publicGetCall)
bytes2 constant GET_VAULT_PREFIX = "GV";
bytes2 constant GET_PREFERENCE_PREFIX = "GP";
uint256 constant GET_MESSAGE_LENGTH = 22; // 2 byte prefix + 20 byte address

// other lengths
uint256 constant TRANSFER_LEN = 72; // 20 + 20 + 32
uint256 constant BALANCE_LEN = 40; // 20 + 20

contract SpenderTEWF is SpenderBase {

    // errors
    error ExpectedBooleanByte();
    error VaultNotAllowed();
    error IncorrectAssetForVault();

    // events
    /// @notice Emitted when a vault's allowed status changes. Emitted in the spender clone's
    ///         context (via delegatecall), so indexers must monitor spender addresses.
    event VaultStatusUpdated(address indexed vault, bool previousStatus, bool newStatus);
    /// @notice Emitted when a user updates their vault preference. Emitted in the spender
    ///         clone's context (via delegatecall), so indexers must monitor spender addresses.
    event UserPreferenceUpdated(address indexed wallet, address previousVault, address newVault);

    constructor(IFactory factory_) SpenderBase(factory_) { }

    function transferToDestination(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        (address from, address token, uint256 amount) = _decodeTransferPayload(data);
        address vault = _userPreference(from);

        if (vault == address(0)) {
            _transferToDestinationErc20(destination, from, token, amount);
        } else {
            ITempoEarnVault v = ITempoEarnVault(vault);
            // Intentional: shareAmount is sized from a live previewWithdraw at execution
            // time with no caller-supplied cap. This contract is an MVP that deliberately
            // omits off-chain slippage protection; if the rate worsens between quote and
            // inclusion the user may burn more earnShares than expected. Slippage guards
            // (e.g. a maxEarnShares field in the payload) may be added in a future version.
            _transferToDestinationTempoEarn(
                destination, from, token, amount, v, v.previewWithdraw(amount)
            );
        }
    }

    function transferToDestinationStrict(address destination, bytes calldata data)
        external
        override
        onlyFactory
    {
        (address from, address token, uint256 amount) = _decodeTransferPayload(data);
        address vault = _userPreference(from);

        if (vault == address(0)) {
            _transferToDestinationStrictErc20(destination, from, token, amount);
        } else {
            _transferToDestinationStrictTempoEarn(
                destination, from, token, amount, ITempoEarnVault(vault)
            );
        }
    }

    function availableBalance(bytes calldata data) external view override returns (uint256) {
        (address from, address token) = _decodeBalancePayload(data);
        address vault = _userPreference(from);

        if (vault == address(0)) {
            return _availableBalanceErc20(from, token);
        } else {
            return _availableBalanceTempoEarn(from, token, ITempoEarnVault(vault));
        }
    }

    function managerCall(bytes calldata data) external override onlyFactory {
        _processVaultUpdate(data);
    }

    function publicCall(bytes calldata data) external override {
        _processPreferenceUpdate(data);
    }

    function publicGetCall(bytes calldata data) external view override returns (bytes memory) {
        require(data.length >= 2, DataIncorrectLength());
        bytes2 innerPrefix = bytes2(data[0:2]);

        if (innerPrefix == GET_VAULT_PREFIX) {
            _validateLengthAndPrefix(data, GET_VAULT_PREFIX, GET_MESSAGE_LENGTH);
            return abi.encode(
                SpenderTEWFStorageLib.getStorage().allowedVaults[_addressFromIndex(data, 2)]
            );
        } else if (innerPrefix == GET_PREFERENCE_PREFIX) {
            _validateLengthAndPrefix(data, GET_PREFERENCE_PREFIX, GET_MESSAGE_LENGTH);
            return abi.encode(
                SpenderTEWFStorageLib.getStorage().userPreferences[_addressFromIndex(data, 2)]
            );
        } else {
            revert PrefixUnknown(innerPrefix);
        }
    }

    // ============ Tempo Earn Internal Functions ============

    function _transferToDestinationTempoEarn(
        address destination,
        address from,
        address token,
        uint256 amount,
        ITempoEarnVault vault,
        uint256 shareAmount
    ) private {
        require(vault.asset() == token, IncorrectAssetForVault());
        require(amount > 0, InvalidAmount());

        address share = vault.earnShare();
        SafeTransferLib.safeTransferFrom(share, from, address(this), shareAmount);

        // withdrawExact pulls earnShare from msg.sender (this contract) via transferFrom,
        // so we must approve the vault for the budget before calling.
        SafeTransferLib.safeApprove(share, address(vault), shareAmount);
        // maxEarnShares is our budget; the vault may burn fewer if the rate has moved.
        // Return any surplus so shares never strand in this contract.
        uint256 burned = vault.withdrawExact(amount, destination, shareAmount);
        SafeTransferLib.safeApprove(share, address(vault), 0);

        if (burned < shareAmount) {
            SafeTransferLib.safeTransfer(share, from, shareAmount - burned);
        }

        emit TransferExecuted(from, destination, token, amount);
    }

    function _transferToDestinationStrictTempoEarn(
        address destination,
        address from,
        address token,
        uint256 amount,
        ITempoEarnVault vault
    ) private {
        uint256 shareAmount = vault.previewWithdraw(amount);
        IERC20 share = IERC20(vault.earnShare());

        require(share.allowance(from, address(this)) >= shareAmount, InsufficientAllowance());
        require(share.balanceOf(from) >= shareAmount, InsufficientBalance());

        _transferToDestinationTempoEarn(destination, from, token, amount, vault, shareAmount);
    }

    function _availableBalanceTempoEarn(address from, address token, ITempoEarnVault vault)
        private
        view
        returns (uint256)
    {
        require(vault.asset() == token, IncorrectAssetForVault());
        IERC20 share = IERC20(vault.earnShare());

        uint256 sharesHeldOrAllowed =
            Math.min(share.balanceOf(from), share.allowance(from, address(this)));

        return vault.previewRedeem(sharesHeldOrAllowed);
    }

    // ============ ERC20 Internal Functions ============

    function _transferToDestinationErc20(
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

    function _transferToDestinationStrictErc20(
        address destination,
        address from,
        address token,
        uint256 amount
    ) private {
        require(IERC20(token).balanceOf(from) >= amount, InsufficientBalance());
        require(IERC20(token).allowance(from, address(this)) >= amount, InsufficientAllowance());
        _transferToDestinationErc20(destination, from, token, amount);
    }

    function _availableBalanceErc20(address from, address token) private view returns (uint256) {
        return Math.min(IERC20(token).balanceOf(from), IERC20(token).allowance(from, address(this)));
    }

    // ============ General Internal Functions ============

    function _userPreference(address wallet) private view returns (address) {
        return SpenderTEWFStorageLib.getStorage().userPreferences[wallet];
    }

    function _processVaultUpdate(bytes calldata data) private {
        // the expected format for this managerCall is:
        // - 2 byte prefix (only one value for now, bytes2("UV"))
        // - 1 byte to indicate enable (1) or disable (0)
        // - 20 bytes (vault address)
        //
        // Intentional: disabling a vault only prevents new users from selecting it as their
        // preference. Existing users who already set this vault keep it active — their prior
        // config is preserved and transfers continue to route through the vault. Users can
        // opt out by updating their own preference (publicCall UP + address(0) or a new vault).
        _validateLengthAndPrefix(data, UPDATE_VAULTS_PREFIX, UPDATE_VAULTS_MESSAGE_LENGTH);
        require(data[2] == 0x00 || data[2] == 0x01, ExpectedBooleanByte());

        address vault = _addressFromIndex(data, 3);
        bool newStatus = data[2] == 0x01;
        bool previousStatus = SpenderTEWFStorageLib.getStorage().allowedVaults[vault];
        SpenderTEWFStorageLib.getStorage().allowedVaults[vault] = newStatus;
        emit VaultStatusUpdated(vault, previousStatus, newStatus);
    }

    function _processPreferenceUpdate(bytes calldata data) private {
        // expected layout:
        // - 2 byte prefix
        // - 20 byte (new value)
        _validateLengthAndPrefix(data, UPDATE_PREFERENCE_PREFIX, UPDATE_PREFERENCE_MESSAGE_LENGTH);

        address preference = _addressFromIndex(data, 2);

        // address(0) is the sentinel for "no vault — use ERC20 directly".
        // Allow it so users can revert to ERC20 mode after opting into a vault.
        require(
            preference == address(0)
                || SpenderTEWFStorageLib.getStorage().allowedVaults[preference],
            VaultNotAllowed()
        );

        address previousPreference = SpenderTEWFStorageLib.getStorage().userPreferences[msg.sender];
        SpenderTEWFStorageLib.getStorage().userPreferences[msg.sender] = preference;
        emit UserPreferenceUpdated(msg.sender, previousPreference, preference);
    }

    function _validateLengthAndPrefix(bytes calldata data, bytes2 prefix, uint256 messageLength)
        private
        pure
    {
        require(data.length == messageLength, DataIncorrectLength());
        require(bytes2(data[0:2]) == prefix, PrefixUnknown(bytes2(data[0:2])));
    }

    function _addressFromIndex(bytes calldata data, uint256 index) private pure returns (address) {
        return address(bytes20(data[index:index + 20]));
    }

    function _decodeTransferPayload(bytes calldata data)
        internal
        pure
        returns (address from, address token, uint256 amount)
    {
        require(data.length == TRANSFER_LEN, DataIncorrectLength());
        from = address(bytes20(data[0:20]));
        token = address(bytes20(data[20:40]));
        amount = uint256(bytes32(data[40:72]));
    }

    function _decodeBalancePayload(bytes calldata data)
        internal
        pure
        returns (address from, address token)
    {
        require(data.length == BALANCE_LEN, DataIncorrectLength());
        from = address(bytes20(data[0:20]));
        token = address(bytes20(data[20:40]));
    }

}
