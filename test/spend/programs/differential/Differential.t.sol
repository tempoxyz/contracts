// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import {
    IReservationCore,
    RESERVATION_CORE_ADDRESS
} from "../../../../src/interfaces/spend/programs/IReservationCore.sol";
import { CoreInvariants } from "./CoreInvariants.sol";
import { StateReader } from "./StateReader.sol";

/// @notice Replays operation traces recorded on a Tempo dev node (scripts/differential in tempoxyz/cards) against
///         MockReservationCore, requiring the same outcome, revert data, core events and full state after every
///         operation, and checks the core's invariants on both.
/// @dev Regenerate the traces with `pnpm differential --cards <this checkout>/cards --node` from the harness.
contract DifferentialTest is CoreInvariants {
    string internal constant TRACES = "test/spend/programs/differential/traces";

    struct EncodedOp {
        uint256 head;
        bytes data;
        bytes ret;
        bytes32[][] topics;
        bytes[] logData;
        /// @dev Changed state entries, each its index shifted left 240 bits over its value.
        uint256[] diff;
    }

    function setUp() public {
        _deployModel();
        reader = new StateReader();
    }

    /// @dev How often the replayed traces reached each core call's success path, each core error and listed events,
    ///      beside the least each must reach.
    struct Coverage {
        bytes4[] calls;
        uint256[] callOk;
        uint256[] callLeast;
        bytes4[] errors;
        uint256[] errorHits;
        uint256[] errorLeast;
        bytes32[] events;
        uint256[] eventHits;
        uint256[] eventLeast;
    }

    /// @notice Every committed trace replays identically on the model, and together they reach every core call's success
    ///         path and every core error at least as often as the generator requires.
    function test_replayTraces() public {
        // Replaying thousands of operations exceeds any block gas limit; gas is not what this test measures.
        vm.pauseGasMetering();
        Vm.DirEntry[] memory entries = vm.readDir(TRACES);
        Coverage memory c = _coverage();
        uint256 replayed;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || !vm.contains(entries[i].path, ".json")) continue;
            uint256 snapshot = vm.snapshotState();
            replayed += _replay(entries[i].path, c);
            vm.revertToState(snapshot);
        }
        assertGt(replayed, 0, "no traces");
        emit log_named_uint("operations compared", replayed);
        _assertCoverage(c);
    }

    /// @dev The minimums scripts/differential/run.ts (tempoxyz/cards) enforces on a run, kept in step with it.
    function _coverage() internal pure returns (Coverage memory c) {
        c.calls = new bytes4[](13);
        c.callLeast = new uint256[](13);
        (c.calls[0], c.callLeast[0]) = (IReservationCore.adjust.selector, 10);
        (c.calls[1], c.callLeast[1]) = (IReservationCore.approveHolder.selector, 20);
        (c.calls[2], c.callLeast[2]) = (IReservationCore.capture.selector, 20);
        (c.calls[3], c.callLeast[3]) = (IReservationCore.charge.selector, 30);
        (c.calls[4], c.callLeast[4]) = (IReservationCore.hold.selector, 20);
        (c.calls[5], c.callLeast[5]) = (IReservationCore.holdFrom.selector, 15);
        (c.calls[6], c.callLeast[6]) = (IReservationCore.lien.selector, 5);
        (c.calls[7], c.callLeast[7]) = (IReservationCore.pledge.selector, 5);
        (c.calls[8], c.callLeast[8]) = (IReservationCore.pledgeFrom.selector, 5);
        (c.calls[9], c.callLeast[9]) = (IReservationCore.refund.selector, 20);
        (c.calls[10], c.callLeast[10]) = (IReservationCore.release.selector, 10);
        (c.calls[11], c.callLeast[11]) = (IReservationCore.releaseExpired.selector, 10);
        (c.calls[12], c.callLeast[12]) = (IReservationCore.setCaptureTolerance.selector, 20);
        c.callOk = new uint256[](13);
        c.errors = new bytes4[](11);
        c.errorLeast = new uint256[](11);
        (c.errors[0], c.errorLeast[0]) = (IReservationCore.BudgetExceeded.selector, 2);
        (c.errors[1], c.errorLeast[1]) = (IReservationCore.CaptureLimitExceeded.selector, 2);
        (c.errors[2], c.errorLeast[2]) = (IReservationCore.HoldExists.selector, 2);
        (c.errors[3], c.errorLeast[3]) = (IReservationCore.HoldExpired.selector, 3);
        (c.errors[4], c.errorLeast[4]) = (IReservationCore.HoldNotExpired.selector, 3);
        (c.errors[5], c.errorLeast[5]) = (IReservationCore.HoldNotFound.selector, 3);
        (c.errors[6], c.errorLeast[6]) = (IReservationCore.InsufficientAvailable.selector, 3);
        (c.errors[7], c.errorLeast[7]) = (IReservationCore.InvalidAmount.selector, 3);
        (c.errors[8], c.errorLeast[8]) = (IReservationCore.InvalidExpiry.selector, 3);
        (c.errors[9], c.errorLeast[9]) = (IReservationCore.PolicyForbids.selector, 3);
        (c.errors[10], c.errorLeast[10]) = (IReservationCore.Unauthorized.selector, 3);
        c.errorHits = new uint256[](11);
        c.events = new bytes32[](0);
        c.eventLeast = new uint256[](0);
        c.eventHits = new uint256[](0);
    }

    function _tally(Coverage memory c, Op memory op) internal pure {
        for (uint256 i; i < op.topics.length; ++i) {
            for (uint256 j; j < c.events.length; ++j) {
                if (op.topics[i].length != 0 && op.topics[i][0] == c.events[j]) ++c.eventHits[j];
            }
        }
        if (op.kind != KIND_CORE) return;
        if (op.ok) {
            bytes4 selector = bytes4(op.data);
            for (uint256 j; j < c.calls.length; ++j) {
                if (c.calls[j] == selector) ++c.callOk[j];
            }
            return;
        }
        if (op.ret.length < 4) return;
        bytes4 error = bytes4(op.ret);
        for (uint256 j; j < c.errors.length; ++j) {
            if (c.errors[j] == error) ++c.errorHits[j];
        }
    }

    function _assertCoverage(Coverage memory c) internal pure {
        for (uint256 j; j < c.calls.length; ++j) {
            assertGe(
                c.callOk[j],
                c.callLeast[j],
                string.concat("successful calls of ", vm.toString(abi.encodePacked(c.calls[j])))
            );
        }
        for (uint256 j; j < c.errors.length; ++j) {
            assertGe(
                c.errorHits[j],
                c.errorLeast[j],
                string.concat("reverts with ", vm.toString(abi.encodePacked(c.errors[j])))
            );
        }
        for (uint256 j; j < c.events.length; ++j) {
            assertGe(c.eventHits[j], c.eventLeast[j], string.concat("events ", vm.toString(c.events[j])));
        }
    }

    function _replay(string memory file, Coverage memory c) internal returns (uint256) {
        string memory json = vm.readFile(file);
        assertEq(vm.parseJsonStringArray(json, ".nodeInvariantFailures").length, 0, "node invariant failures recorded");
        // A trace names the node commit it was recorded on, so a drift can be traced to a node change.
        assertEq(bytes(vm.parseJsonString(json, ".node.commit")).length, 40, "trace records its node commit");
        Trace memory t = _setup(file, json);
        bytes[] memory ops = vm.parseJsonBytesArray(json, ".ops");
        string[] memory labels = vm.parseJsonStringArray(json, ".labels");
        for (uint256 n; n < ops.length; ++n) {
            // Each step's scratch memory is freed after it; only the expected state carries over, updated in place.
            uint256 free;
            assembly ("memory-safe") {
                free := mload(0x40)
            }
            Op memory op = _unpack(abi.decode(ops[n], (EncodedOp)));
            _step(t, op, labels[n]);
            _tally(c, op);
            assembly ("memory-safe") {
                mstore(0x40, free)
            }
        }
        return ops.length;
    }

    function _unpack(EncodedOp memory e) internal pure returns (Op memory) {
        return Op({
            kind: uint8(e.head >> 248),
            caller: address(uint160(e.head)),
            ts: uint64(e.head >> 160),
            ok: (e.head >> 240) & 1 == 1,
            data: e.data,
            ret: e.ret,
            topics: e.topics,
            logData: e.logData,
            diff: e.diff
        });
    }

    function _setup(string memory file, string memory json) internal returns (Trace memory t) {
        t.file = file;
        t.admin = vm.parseJsonAddress(json, ".admin");
        t.accounts = vm.parseJsonAddressArray(json, ".accounts");
        t.ids = vm.parseJsonBytes32Array(json, ".ids");
        t.expected = new uint256[](vm.parseJsonUint(json, ".vectorLength"));
        uint256 count = _count(json);
        t.tokens = new address[](count);
        for (uint256 i; i < count; ++i) {
            string memory at = string.concat(".tokens[", vm.toString(i), "]");
            vm.startPrank(t.admin);
            ITIP20Token token = ITIP20Token(
                StdPrecompiles.TIP20_FACTORY
                    .createToken(
                        vm.parseJsonString(json, string.concat(at, ".name")),
                        vm.parseJsonString(json, string.concat(at, ".symbol")),
                        "USD",
                        ITIP20(PATH_USD),
                        t.admin,
                        vm.parseJsonBytes32(json, string.concat(at, ".salt"))
                    )
            );
            assertEq(address(token), vm.parseJsonAddress(json, string.concat(at, ".address")), "token address");
            token.grantRole(token.ISSUER_ROLE(), t.admin);
            token.grantRole(token.PAUSE_ROLE(), t.admin);
            token.grantRole(token.UNPAUSE_ROLE(), t.admin);
            token.changeTransferPolicyId(registry.createPolicy(t.admin, ITIP403Registry.PolicyType.BLACKLIST));
            vm.stopPrank();
            t.tokens[i] = address(token);
        }
    }

    function _count(string memory json) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(".tokens[", vm.toString(n), "]"))) {
            ++n;
        }
    }

    function _step(Trace memory t, Op memory op, string memory label) internal {
        uint256[] memory before = _copy(t.expected);
        vm.warp(op.ts);
        vm.recordLogs();
        (bool ok, bytes memory ret) = _execute(op);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        string memory at = string.concat(t.file, " op ", label);

        assertEq(ok, op.ok, string.concat(at, ": outcome"));
        if (op.kind == KIND_CORE) assertEq(ret, op.ret, string.concat(at, ": revert data"));
        // vm.getRecordedLogs keeps logs from reverted frames; a reverted transaction on the node emits none.
        if (ok) _compareLogs(logs, op, at);
        else assertEq(op.topics.length, 0, string.concat(at, ": events from a reverted call"));

        for (uint256 i; i < op.diff.length; ++i) {
            t.expected[op.diff[i] >> 240] = op.diff[i] & ((1 << 240) - 1);
        }
        uint256[] memory actual = reader.snapshot(t.accounts, t.tokens, t.ids);
        assertEq(actual.length, t.expected.length, string.concat(at, ": state length"));
        for (uint256 i; i < actual.length; ++i) {
            if (actual[i] != t.expected[i]) {
                assertEq(actual[i], t.expected[i], string.concat(at, ": state[", vm.toString(i), "] ", _name(t, i)));
            }
        }
        _invariants(t, op, before, at);
    }

    function _compareLogs(Vm.Log[] memory logs, Op memory op, string memory at) internal pure {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != RESERVATION_CORE_ADDRESS) continue;
            assertLt(n, op.topics.length, string.concat(at, ": extra core event"));
            assertEq(logs[i].topics, op.topics[n], string.concat(at, ": event topics ", vm.toString(n)));
            assertEq(logs[i].data, op.logData[n], string.concat(at, ": event data ", vm.toString(n)));
            ++n;
        }
        assertEq(n, op.topics.length, string.concat(at, ": core event count"));
    }

    // Invariants, checked on the node's recorded state (which the model now matches) and the model's balances.
}
