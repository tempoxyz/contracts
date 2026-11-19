// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";

import { Conversion } from "../../../src/programs/Conversion.sol";

/// @notice Sets a Conversion's reference rate the way its owner must: at once when the move fits in one step, else
///         scheduled and set once the delay has passed (warping past it).
library Rates {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function set(Conversion conv, address token, uint256 rate) internal {
        try conv.setReferenceRate(token, rate) { }
        catch {
            conv.scheduleReferenceRate(token, rate);
            VM.warp(VM.getBlockTimestamp() + conv.RATE_DELAY());
            conv.setReferenceRate(token, rate);
        }
    }
}
