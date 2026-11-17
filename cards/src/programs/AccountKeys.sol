// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ECDSA } from "solady/utils/ECDSA.sol";

/// @title AccountKeys
/// @notice The keys that sign cardholder actions for an account, and the guardians that can replace them when a device
///         is lost. The reservation core keeps no account keys: money, holds, debts and card records stay keyed by the
///         account, so a recovery changes only who signs. One registry serves every card program that consults it.
/// @dev An account without keys signs as itself. Once it sets keys, only those keys sign, the account's own key
///      included only if it is listed.
contract AccountKeys {
    /// @notice Most keys or guardians an account may list.
    uint256 public constant MAX_ENTRIES = 16;

    struct Account {
        address[] keys;
        address[] guardians;
        uint8 threshold;
        uint64 nonce;
    }

    mapping(address account => Account) internal _accounts;

    event AccountConfigured(address indexed account, address[] keys, address[] guardians, uint8 threshold);
    event AccountRecovered(address indexed account, address indexed key, uint64 nonce, address[] approvals);

    error NotSigner();
    error InvalidKeys();
    error ThresholdAboveGuardians();
    error NotEnoughGuardians(uint256 approvals, uint256 threshold);

    /// @notice Sets `account`'s signing keys and guardians. The caller is the account until it has keys, then one of
    ///         them. A zero `threshold` means a majority of the guardians; with no guardians the account cannot recover.
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
    }

    /// @notice Replaces `account`'s keys with `key`, approved by at least its threshold of guardians. Anyone submits
    ///         the guardians' signatures over `recoveryDigest(account, key)`; signatures from strangers and repeats
    ///         count for nothing and block nothing.
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
        delete a.keys;
        a.keys.push(key);
        uint64 nonce = a.nonce++;
        emit AccountRecovered(account, key, nonce, approvals);
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

    function accountOf(address account)
        external
        view
        returns (address[] memory keys, address[] memory guardians, uint8 threshold, uint64 nonce)
    {
        Account storage a = _accounts[account];
        return (a.keys, a.guardians, a.threshold, a.nonce);
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
