// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ZoneRouterFactory } from "../../../../src/zone/ZoneRouterFactory.sol";

/// @notice Admits the current router factory before creating an immutable card program.
library RouterFactoryChecks {
    function check(address factory) internal view {
        require(factory != address(0), "ROUTER_FACTORY unset");
        bytes memory runtime = factory.code;
        require(runtime.length != 0, "ROUTER_FACTORY has no code");
        require(matches(runtime), "ROUTER_FACTORY runtime mismatch");
    }

    /// @dev The canonical Zone router build and cards build differ only in terminal IPFS digests.
    ///      Never search executable bytes or admit a factory by its self-reported getters.
    function matches(bytes memory runtime) internal pure returns (bool) {
        bytes memory expected = type(ZoneRouterFactory).runtimeCode;
        if (runtime.length != expected.length) return false;
        // Both compiler outputs must end in exactly the router and factory's recognized CBOR trailers.
        // Preserve every other byte, including the INVALID delimiter, solar version and CBOR lengths.
        if (!_normalize(expected) || !_normalize(runtime)) return false;
        return keccak256(runtime) == keccak256(expected);
    }

    /// @dev Each of the two trailers is solar's CBOR map `{ipfs: <34-byte multihash>, solar: <version>}` followed
    ///      by its 2-byte length; an INVALID byte precedes each. The version is a CBOR byte or text string (a
    ///      release encodes it differently from a development build), and both trailers must have one layout.
    function _normalize(bytes memory runtime) private pure returns (bool) {
        if (runtime.length < 2) return false;
        uint256 size = 2 + (uint256(uint8(runtime[runtime.length - 2])) << 8 | uint8(runtime[runtime.length - 1]));
        // Prefix, digest and key take 48 bytes; the version item at least one more.
        if (size < 51 || runtime.length < 2 * size + 2) return false;
        uint256 start = runtime.length - (2 * size + 1);
        if (runtime[start - 1] != 0xfe || runtime[start + size] != 0xfe) return false;
        for (uint256 i; i < 2; ++i) {
            uint256 offset = start + i * (size + 1);
            bytes10 prefix;
            bytes6 compilerKey;
            assembly ("memory-safe") {
                prefix := mload(add(add(runtime, 32), offset))
                // Bytes [offset + 22, offset + 54) always lie inside this trailer, so the load stays in bounds.
                compilerKey := shl(160, mload(add(add(runtime, 54), offset)))
            }
            if (prefix != hex"a2646970667358221220" || compilerKey != hex"65736f6c6172") return false;
            if (_versionItemLength(runtime, offset + 48) != size - 50) return false;
            if (runtime[offset + size - 2] != runtime[runtime.length - 2]) return false;
            if (runtime[offset + size - 1] != runtime[runtime.length - 1]) return false;
            // Only the 32-byte IPFS multihash digest is mutable; the multihash type stays checked.
            assembly ("memory-safe") {
                mstore(add(add(runtime, 42), offset), 0)
            }
        }
        return true;
    }

    /// @dev The encoded length of the CBOR byte or text string at `at`, or zero for any other item.
    function _versionItemLength(bytes memory runtime, uint256 at) private pure returns (uint256) {
        uint8 head = uint8(runtime[at]);
        uint8 major = head & 0xe0;
        if (major != 0x40 && major != 0x60) return 0;
        uint8 info = head & 0x1f;
        if (info < 24) return 1 + info;
        if (info == 24) return 2 + uint8(runtime[at + 1]);
        return 0;
    }
}
