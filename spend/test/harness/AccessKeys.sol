// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { VmExecuteTransaction, VmRlp } from "tempo-std/StdVm.sol";
import { IAccountKeychain } from "tempo-std/interfaces/IAccountKeychain.sol";

import { ZoneEnv } from "./ZoneEnv.sol";
import { TempoTx, TxCall, TxEnvelope } from "./lib/TempoTx.sol";

/// @notice Tempo access keys through the real AccountKeychain precompile: a cardholder authorizes a
///         Bridge-held key, and Bridge signs Tempo transactions for the cardholder with it.
abstract contract AccessKeys is ZoneEnv {
    using TempoTx for TxEnvelope;

    uint32 internal constant LIMIT_PERIOD = 30 days;

    IAccountKeychain internal keychain = IAccountKeychain(StdPrecompiles.ACCOUNT_KEYCHAIN_ADDRESS);

    /// @dev Bridge-held access key that signs for cardholders.
    uint256 internal bridgeKeyPk = uint256(keccak256("bridge.access-key"));
    address internal bridgeKey = vm.addr(uint256(keccak256("bridge.access-key")));

    /// @notice Executes `calls` as one Tempo transaction from `account`, signed by Bridge's access
    ///         key with a V2 keychain signature. Returns false if the transaction reverted.
    function _execAsAccessKey(address account, TxCall[] memory calls) internal returns (bool ok) {
        (ok,) = _execSignedBy(bridgeKeyPk, account, calls);
    }

    /// @notice Executes `calls` like `_execAsAccessKey` and returns why the transaction failed:
    ///         the revert data of the call that reverted, or the encoded keychain error that
    ///         rejected the signature. Empty when it succeeded.
    function _execAsAccessKeyWithError(address account, TxCall[] memory calls)
        internal
        returns (bool ok, bytes memory reason)
    {
        bytes memory err;
        (ok, err) = _execSignedBy(bridgeKeyPk, account, calls);
        if (!ok) reason = _txError(err);
    }

    /// @notice Decodes the `vm.executeTransaction` failure message into the error behind it.
    function _txError(bytes memory cheatcodeError) internal pure returns (bytes memory) {
        string memory message = abi.decode(_tail(cheatcodeError, 4), (string));
        (bool reverted, uint256 hexStart) = _find(bytes(message), "transaction reverted: ");
        if (reverted) return vm.parseBytes(string(_tail(bytes(message), hexStart)));
        (bool rejected, uint256 from) = _find(bytes(message), "AccountKeychainError(");
        if (!rejected) return bytes(message);
        bytes memory name = _tail(bytes(message), from);
        uint256 end;
        while (end < name.length && name[end] != "(") ++end;
        assembly {
            mstore(name, end)
        }
        return abi.encodePacked(bytes4(keccak256(abi.encodePacked(name, "()"))));
    }

    /// @dev The bytes of `data` from `start` on.
    function _tail(bytes memory data, uint256 start) private pure returns (bytes memory out) {
        out = new bytes(data.length - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[start + i];
        }
    }

    /// @dev Whether `needle` occurs in `haystack`, and the index just past its first occurrence.
    function _find(bytes memory haystack, bytes memory needle)
        private
        pure
        returns (bool, uint256)
    {
        if (haystack.length < needle.length) return (false, 0);
        for (uint256 i; i <= haystack.length - needle.length; ++i) {
            bool matched = true;
            for (uint256 j; j < needle.length && matched; ++j) {
                matched = haystack[i + j] == needle[j];
            }
            if (matched) return (true, i + needle.length);
        }
        return (false, 0);
    }

    /// @notice Executes `calls` from `account`, signed by the access key `keyPk`. Returns the
    ///         revert data when the transaction fails.
    function _execSignedBy(uint256 keyPk, address account, TxCall[] memory calls)
        internal
        returns (bool, bytes memory)
    {
        TxEnvelope memory txn = TempoTx.create()
            .withChainId(uint64(block.chainid))
            .withGasLimit(29_000_000)
            .withMaxFeePerGas(0)
            .withCalls(calls)
            .withNonce(uint64(vm.getNonce(account)));
        bytes32 digest = keccak256(
            abi.encodePacked(uint8(0x04), txn.signingHash(VmRlp(address(vm))), account)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keyPk, digest);
        bytes memory raw = txn.encodeWithRawSignature(
            VmRlp(address(vm)), abi.encodePacked(uint8(0x04), account, r, s, v)
        );
        try VmExecuteTransaction(address(vm)).executeTransaction(raw) returns (bytes memory) {
            return (true, "");
        } catch (bytes memory err) {
            return (false, err);
        }
    }

    /// @notice The cardholder authorizes Bridge's access key with periodic token limits and the
    ///         given call scopes.
    function _authorizeBridgeKey(
        address account,
        address[] memory limitTokens,
        uint256[] memory limits,
        IAccountKeychain.CallScope[] memory scopes
    ) internal {
        IAccountKeychain.TokenLimit[] memory tokenLimits =
            new IAccountKeychain.TokenLimit[](limitTokens.length);
        for (uint256 i; i < limitTokens.length; ++i) {
            tokenLimits[i] = IAccountKeychain.TokenLimit({
                token: limitTokens[i], amount: limits[i], period: LIMIT_PERIOD
            });
        }
        IAccountKeychain.KeyRestrictions memory restrictions;
        restrictions.expiry = uint64(block.timestamp + 365 days);
        restrictions.enforceLimits = true;
        restrictions.limits = tokenLimits;
        restrictions.allowedCalls = scopes;
        vm.prank(account);
        keychain.authorizeKey(bridgeKey, IAccountKeychain.SignatureType.Secp256k1, restrictions);
    }

    function _scope(address target, bytes4 selector, address recipient)
        internal
        pure
        returns (IAccountKeychain.CallScope memory scope)
    {
        IAccountKeychain.SelectorRule[] memory rules = new IAccountKeychain.SelectorRule[](1);
        address[] memory recipients;
        if (recipient != address(0)) {
            recipients = new address[](1);
            recipients[0] = recipient;
        }
        rules[0] = IAccountKeychain.SelectorRule({ selector: selector, recipients: recipients });
        scope = IAccountKeychain.CallScope({ target: target, selectorRules: rules });
    }
}
