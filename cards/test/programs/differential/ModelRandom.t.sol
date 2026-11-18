// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Vm } from "forge-std/Vm.sol";
import { ITIP20Token } from "tempo-std/interfaces/ITIP20.sol";
import { ITIP403Registry } from "tempo-std/interfaces/ITIP403Registry.sol";

import { IReservationCore } from "../../../src/programs/interfaces/IReservationCore.sol";
import { CoreInvariants } from "./CoreInvariants.sol";
import { StateReader } from "./StateReader.sol";

/// @notice Seeded random operation sequences against MockReservationCore alone, checking the core invariants after every
///         operation. A fast, node-free companion to the trace replay; it mirrors scripts/differential/Generator.ts.
contract ModelRandomTest is CoreInvariants {
    uint256 internal constant OPS = 150;
    uint256 internal constant U64 = type(uint64).max;

    Trace internal t;
    uint256 internal rng;
    bool[2] internal paused;
    mapping(uint256 token => mapping(uint256 account => bool)) internal listed;
    mapping(uint256 token => mapping(uint256 account => bool)) internal lienHolder;

    function setUp() public {
        vm.warp(1_800_000_000);
        _deployModel();
        reader = new StateReader();
        t.admin = address(this);
        for (uint256 i; i < 5; ++i) {
            t.accounts.push(makeAddr(string.concat("account", vm.toString(i))));
        }
        for (uint256 i; i < 2; ++i) {
            ITIP20Token token = _token(string.concat("RND", vm.toString(i)));
            token.changeTransferPolicyId(registry.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST));
            t.tokens.push(address(token));
        }
        for (uint256 i; i < 3; ++i) {
            t.ids.push(keccak256(abi.encode("hold", i)));
        }
    }

    function test_seed1() public {
        _run(1);
    }

    function test_seed2() public {
        _run(2);
    }

    function test_seed3() public {
        _run(3);
    }

    function test_seed4() public {
        _run(4);
    }

    /// forge-config: default.fuzz.runs = 16
    function testFuzz_randomOps(uint256 seed) public {
        _run(seed);
    }

    function _run(uint256 seed) internal {
        vm.pauseGasMetering();
        rng = seed;
        paused = [false, false];
        Trace memory m = t;
        m.expected = reader.snapshot(m.accounts, m.tokens, m.ids);
        for (uint256 a; a < 4; ++a) {
            for (uint256 k; k < 2; ++k) {
                _mint(ITIP20Token(m.tokens[k]), m.accounts[a], 10_000 + _below(200_000));
            }
        }
        m.expected = reader.snapshot(m.accounts, m.tokens, m.ids);
        // Two state buffers reused across operations; each operation's scratch memory is freed after it.
        uint256[] memory before = _copy(m.expected);
        for (uint256 n; n < OPS; ++n) {
            uint256 free;
            assembly ("memory-safe") {
                free := mload(0x40)
            }
            for (uint256 i; i < before.length; ++i) {
                before[i] = m.expected[i];
            }
            if (_chance(30)) vm.warp(_nextTime(m.expected));
            Op memory op = _op(m);
            vm.recordLogs();
            (op.ok, op.ret) = _execute(op);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 count;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter == address(core)) ++count;
            }
            op.topics = new bytes32[][](count);
            op.logData = new bytes[](count);
            count = 0;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter != address(core)) continue;
                op.topics[count] = logs[i].topics;
                op.logData[count++] = logs[i].data;
            }
            uint256[] memory next = reader.snapshot(m.accounts, m.tokens, m.ids);
            for (uint256 i; i < next.length; ++i) {
                m.expected[i] = next[i];
            }
            _invariants(m, op, before, string.concat("seed ", vm.toString(seed), " op ", vm.toString(n)));
            assembly ("memory-safe") {
                mstore(0x40, free)
            }
        }
    }

    function _op(Trace memory m) internal returns (Op memory op) {
        uint256 roll = _below(100);
        uint256 k = _below(2);
        address token = m.tokens[k];
        if (roll < 6) {
            op.kind = KIND_MINT;
            op.caller = address(this);
            op.data = abi.encode(token, m.accounts[_below(4)], 1 + _below(100_000));
            return op;
        }
        if (roll < 9) {
            op.kind = KIND_TRANSFER;
            uint256 from = _below(4);
            op.caller = m.accounts[from];
            op.data = abi.encode(token, m.accounts[_below(5)], _amount(m, from, k));
            return op;
        }
        if (roll < 11) {
            uint256 a = _below(5);
            listed[k][a] = !listed[k][a];
            op.kind = KIND_BLACKLIST;
            op.caller = address(this);
            op.data = abi.encode(token, m.accounts[a], listed[k][a]);
            return op;
        }
        if (roll < (paused[k] ? 17 : 12)) {
            paused[k] = !paused[k];
            op.kind = KIND_PAUSE;
            op.caller = address(this);
            op.data = abi.encode(token, paused[k]);
            return op;
        }
        if (roll < 18) {
            uint256 a = _below(5);
            lienHolder[k][a] = !lienHolder[k][a];
            op.kind = KIND_LIEN_ROLE;
            op.caller = address(this);
            op.data = abi.encode(token, m.accounts[a], lienHolder[k][a]);
            return op;
        }
        op.kind = KIND_CORE;
        uint256 c = _below(m.accounts.length);
        op.caller = m.accounts[c];
        op.data = _coreCall(m, roll, c, k);
    }

    function _coreCall(Trace memory m, uint256 roll, uint256 c, uint256 k) internal returns (bytes memory) {
        address token = _chance(2) ? m.accounts[0] : m.tokens[k];
        address other = m.accounts[(c + 1 + _below(4)) % 5];
        bytes32 id = m.ids[_below(3)];
        uint64 now_ = uint64(vm.getBlockTimestamp());
        if (roll < 24) {
            uint128 limit =
                uint128(_pick([uint256(1 + _below(10_000)), 1 + _below(1_000_000), 0, U64, type(uint128).max]));
            return abi.encodeCall(
                IReservationCore.approveHolder, (other, token, limit, uint32(_pick([uint256(0), 0, 60, 3600, 86_400])))
            );
        }
        if (roll < 29) {
            IReservationCore.PayeeTerms memory terms = IReservationCore.PayeeTerms({
                debtCap: uint128(_pick([uint256(0), 0, 1 + _below(5000), U64, type(uint128).max])),
                offlineCap: uint128(_pick([uint256(0), 0, 1 + _below(10_000), U64 + 5, 0])),
                toleranceBps: uint16(_pick([uint256(0), 0, 100, 1500, 65_535])),
                debtTerm: uint32(_pick([uint256(0), 60, 86_400, 365 days, 365 days + 1]))
            });
            return abi.encodeCall(IReservationCore.setPayeeTerms, (other, token, terms));
        }
        uint256 owner = roll < 40 ? c : _below(5);
        if (roll < 45) {
            IReservationCore.HoldRequest memory request = IReservationCore.HoldRequest({
                token: token,
                id: id,
                amount: _amount(m, owner, k),
                payee: _chance(3) ? address(0) : other,
                expiresAt: _expiry(now_, 31 days),
                standIn: _chance(25)
            });
            if (roll < 37) return abi.encodeCall(IReservationCore.hold, (request));
            return abi.encodeCall(IReservationCore.holdFrom, (m.accounts[owner], request));
        }
        if (roll < 49) {
            return
                abi.encodeCall(IReservationCore.pledge, (other, token, id, _amount(m, c, k), _expiry(now_, 400 days)));
        }
        if (roll < 53) {
            return abi.encodeCall(
                IReservationCore.pledgeFrom,
                (m.accounts[owner], token, id, _amount(m, owner, k), _expiry(now_, 400 days))
            );
        }
        if (roll < 56) {
            return abi.encodeCall(
                IReservationCore.lien,
                (m.accounts[owner], token, id, _amount(m, owner, k), _chance(50) ? 0 : _expiry(now_, 400 days))
            );
        }
        if (roll < 80) return _settle(m, roll, k);
        if (roll < 88) {
            uint256 amount = _amount(m, owner, k);
            if (_chance(30) && amount < U64) amount += _below(3000);
            return abi.encodeCall(
                IReservationCore.charge, (m.accounts[owner], token, id, uint128(amount), other, _chance(40))
            );
        }
        if (roll < 96) {
            return abi.encodeCall(
                IReservationCore.refund, (m.accounts[owner], token, other, id, _chance(5) ? 0 : _amount(m, c, k))
            );
        }
        return abi.encodeCall(IReservationCore.clearLapsedDebt, (m.accounts[owner], token));
    }

    /// @dev Adjust, capture or release a live record, or a random key.
    function _settle(Trace memory m, uint256 roll, uint256 k) internal returns (bytes memory) {
        (address owner, address placer, bytes32 id, uint256 held, uint256 limit) = _someHold(m);
        if (roll < 62) {
            uint128 amount = uint128(_pick([held, held + 1, held > 1 ? held - 1 : 1, 1 + _below(2000), 0]));
            return abi.encodeCall(IReservationCore.adjust, (owner, placer, id, amount));
        }
        if (roll < 74) {
            uint128 amount = uint128(_pick([held, _below(held + 1), limit, limit + 1, 0]));
            return abi.encodeCall(IReservationCore.capture, (owner, placer, id, amount, _chance(60)));
        }
        k;
        if (roll < 77) return abi.encodeCall(IReservationCore.release, (owner, placer, id));
        return abi.encodeCall(IReservationCore.releaseExpired, (owner, placer, id));
    }

    function _someHold(Trace memory m)
        internal
        returns (address owner, address placer, bytes32 id, uint256 held, uint256 limit)
    {
        uint256 a = m.accounts.length;
        uint256 start = _iHold(m, 0, 0, m.ids[0]);
        uint256 slots = a * a * m.ids.length;
        uint256 from = _below(slots);
        for (uint256 j; j < slots; ++j) {
            uint256 s = (from + j) % slots;
            uint256 i = start + s * 7;
            if (m.expected[i] == 0 || _chance(10)) continue;
            return (
                m.accounts[s / (a * m.ids.length)],
                m.accounts[s / m.ids.length % a],
                m.ids[s % m.ids.length],
                m.expected[i + 2],
                m.expected[i + 3]
            );
        }
        return (m.accounts[_below(a)], m.accounts[_below(a)], m.ids[_below(m.ids.length)], 0, 0);
    }

    function _amount(Trace memory m, uint256 owner, uint256 k) internal returns (uint128) {
        uint256 free = m.expected[_iAvailable(m, k, owner)];
        uint256 r = _below(100);
        if (r < 40) return uint128(1 + _below(1000));
        if (r < 60) return uint128(1 + _below(free == 0 ? 1 : free));
        if (r < 72) return uint128(free);
        if (r < 80) return uint128(free + 1);
        if (r < 84) return 0;
        if (r < 90) return uint128(U64);
        if (r < 95) return uint128(U64 + 1);
        return type(uint128).max;
    }

    function _expiry(uint64 now_, uint64 max) internal returns (uint64) {
        uint256 r = _below(100);
        if (r < 60) return now_ + 1 + uint64(_below(120));
        if (r < 75) return now_ + 1 + uint64(_below(7 days));
        if (r < 85) return now_ + max;
        if (r < 92) return now_ + max + 1;
        if (r < 97) return now_;
        return uint64(1) << 32;
    }

    /// @dev A block time near a stored edge (an expiry, a period end, a debt lapse), or a short step.
    function _nextTime(uint256[] memory s) internal returns (uint64) {
        uint64 now_ = uint64(vm.getBlockTimestamp());
        uint256 edge;
        uint256 base = _iDebt(t, 0, 0);
        if (_chance(60)) {
            uint256 at = _below(s.length);
            for (uint256 j; j < s.length; ++j) {
                uint256 v = s[(at + j) % s.length];
                if (v > now_ + 1 && v < now_ + 400 days && (at + j) % s.length >= 1 && (at + j) % s.length != base) {
                    edge = v;
                    break;
                }
            }
        }
        if (edge != 0) return uint64(edge - 1 + _below(3));
        return now_ + 1 + uint64(_below(_chance(5) ? 31 days : 60));
    }

    function _pick(uint256[5] memory options) internal returns (uint256) {
        return options[_below(5)];
    }

    function _chance(uint256 percent) internal returns (bool) {
        return _below(100) < percent;
    }

    function _below(uint256 n) internal returns (uint256) {
        rng = uint256(keccak256(abi.encode(rng)));
        return n == 0 ? 0 : rng % n;
    }
}
