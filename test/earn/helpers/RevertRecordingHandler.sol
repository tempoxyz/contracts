// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Test } from "forge-std/Test.sol";

/// @dev Invariant runs discard handler reverts (`fail_on_revert` is off), so a handler catches each call: an
///      error its action expects is rethrown, rolling back the action as before, and any other is recorded
///      without reverting, so the record survives for an invariant to fail on.
abstract contract RevertRecordingHandler is Test {
    /// @dev Whether a call reverted with an error its action does not expect, and the first such reason.
    bool public revertedUnexpectedly;
    bytes public unexpectedRevertReason;

    function _expectOnly(bytes memory reason) internal {
        _expectOnly(reason, bytes4(0), bytes4(0), bytes4(0), bytes4(0));
    }

    function _expectOnly(bytes memory reason, bytes4 first) internal {
        _expectOnly(reason, first, bytes4(0), bytes4(0), bytes4(0));
    }

    function _expectOnly(bytes memory reason, bytes4 first, bytes4 second) internal {
        _expectOnly(reason, first, second, bytes4(0), bytes4(0));
    }

    function _expectOnly(bytes memory reason, bytes4 first, bytes4 second, bytes4 third) internal {
        _expectOnly(reason, first, second, third, bytes4(0));
    }

    /// @dev Rethrows `reason` if it is one of the expected errors, and records it otherwise; a zero selector
    ///      expects nothing.
    function _expectOnly(bytes memory reason, bytes4 first, bytes4 second, bytes4 third, bytes4 fourth) internal {
        bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0);
        if (
            selector != bytes4(0)
                && (selector == first || selector == second || selector == third || selector == fourth)
        ) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        if (revertedUnexpectedly) return;
        revertedUnexpectedly = true;
        unexpectedRevertReason = reason;
    }
}
