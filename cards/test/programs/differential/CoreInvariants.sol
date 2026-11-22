// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ITIP20, ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP20RolesAuth } from "tempo-std/interfaces/ITIP20RolesAuth.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import {
    IReservationCore,
    KIND_HOLD,
    RESERVATION_CORE_ADDRESS
} from "../../../src/programs/interfaces/IReservationCore.sol";
import { ModelEnv } from "./ModelEnv.sol";
import { StateReader } from "./StateReader.sol";

/// @notice Operations over the reservation core model and the invariants checked after each one, shared by the trace
///         replay (Differential.t.sol) and the node-free randomized run (ModelRandom.t.sol). State is StateReader's
///         vector over a fixed universe of accounts, tokens and hold ids.
abstract contract CoreInvariants is ModelEnv {
    uint8 internal constant KIND_CORE = 0;
    uint8 internal constant KIND_MINT = 1;
    uint8 internal constant KIND_TRANSFER = 2;
    uint8 internal constant KIND_BLACKLIST = 3;
    uint8 internal constant KIND_PAUSE = 4;
    uint8 internal constant KIND_LIEN_ROLE = 5;

    StateReader internal reader;

    struct Trace {
        string file;
        address admin;
        address[] accounts;
        address[] tokens;
        bytes32[] ids;
        uint256[] expected;
    }

    /// @dev An operation as the trace encodes it, after unpacking its head word.
    struct Op {
        uint8 kind;
        address caller;
        uint64 ts;
        bool ok;
        bytes data;
        bytes ret;
        bytes32[][] topics;
        bytes[] logData;
        uint256[] diff;
    }

    /// @dev The encoded form: the head word packs kind (bits 248+), ok (240), block time (160) and sender.
    function _execute(Op memory op) internal returns (bool ok, bytes memory ret) {
        if (op.kind == KIND_CORE) {
            vm.prank(op.caller);
            return RESERVATION_CORE_ADDRESS.call(op.data);
        }
        if (op.kind == KIND_MINT || op.kind == KIND_TRANSFER) {
            (address token, address to, uint256 amount) = abi.decode(op.data, (address, address, uint256));
            vm.prank(op.caller);
            (ok, ret) = op.kind == KIND_MINT
                ? token.call(abi.encodeCall(ITIP20.mint, (to, amount)))
                : token.call(abi.encodeCall(ITIP20.transfer, (to, amount)));
            return (ok, ret);
        }
        if (op.kind == KIND_PAUSE) {
            (address token, bool on) = abi.decode(op.data, (address, bool));
            vm.prank(op.caller);
            return token.call(on ? abi.encodeCall(ITIP20.pause, ()) : abi.encodeCall(ITIP20.unpause, ()));
        }
        (address token_, address account, bool on_) = abi.decode(op.data, (address, address, bool));
        if (op.kind == KIND_BLACKLIST) {
            uint64 policy = ITIP20Token(token_).transferPolicyId();
            vm.prank(op.caller);
            return address(registry).call(abi.encodeCall(ITIP403Registry.modifyPolicyBlacklist, (policy, account, on_)));
        }
        bytes32 role = core.LIEN_ROLE();
        vm.prank(op.caller);
        return token_.call(
            on_
                ? abi.encodeCall(ITIP20RolesAuth.grantRole, (role, account))
                : abi.encodeCall(ITIP20RolesAuth.revokeRole, (role, account))
        );
    }

    function _invariants(Trace memory t, Op memory op, uint256[] memory before, string memory at) internal view {
        uint256[] memory s = t.expected;
        uint256 a = t.accounts.length;
        for (uint256 k; k < t.tokens.length; ++k) {
            uint256 sum;
            uint256 reservedSum;
            for (uint256 j; j < a; ++j) {
                uint256 avail = s[_iAvailable(t, k, j)];
                sum += avail + s[_iAvailable(t, k, j) + 1];
                reservedSum += s[_iAvailable(t, k, j) + 1];
                // available = balance - reserved: the model keeps reserved amounts in the core's own balance.
                assertEq(ITIP20Token(t.tokens[k]).balanceOf(t.accounts[j]), avail, string.concat(at, ": available"));
            }
            assertEq(sum, s[_iSupply(t, k)], string.concat(at, ": balances + reserved = supply"));
            assertEq(core.totalReserved(t.tokens[k]), reservedSum, string.concat(at, ": total reserved"));
            assertEq(ITIP20Token(t.tokens[k]).balanceOf(RESERVATION_CORE_ADDRESS), reservedSum, at);
        }
        for (uint256 o; o < a; ++o) {
            for (uint256 h; h < a; ++h) {
                for (uint256 k; k < t.tokens.length; ++k) {
                    uint256 i = _iPair(t, o, h, k);
                    // A budget never admits past its limit (a later lower limit can leave older use above it).
                    if (s[i + 1] + s[i + 2] > before[i + 1] + before[i + 2]) {
                        assertLe(s[i + 1] + s[i + 2], s[i], string.concat(at, ": budget spent + outstanding <= limit"));
                    }
                }
            }
            // A live hold never reserves more than its captures may still pay.
            for (uint256 p; p < a; ++p) {
                for (uint256 d; d < t.ids.length; ++d) {
                    uint256 r = _iHold(t, o, p, t.ids[d]);
                    if (s[r + 5] == KIND_HOLD) {
                        assertLe(s[r + 2], s[r + 3], string.concat(at, ": held <= capture limit"));
                    }
                }
            }
        }
        if (op.kind == KIND_CORE) _callInvariants(t, op, before, at);
    }

    function _callInvariants(Trace memory t, Op memory op, uint256[] memory before, string memory at) internal view {
        uint32 selector = _selector(op.data);
        bytes memory args = _args(op.data);
        if (selector == uint32(IReservationCore.hold.selector)) {
            IReservationCore.HoldRequest memory request = abi.decode(args, (IReservationCore.HoldRequest));
            _placement(t, op, before, op.caller, op.caller, request.id, request.token, request.amount, at);
        } else if (selector == uint32(IReservationCore.holdFrom.selector)) {
            (address owner, IReservationCore.HoldRequest memory request) =
                abi.decode(args, (address, IReservationCore.HoldRequest));
            _placement(t, op, before, owner, op.caller, request.id, request.token, request.amount, at);
        } else if (selector == uint32(IReservationCore.pledge.selector)) {
            (, address token, bytes32 id, uint128 amount,) =
                abi.decode(args, (address, address, bytes32, uint128, uint64));
            _placement(t, op, before, op.caller, op.caller, id, token, amount, at);
        } else if (
            selector == uint32(IReservationCore.pledgeFrom.selector)
                || selector == uint32(IReservationCore.lien.selector)
        ) {
            (address owner, address token, bytes32 id, uint128 amount,) =
                abi.decode(args, (address, address, bytes32, uint128, uint64));
            _placement(t, op, before, owner, op.caller, id, token, amount, at);
        } else if (selector == uint32(IReservationCore.refund.selector) && op.ok) {
            (, address token,,, uint128 amount) = abi.decode(args, (address, address, address, bytes32, uint128));
            uint256 i = _iAvailable(t, _tokenIndex(t, token), _accountIndex(t, op.caller));
            // A refund costs its caller exactly the amount: nothing is forgiven.
            assertEq(before[i] - t.expected[i], amount, string.concat(at, ": refund paid by caller"));
        } else if (selector == uint32(IReservationCore.charge.selector) && op.ok) {
            (address owner, address token,, uint128 amount,) =
                abi.decode(args, (address, address, bytes32, uint128, address));
            uint256 o = _accountIndex(t, owner);
            if (o == type(uint256).max) return;
            uint256 i = _iAvailable(t, _tokenIndex(t, token), o);
            // A charge pays exactly the amount, all of it from the owner's free balance.
            assertEq(before[i] - t.expected[i], amount, string.concat(at, ": charge paid from free balance"));
        }
    }

    /// @dev A key holding a record cannot be placed again until settlement deletes it; every placement is backed in
    ///      full, so it needs that much available, and one refused for lack of it had less.
    function _placement(
        Trace memory t,
        Op memory op,
        uint256[] memory before,
        address owner,
        address placer,
        bytes32 id,
        address token,
        uint128 amount,
        string memory at
    ) internal view {
        uint256 o = _accountIndex(t, owner);
        uint256 p = _accountIndex(t, placer);
        uint256 k = _maybeTokenIndex(t, token);
        if (o == type(uint256).max || p == type(uint256).max) return;
        uint256 key = _iHold(t, o, p, id);
        if (before[key] != 0) assertFalse(op.ok, string.concat(at, ": placed over a live record"));
        if (k == type(uint256).max) return;
        uint256 avail = before[_iAvailable(t, k, o)];
        if (op.ok) assertLe(amount, avail, string.concat(at, ": backed in full"));
        if (!op.ok && _selector(op.ret) == uint32(IReservationCore.InsufficientAvailable.selector)) {
            assertGt(amount, avail, string.concat(at, ": refused with enough available"));
        }
    }

    // State vector layout (StateReader.snapshot).

    function _iSupply(Trace memory t, uint256 k) internal pure returns (uint256) {
        return 1 + k * (1 + 2 * t.accounts.length);
    }

    function _iAvailable(Trace memory t, uint256 k, uint256 j) internal pure returns (uint256) {
        return _iSupply(t, k) + 1 + 2 * j;
    }

    function _iPair(Trace memory t, uint256 o, uint256 h, uint256 k) internal pure returns (uint256) {
        uint256 a = t.accounts.length;
        return 1 + t.tokens.length * (1 + 2 * a) + ((o * a + h) * t.tokens.length + k) * 6;
    }

    function _iHold(Trace memory t, uint256 o, uint256 p, bytes32 id) internal pure returns (uint256) {
        uint256 a = t.accounts.length;
        uint256 k;
        while (t.ids[k] != id) {
            ++k;
        }
        return _iPair(t, a, 0, 0) + ((o * a + p) * t.ids.length + k) * 6;
    }

    function _name(Trace memory t, uint256 i) internal pure returns (string memory) {
        if (i == 0) return "time";
        if (i < _iPair(t, 0, 0, 0)) return "supply/available/reserved";
        if (i < _iPair(t, t.accounts.length, 0, 0)) return "budget/captureTolerance";
        return "getHold";
    }

    function _accountIndex(Trace memory t, address account) internal pure returns (uint256) {
        for (uint256 i; i < t.accounts.length; ++i) {
            if (t.accounts[i] == account) return i;
        }
        return type(uint256).max;
    }

    function _tokenIndex(Trace memory t, address token) internal pure returns (uint256 k) {
        k = _maybeTokenIndex(t, token);
        require(k != type(uint256).max, "unknown token");
    }

    function _maybeTokenIndex(Trace memory t, address token) internal pure returns (uint256) {
        for (uint256 i; i < t.tokens.length; ++i) {
            if (t.tokens[i] == token) return i;
        }
        return type(uint256).max;
    }

    /// @dev The first four bytes, or zero for shorter data.
    function _selector(bytes memory data) internal pure returns (uint32 out) {
        if (data.length < 4) return 0;
        assembly ("memory-safe") {
            out := shr(224, mload(add(data, 32)))
        }
    }

    function _args(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    function _copy(uint256[] memory v) internal pure returns (uint256[] memory out) {
        out = new uint256[](v.length);
        for (uint256 i; i < v.length; ++i) {
            out[i] = v[i];
        }
    }
}
