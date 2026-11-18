// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";
import { StdPrecompiles } from "tempo-std/StdPrecompiles.sol";
import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import {
    IReservationCore,
    MAX_CREDITORS,
    RESERVATION_CORE_ADDRESS
} from "../../../src/programs/interfaces/IReservationCore.sol";
import { CoreInvariants } from "./CoreInvariants.sol";
import { StateReader } from "./StateReader.sol";

/// @notice Replays operation traces recorded on a Tempo dev node (scripts/differential in tempoxyz/cards) against
///         MockReservationCore, requiring the same outcome, revert data, core events and full state after every
///         operation, and checks the core's invariants on both.
/// @notice Replays operation traces recorded on a Tempo dev node (scripts/differential in tempoxyz/cards) against
///         MockReservationCore, requiring the same outcome, revert data, core events and full state after every
///         operation, and checks the core's invariants on both.
/// @dev Regenerate the traces with `pnpm differential --cards <this checkout>/cards --node` from the harness.
contract DifferentialTest is CoreInvariants {
    string internal constant TRACES = "test/programs/differential/traces";

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

    /// @notice Every committed trace replays identically on the model.
    function test_replayTraces() public {
        // Replaying thousands of operations exceeds any block gas limit; gas is not what this test measures.
        vm.pauseGasMetering();
        Vm.DirEntry[] memory entries = vm.readDir(TRACES);
        uint256 replayed;
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || !vm.contains(entries[i].path, ".json")) continue;
            uint256 snapshot = vm.snapshotState();
            replayed += _replay(entries[i].path);
            vm.revertToState(snapshot);
        }
        assertGt(replayed, 0, "no traces");
        emit log_named_uint("operations compared", replayed);
    }

    function _replay(string memory file) internal returns (uint256) {
        string memory json = vm.readFile(file);
        assertEq(vm.parseJsonStringArray(json, ".nodeInvariantFailures").length, 0, "node invariant failures recorded");
        Trace memory t = _setup(file, json);
        bytes[] memory ops = vm.parseJsonBytesArray(json, ".ops");
        string[] memory labels = vm.parseJsonStringArray(json, ".labels");
        for (uint256 n; n < ops.length; ++n) {
            // Each step's scratch memory is freed after it; only the expected state carries over, updated in place.
            uint256 free;
            assembly ("memory-safe") {
                free := mload(0x40)
            }
            _step(t, _unpack(abi.decode(ops[n], (EncodedOp))), labels[n]);
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
