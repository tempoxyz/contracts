// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ERC165Checker } from "openzeppelin-contracts/utils/introspection/ERC165Checker.sol";
import { LibClone } from "solady/utils/LibClone.sol";
import { IEarnEngineExactWithdraw } from "tempo-earn/interfaces/engines/IEarnEngineExactWithdraw.sol";
import { IEarnEngineRedeem } from "tempo-earn/interfaces/engines/IEarnEngineRedeem.sol";

/// @notice Read-only checks the deploy scripts and the preflight share.
library ProgramChecks {
    /// @dev True when `createSpender(spenderId)` deployed `clone`, which "TS" requires of a program.
    function isCanonical(address factory, bytes32 spenderId, address clone) internal pure returns (bool) {
        return clone != address(0)
            && LibClone.predictDeterministicAddressERC1967BeaconProxy(factory, spenderId, factory) == clone;
    }

    /// @dev True when `vault`'s engine supports exact withdrawals, which every Earn spend makes,
    ///      and redeem previews, which `availableBalance` uses to value shares.
    function supportsEarnSpend(address vault) internal view returns (bool) {
        (bool ok, address engine) = readAddress(vault, bytes4(keccak256("engine()")));
        return ok && ERC165Checker.supportsInterface(engine, type(IEarnEngineExactWithdraw).interfaceId)
            && ERC165Checker.supportsInterface(engine, type(IEarnEngineRedeem).interfaceId);
    }

    /// @dev A low-level read, since `try` reverts on return data it cannot decode. False unless the
    ///      call returns a whole word holding an address.
    function readAddress(address target, bytes4 selector) internal view returns (bool ok, address value) {
        if (target.code.length == 0) return (false, address(0));
        (bool success, bytes memory data) = target.staticcall(abi.encodePacked(selector));
        if (!success || data.length < 32) return (false, address(0));
        uint256 word = abi.decode(data, (uint256));
        if (word >> 160 != 0) return (false, address(0));
        return (true, address(uint160(word)));
    }

    /// @dev True when `a` and `b` run the same code. Solc appends a CBOR metadata blob, sized by the
    ///      code's last two bytes, that hashes the source text, so comments alone would differ.
    function sameLogic(address a, address b) internal view returns (bool) {
        return keccak256(_withoutMetadata(a.code)) == keccak256(_withoutMetadata(b.code));
    }

    function _withoutMetadata(bytes memory code) private pure returns (bytes memory) {
        if (code.length < 2) return code;
        uint256 metadata = (uint256(uint8(code[code.length - 2])) << 8) | uint256(uint8(code[code.length - 1]));
        if (metadata + 2 > code.length) return code;
        uint256 logic = code.length - metadata - 2;
        assembly {
            mstore(code, logic)
        }
        return code;
    }

    /// @dev Reads ZONE_ID, which must fit the Zone factory's `uint32` IDs and is never zero.
    function zoneId(uint256 raw) internal pure returns (uint32) {
        require(raw != 0 && raw <= type(uint32).max, "ZONE_ID out of range");
        return uint32(raw);
    }
}
