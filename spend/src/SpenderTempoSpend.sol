// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFactory } from "bridge-spender/src/lib/IFactory.sol";
import { SpenderBase } from "bridge-spender/src/spenders/SpenderBase.sol";
import { IERC20 } from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { IBridgeSpenderFactory } from "./interfaces/IBridgeSpenderFactory.sol";
import { ITempoEarnVault } from "./interfaces/ITempoEarnVault.sol";

/// @notice One card spend. The same struct settles public spend (paid by the cardholder's account)
///         and private spend (paid by the program's `ZoneSpendReceiver`).
struct Spend {
    bytes32 spenderId;
    /// @dev Stablecoin the destination receives.
    address token;
    uint256 amount;
    address destination;
    /// @dev Tempo Earn vault that funds `fromVault`, holding `token`. Zero when `fromVault` is zero.
    address vault;
    /// @dev Part of `amount` redeemed from `vault`. The rest is paid in `token`.
    uint256 fromVault;
    /// @dev Most EarnShares `fromVault` may burn. Zero accepts the live price.
    uint256 maxShares;
    /// @dev Bridge's own reference for reconciliation. Emitted, never enforced.
    bytes32 ref;
}

struct SpenderTempoSpendStorage {
    mapping(address vault => bool allowed) allowedVaults;
}

library SpenderTempoSpendStorageLib {
    /// @custom:storage-location erc7201:tempo.spend.SpenderTempoSpend
    bytes32 internal constant SLOT = 0xbc7f0a75443d84f208551e2e19a839e794ecf9029344e5d8e1a095f84e555400;

    function load() internal pure returns (SpenderTempoSpendStorage storage $) {
        assembly {
            $.slot := SLOT
        }
    }
}

