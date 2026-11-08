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
        // Preserve every other byte, including the INVALID delimiter, solc version and CBOR lengths.
        if (!_normalize(expected) || !_normalize(runtime)) return false;
        return keccak256(runtime) == keccak256(expected);
    }

    function _normalize(bytes memory runtime) private pure returns (bool) {
        if (runtime.length < 107) return false;
        uint256 start = runtime.length - 106;
        if (runtime[start - 1] != 0xfe) return false;
        for (uint256 i; i < 2; ++i) {
            uint256 offset = start + i * 53;
            bytes10 prefix;
            bytes6 compilerKey;
            assembly ("memory-safe") {
                prefix := mload(add(add(runtime, 32), offset))
                // Read the trailer's final 32 bytes so the load never extends beyond the bytes allocation.
                compilerKey := shl(168, mload(add(add(runtime, 53), offset)))
            }
            if (
                prefix != hex"a2646970667358221220" || compilerKey != hex"64736f6c6343" || runtime[offset + 51] != 0x00
                    || runtime[offset + 52] != 0x33
            ) return false;
            // Only the 32-byte IPFS multihash digest is mutable; the multihash type stays checked.
            assembly ("memory-safe") {
                mstore(add(add(runtime, 42), offset), 0)
            }
        }
        return true;
    }
}
