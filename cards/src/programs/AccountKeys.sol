// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ECDSA } from "solady/utils/ECDSA.sol";

/// @title AccountKeys
/// @notice The keys that sign cardholder actions for an account, and the guardians that can replace them when a device
///         is lost. The reservation core keeps no account keys: money, holds, debts and card records stay keyed by the
///         account, so a recovery changes only who signs. One registry serves every card program that consults it.
/// @dev An account without keys signs as itself. Once it sets keys, only those keys sign, the account's own key
///      included only if it is listed. A guardian recovery waits RECOVERY_DELAY before the new key signs, and until
///      then the account or any of its keys can cancel it, so a guardian quorum cannot take an account its owner
///      still holds.
contract AccountKeys {
    /// @notice Most keys or guardians an account may list.
    uint256 public constant MAX_ENTRIES = 16;
    /// @notice Seconds between guardians approving a recovery and its key signing for the account.
    uint64 public constant RECOVERY_DELAY = 3 days;

    /// @param recoveryKey The key a pending recovery installs; zero for none.
    /// @param recoveryAt When the pending recovery may complete.
    struct Account {
        address[] keys;
        address[] guardians;
        uint8 threshold;
        uint64 nonce;
        address recoveryKey;
        uint64 recoveryAt;
    }

    mapping(address account => Account) internal _accounts;

    event AccountConfigured(address indexed account, address[] keys, address[] guardians, uint8 threshold);
    /// @notice Guardians approved replacing the account's keys with key, which signs from readyAt unless cancelled.
    event RecoveryStarted(
        address indexed account, address indexed key, uint64 readyAt, uint64 nonce, address[] approvals
    );
    /// @notice The account or one of its keys cancelled the pending recovery to key.
    event RecoveryCancelled(address indexed account, address indexed key);
    /// @notice The account's keys are now key alone.
    event AccountRecovered(address indexed account, address indexed key);

    error NotSigner();
    error InvalidKeys();
    error ThresholdAboveGuardians();
    error NotEnoughGuardians(uint256 approvals, uint256 threshold);
    error NoRecovery();
    error RecoveryNotReady(uint64 readyAt);

    /// @notice Sets `account`'s signing keys and guardians. The caller is the account until it has keys, then one of
    ///         them. A zero `threshold` means a majority of the guardians; with no guardians the account cannot recover.
    ///         It cancels a pending recovery.
    function configure(address account, address[] calldata keys, address[] calldata guardians, uint8 threshold)
        external
    {
        if (!signsFor(account, msg.sender)) revert NotSigner();
        if (keys.length == 0 || keys.length > MAX_ENTRIES || guardians.length > MAX_ENTRIES) revert InvalidKeys();
        _requireDistinct(keys);
        _requireDistinct(guardians);
        if (guardians.length == 0) {
            threshold = 0;
        } else if (threshold == 0) {
            // Bounded by MAX_ENTRIES.
            // forge-lint: disable-next-line(unsafe-typecast)
            threshold = uint8(guardians.length / 2 + 1);
        } else if (threshold > guardians.length) {
            revert ThresholdAboveGuardians();
        }
        Account storage a = _accounts[account];
        a.keys = keys;
        a.guardians = guardians;
        a.threshold = threshold;
        // Approvals signed for the old guardians or keys stop counting.
        ++a.nonce;
        emit AccountConfigured(account, keys, guardians, threshold);
        _cancel(account, a);
    }

    /// @notice Starts replacing `account`'s keys with `key`, approved by at least its threshold of guardians; the
    ///         replacement completes after RECOVERY_DELAY unless the account or one of its keys cancels it first. It
    ///         replaces any pending recovery. Anyone submits the guardians' signatures over
    ///         `recoveryDigest(account, key)`; signatures from strangers and repeats count for nothing and block nothing.
    function recover(address account, address key, bytes[] calldata signatures) external {
        Account storage a = _accounts[account];
        if (key == address(0)) revert InvalidKeys();
        bytes32 digest = recoveryDigest(account, key);
        address[] memory guardians = a.guardians;
        address[] memory approvals = new address[](guardians.length);
        uint256 count;
        uint256 seen;
        for (uint256 i; i < signatures.length; ++i) {
            address signer = ECDSA.tryRecoverCalldata(digest, signatures[i]);
            if (signer == address(0)) continue;
            for (uint256 g; g < guardians.length; ++g) {
                if (guardians[g] != signer || seen & (1 << g) != 0) continue;
                seen |= 1 << g;
                approvals[count++] = signer;
                break;
            }
        }
        uint256 threshold = a.threshold;
        if (threshold == 0 || count < threshold) revert NotEnoughGuardians(count, threshold);
        assembly {
            mstore(approvals, count)
        }
        // The approvals are used up: a cancelled recovery needs new ones.
        uint64 nonce = a.nonce++;
        uint64 readyAt = _now() + RECOVERY_DELAY;
        (a.recoveryKey, a.recoveryAt) = (key, readyAt);
        emit RecoveryStarted(account, key, readyAt, nonce, approvals);
    }

    /// @notice Completes `account`'s pending recovery once its delay has passed: its keys become the recovery's key
    ///         alone. Anyone may call it.
    function completeRecovery(address account) external {
        Account storage a = _accounts[account];
        address key = a.recoveryKey;
        if (key == address(0)) revert NoRecovery();
        uint64 readyAt = a.recoveryAt;
        // The delay is measured in days; a few seconds of validator skew does not change it.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < readyAt) revert RecoveryNotReady(readyAt);
        (a.recoveryKey, a.recoveryAt) = (address(0), 0);
        delete a.keys;
        a.keys.push(key);
        emit AccountRecovered(account, key);
    }

    /// @notice The account, or one of its current keys, cancels its pending recovery.
    function cancelRecovery(address account) external {
        if (msg.sender != account && !signsFor(account, msg.sender)) revert NotSigner();
        Account storage a = _accounts[account];
        if (a.recoveryKey == address(0)) revert NoRecovery();
        _cancel(account, a);
    }

    /// @notice Whether `signer` signs cardholder actions for `account`: the account itself until it sets keys, then
    ///         only its keys.
    function signsFor(address account, address signer) public view returns (bool) {
        address[] storage keys = _accounts[account].keys;
        if (keys.length == 0) return signer == account;
        for (uint256 i; i < keys.length; ++i) {
            if (keys[i] == signer) return true;
        }
        return false;
    }

    /// @notice What a guardian signs (as an Ethereum signed message) to approve replacing `account`'s keys with `key`.
    ///         It names this registry, the chain and the account's nonce, so it cannot be replayed after a recovery or
    ///         a change of guardians.
    function recoveryDigest(address account, address key) public view returns (bytes32) {
        return ECDSA.toEthSignedMessageHash(
            keccak256(abi.encode(address(this), block.chainid, account, key, _accounts[account].nonce))
        );
    }

    /// @notice `account`'s pending recovery: the key it installs and when it may complete; zero key for none.
    function recoveryOf(address account) external view returns (address key, uint64 readyAt) {
        Account storage a = _accounts[account];
        return (a.recoveryKey, a.recoveryAt);
    }

    function accountOf(address account)
        external
        view
        returns (address[] memory keys, address[] memory guardians, uint8 threshold, uint64 nonce)
    {
        Account storage a = _accounts[account];
        return (a.keys, a.guardians, a.threshold, a.nonce);
    }

    /// @dev Drops a pending recovery, if any.
    function _cancel(address account, Account storage a) private {
        address key = a.recoveryKey;
        if (key == address(0)) return;
        (a.recoveryKey, a.recoveryAt) = (address(0), 0);
        emit RecoveryCancelled(account, key);
    }

    function _now() private view returns (uint64) {
        // Timestamps fit 64 bits for billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp);
    }

    function _requireDistinct(address[] calldata list) private pure {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == address(0)) revert InvalidKeys();
            for (uint256 j; j < i; ++j) {
                if (list[i] == list[j]) revert InvalidKeys();
            }
        }
    }
}