/// @title SpenderTempoSpend
/// @notice Bridge spender handler (prefix "TS") that settles Tempo card spend from stablecoin,
///         Tempo Earn shares, or both, publicly or from a Zone.
/// @dev Runs by delegatecall inside a Bridge spender clone, so the factory's destinations and
///      pause govern every spend. The payer submits a `Spend` through `publicCall "PS"`:
///      - public spend: the cardholder's account, in a transaction signed by Bridge's access key
///        that approves the exact amount, spends and clears the approval;
///      - private spend: the program's `ZoneSpendReceiver`, after a Zone withdrawal.
///      Bridge's pull pipeline (`transferToDestination`) is not used: it needs a standing
///      allowance and cannot reach Zone balances.
///      A spend settles in the stablecoin the funds are held in. Earn shares redeem into the
///      vault's own asset, so a spend from Earn names that asset as `token`.
///
/// Payload layouts (after the factory strips the 2-byte handler prefix):
///   balance:  from(20) token(20) [vault(20)]
///   governorCall "UV": flag(1) vault(20)
///   publicCall  "PS": abi.encode(Spend), paid by msg.sender
///   publicGetCall "GV" vault(20)
contract SpenderTempoSpend is SpenderBase {
    error DestinationNotAuthorized(address destination);
    error ExpectedBooleanByte();
    error IncorrectAssetForVault();
    error ShareCostExceeded(uint256 required, uint256 maxShares);
    error PipelineDisabled();
    error VaultNotAllowed();
    error WrongProgram(bytes32 spenderId);

    /// @dev Named apart from the Tempo Earn handler's `VaultStatusUpdated`, which the same clone
    ///      can emit with a different signature.
    event SpendVaultUpdated(address indexed vault, bool allowed);
    event TempoSpendExecuted(
        bytes32 indexed ref,
        address indexed from,
        address indexed destination,
        address token,
        uint256 amount,
        uint256 fromStable,
        uint256 fromVault,
        uint256 sharesBurned
    );

    constructor(IFactory factory_) SpenderBase(factory_) { }

    // ------------------------------------------------------------------
    // Factory entrypoints
    // ------------------------------------------------------------------

    function transferToDestination(address, bytes calldata) external pure override {
        revert PipelineDisabled();
    }

    function transferToDestinationStrict(address, bytes calldata) external pure override {
        revert PipelineDisabled();
    }

    /// @notice Stablecoin balance of `from`, plus the value of its shares in `vault` when given
    ///         and the vault holds `token`.
    function availableBalance(bytes calldata data) external view override returns (uint256) {
        require(data.length == 40 || data.length == 60, DataIncorrectLength());
        address from = address(bytes20(data[0:20]));
        address token = address(bytes20(data[20:40]));
        uint256 total = IERC20(token).balanceOf(from);
        if (data.length == 60) {
            address vault = address(bytes20(data[40:60]));
            if (_storage().allowedVaults[vault]) {
                total += _vaultValue(ITempoEarnVault(vault), from, token);
            }
        }
        return total;
    }

    /// @dev Governance, not the manager, allows vaults: a vault's `withdrawExact` decides where
    ///      redeemed value goes, so allowing one is as strong as adding a destination.
    function governorCall(bytes calldata data) external override onlyFactory {
        bytes2 action = _prefix(data);
        require(action == "UV", PrefixUnknown(action));
        require(data.length == 23, DataIncorrectLength());
        require(data[2] == 0x00 || data[2] == 0x01, ExpectedBooleanByte());
        address vault = address(bytes20(data[3:23]));
        bool allowed = data[2] == 0x01;
        _storage().allowedVaults[vault] = allowed;
        emit SpendVaultUpdated(vault, allowed);
    }

    /// @dev The clone has already checked the factory's pause.
    function publicCall(bytes calldata data) external override {
        bytes2 action = _prefix(data);
        require(action == "PS", PrefixUnknown(action));
        _spend(abi.decode(data[2:], (Spend)));
    }

    function publicGetCall(bytes calldata data) external view override returns (bytes memory) {
        bytes2 query = _prefix(data);
        require(query == "GV", PrefixUnknown(query));
        require(data.length == 22, DataIncorrectLength());
        return abi.encode(_storage().allowedVaults[address(bytes20(data[2:22]))]);
    }

    // ------------------------------------------------------------------
    // Settlement
    // ------------------------------------------------------------------

    function _spend(Spend memory s) private {
        IBridgeSpenderFactory factory = IBridgeSpenderFactory(address(FACTORY));
        require(_isCanonical(s.spenderId), WrongProgram(s.spenderId));
        require(factory.getSpenderAddress(s.spenderId) == address(this), WrongProgram(s.spenderId));
        require(factory.isAuthorizedDestination(s.spenderId, s.destination), DestinationNotAuthorized(s.destination));
        require(s.amount > 0 && s.fromVault <= s.amount, InvalidAmount());

        uint256 fromStable = s.amount - s.fromVault;
        uint256 before = IERC20(s.token).balanceOf(s.destination);
        if (fromStable != 0) {
            SafeTransferLib.safeTransferFrom(s.token, msg.sender, s.destination, fromStable);
        }
        uint256 sharesBurned;
        if (s.fromVault != 0) {
            require(_storage().allowedVaults[s.vault], VaultNotAllowed());
            require(ITempoEarnVault(s.vault).asset() == s.token, IncorrectAssetForVault());
            sharesBurned = _withdrawFromEarn(s.vault, s.destination, s.fromVault, s.maxShares);
        }
        require(IERC20(s.token).balanceOf(s.destination) == before + s.amount, DestinationNotCredited());

        emit TempoSpendExecuted(
            s.ref, msg.sender, s.destination, s.token, s.amount, fromStable, s.fromVault, sharesBurned
        );
    }

    /// @dev Pulls only the shares `assets` costs, burns them and returns any the vault left over.
    function _withdrawFromEarn(address vault, address receiver, uint256 assets, uint256 maxShares)
        private
        returns (uint256 burned)
    {
        ITempoEarnVault v = ITempoEarnVault(vault);
        uint256 required = v.previewWithdraw(assets);
        require(maxShares == 0 || required <= maxShares, ShareCostExceeded(required, maxShares));

        address share = v.earnShare();
        SafeTransferLib.safeTransferFrom(share, msg.sender, address(this), required);
        SafeTransferLib.safeApprove(share, vault, required);
        burned = v.withdrawExact(assets, receiver, required);
        SafeTransferLib.safeApprove(share, vault, 0);
        if (burned < required) SafeTransferLib.safeTransfer(share, msg.sender, required - burned);
    }

    /// @dev Value of `from`'s shares in `vault` when it holds `token`. A vault that cannot report
    ///      its asset, share or redemption value adds nothing, so the stablecoin stays readable.
    ///      Reads are low-level: `try` cannot catch a call to an address without code or return
    ///      data it cannot decode, which would revert the whole balance query.
    function _vaultValue(ITempoEarnVault vault, address from, address token) private view returns (uint256) {
        (bool ok, uint256 word) = _readWord(address(vault), abi.encodeCall(vault.asset, ()));
        if (!ok || word != uint256(uint160(token))) return 0;
        (ok, word) = _readWord(address(vault), abi.encodeCall(vault.earnShare, ()));
        if (!ok || word >> 160 != 0) return 0;
        address share = address(uint160(word));
        uint256 shares;
        (ok, shares) = _readWord(share, abi.encodeCall(IERC20.balanceOf, (from)));
        if (!ok || shares == 0) return 0;
        (ok, word) = _readWord(address(vault), abi.encodeCall(vault.previewRedeem, (shares)));
        return ok ? word : 0;
    }

    /// @dev False unless `target` has code, the call succeeds and it returns at least one word.
    function _readWord(address target, bytes memory data) private view returns (bool ok, uint256 word) {
        if (target.code.length == 0) return (false, 0);
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev True when `createSpender(spenderId)` deployed this clone. A manager can register more
    ///      IDs on an existing clone, each with its own destinations, and those must not pay.
    function _isCanonical(bytes32 spenderId) private view returns (bool) {
        return LibClone.predictDeterministicAddressERC1967BeaconProxy(address(FACTORY), spenderId, address(FACTORY))
            == address(this);
    }

    function _storage() private pure returns (SpenderTempoSpendStorage storage) {
        return SpenderTempoSpendStorageLib.load();
    }
}
