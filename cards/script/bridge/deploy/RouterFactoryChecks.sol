// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ZoneRouterFactory } from "zone-router/ZoneRouterFactory.sol";

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

    /// @dev Each of the two trailers is solar's CBOR map `{ipfs: <34-byte multihash>, solar: <3-byte version>}`
    ///      followed by its 2-byte length (0x0034), 54 bytes in all; an INVALID byte precedes each.
    function _normalize(bytes memory runtime) private pure returns (bool) {
        if (runtime.length < 110) return false;
        uint256 start = runtime.length - 109;
        if (runtime[start - 1] != 0xfe || runtime[start + 54] != 0xfe) return false;
        for (uint256 i; i < 2; ++i) {
            uint256 offset = start + i * 55;
            bytes10 prefix;
            bytes6 compilerKey;
            assembly ("memory-safe") {
                prefix := mload(add(add(runtime, 32), offset))
                // Read the trailer's final 32 bytes so the load never extends beyond the bytes allocation.
                compilerKey := shl(160, mload(add(add(runtime, 54), offset)))
            }
            if (
                prefix != hex"a2646970667358221220" || compilerKey != hex"65736f6c6172" || runtime[offset + 48] != 0x43
                    || runtime[offset + 52] != 0x00 || runtime[offset + 53] != 0x34
            ) return false;
            // Only the 32-byte IPFS multihash digest is mutable; the multihash type stays checked.
            assembly ("memory-safe") {
                mstore(add(add(runtime, 42), offset), 0)
            }
        }
        return true;
    }
}
