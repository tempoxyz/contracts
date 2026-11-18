// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { CAPTURE_BEYOND, CAPTURE_FINAL, ISource } from "./interfaces/ISource.sol";

/// @title CardLegs
/// @notice How a card authorization contract (CardAuth) moves a purchase across its funding legs: one leg per entry
///         of the owner's funding order that the purchase drew on, each held, captured, released and refunded by its
///         source.
/// @dev Linked as an external library so CardAuth keeps its runtime code small; it runs in CardAuth's context, so the
///      sources see CardAuth as the caller. Leg sets are bitmasks over order entries.
// Sources are contracts the issuer approved; every call here runs inside a role-gated purchase step.
// forge-lint: disable-start(reentrancy-no-eth, calls-loop)
library CardLegs {
    /// @notice Source kinds.
    uint8 internal constant CASH = 1;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant NONE = type(uint256).max;

    /// @notice An owner's order entry: a source and what it draws on there.
    struct Funding {
        ISource source;
        bytes32 position;
    }

    /// @notice A settlement token the program used, and how many of its units one base unit is worth (18 decimals).
    struct Era {
        address token;
        uint96 scale;
    }

    /// @notice A program's current settlement era, card count, owners that ever granted terms, and what open
    ///         purchases hold (the stand-in part apart).
    struct State {
        uint8 era;
        uint32 cards;
        uint64 grantedOwners;
        uint64 held;
        uint64 standIn;
    }

    /// @notice Purchase steps so far and the last one the issuer acknowledged, with net covered units now and at
    ///         that acknowledgement.
    struct Ledger {
        uint64 seq;
        uint64 settledThrough;
        int128 net;
        int128 settledNet;
    }

    /// @notice Most order entries an owner may list.
    uint256 internal constant MAX_LEGS = 4;

    event FundingSet(address indexed owner, uint8 version, Funding[] order);

    event SettlementAcknowledged(uint64 throughSeq, uint64 previous);
    event SettlementTokenSet(address token, uint256 scale, uint8 era);

    error CaptureLimitExceeded();
    error InsufficientAvailable();
    error InvalidAmount();
    error InvalidCursor();
    error InvalidOrder();
    error Unsettled();

    /// @notice Acknowledges purchase steps through `throughSeq` as settled.
    function acknowledge(Ledger storage l, uint64 throughSeq) external {
        uint64 previous = l.settledThrough;
        if (throughSeq <= previous || throughSeq > l.seq) revert InvalidCursor();
        l.settledThrough = throughSeq;
        if (throughSeq == l.seq) l.settledNet = l.net;
        emit SettlementAcknowledged(throughSeq, previous);
    }

    /// @notice Switches to settlement token `token`, worth `scale` units per unit of the current one (18 decimals).
    ///         Refused while purchases hold anything or steps are unacknowledged.
    function switchToken(
        mapping(uint8 => Era) storage eras,
        State storage s,
        Ledger storage l,
        address token,
        uint256 scale
    ) external {
        uint8 era = s.era;
        if (s.held != 0 || l.net != l.settledNet || l.seq != l.settledThrough) revert Unsettled();
        uint256 next = FixedPointMathLib.mulDiv(eras[era].scale, scale, 1e18);
        if (token == address(0) || era == type(uint8).max || next == 0 || next > type(uint96).max) {
            revert InvalidAmount();
        }
        eras[++era] = Era(token, uint96(next));
        s.era = era;
        (l.net, l.settledNet) = (0, 0);
        emit SettlementTokenSet(token, scale, era);
    }

    /// @notice Replaces `list` with `order`, every entry an approved source.
    function setOrder(
        Funding[] storage list,
        mapping(address => uint8) storage kindOf,
        Funding[] calldata order,
        uint8 version
    ) external {
        if (order.length > MAX_LEGS) revert InvalidOrder();
        while (list.length != 0) {
            list.pop();
        }
        for (uint256 i; i < order.length; ++i) {
            if (kindOf[address(order[i].source)] == 0) revert InvalidOrder();
            list.push(order[i]);
        }
        emit FundingSet(msg.sender, version, order);
    }

    /// @notice Holds up to `amount` across the order's entries the card allows, in order: a stand-in only on the
    ///         first cash entry. Returns what the legs hold and the legs.
    function place(
        Funding[] storage order,
        mapping(address => uint8) storage kindOf,
        bytes32 ref,
        address owner,
        uint8 kinds,
        uint256 amount,
        uint64 expiresAt,
        bool standIn
    ) external returns (uint256 held, uint256 legs) {
        for (uint256 i; i < order.length && held < amount; ++i) {
            Funding memory f = order[i];
            uint8 kind = kindOf[address(f.source)];
            if (kind & kinds == 0 || (standIn && kind != CASH)) continue;
            uint256 h = f.source.hold(owner, f.position, legId(ref, i), amount - held, expiresAt, standIn);
            if (h != 0) (held, legs) = (held + h, legs | 1 << i);
            if (standIn) break;
        }
    }

    /// @notice Holds `want` more across the order's entries the card allows, growing the purchase's legs. Reverts
    ///         when the sources can't hold it all.
    function grow(
        Funding[] storage order,
        mapping(address => uint8) storage kindOf,
        bytes32 ref,
        address owner,
        uint8 kinds,
        uint256 want,
        uint256 legs,
        uint64 expiresAt
    ) external returns (uint256) {
        for (uint256 i; i < order.length && want != 0; ++i) {
            Funding memory f = order[i];
            if (kindOf[address(f.source)] & kinds == 0) continue;
            bytes32 id = legId(ref, i);
            uint256 cur = legs >> i & 1 == 0 ? 0 : f.source.held(owner, f.position, id);
            uint256 next = f.source.hold(owner, f.position, id, cur + want, expiresAt, false);
            if (next > cur) (want, legs) = (want - _min(next - cur, want), legs | 1 << i);
        }
        if (want != 0) revert InsufficientAvailable();
        return legs;
    }

    /// @notice Returns `less` of what the legs hold, from the last leg first. A stand-in keeps what it holds up to
    ///         `open`.
    function shrink(
        Funding[] storage order,
        bytes32 ref,
        address owner,
        uint256 legs,
        uint256 less,
        uint256 open,
        bool standIn,
        uint64 expiresAt
    ) external {
        for (uint256 i = order.length; i != 0 && less != 0;) {
            --i;
            if (legs >> i & 1 == 0) continue;
            Funding memory f = order[i];
            bytes32 id = legId(ref, i);
            if (standIn) {
                f.source.hold(owner, f.position, id, open, expiresAt, true);
                return;
            }
            uint256 cur = f.source.held(owner, f.position, id);
            uint256 cut = _min(cur, less);
            if (cut != 0) f.source.hold(owner, f.position, id, cur - cut, expiresAt, false);
            less -= cut;
        }
    }

    /// @notice Captures `amount` across the legs: each leg's hold in order, then what they lack from the first
    ///         cash leg (else the first leg), free funds and debt within the owner's terms. Past `open` plus the
    ///         tolerance on `total` it reverts (a stand-in has none). Returns the units the sources covered.
    function capture(
        Funding[] storage order,
        mapping(address => uint8) storage kindOf,
        bytes32 ref,
        address owner,
        uint256 legs,
        uint256[3] memory amounts,
        bool isFinal,
        bool standIn
    ) external returns (uint256 covered) {
        (uint256 amount, uint256 open, uint256 total) = (amounts[0], amounts[1], amounts[2]);
        // The leg that takes what the holds lack: the first cash leg, else the first leg.
        uint256 last = _lowBit(legs);
        for (uint256 i = last; i < order.length; ++i) {
            if (legs >> i & 1 != 0 && kindOf[address(order[i].source)] == CASH) {
                last = i;
                break;
            }
        }
        Funding memory f = order[last];
        if (amount > open) {
            uint256 tolerance = standIn ? 0 : f.source.toleranceBps(owner, f.position);
            if (amount > open + total * tolerance / BPS) revert CaptureLimitExceeded();
        }
        if (legs == 1 << last) {
            uint8 flags = CAPTURE_BEYOND | (isFinal ? CAPTURE_FINAL : 0);
            return f.source.capture(owner, f.position, legId(ref, last), amount, flags);
        }
        uint256 rest = amount;
        for (uint256 i; i < order.length && rest != 0; ++i) {
            if (legs >> i & 1 == 0) continue;
            Funding memory g = order[i];
            rest -= g.source.capture(owner, g.position, legId(ref, i), rest, 0);
        }
        if (rest != 0) rest -= f.source.capture(owner, f.position, legId(ref, last), rest, CAPTURE_BEYOND);
        if (isFinal) release(order, ref, owner, legs);
        covered = amount - rest;
    }

    /// @notice Charges `amount` with no hold across the order's cash entries, adding the ones that paid to the legs.
    ///         Returns the units they covered and the legs.
    function charge(
        Funding[] storage order,
        mapping(address => uint8) storage kindOf,
        bytes32 ref,
        address owner,
        uint256 amount,
        uint256 legs
    ) external returns (uint256 covered, uint256) {
        uint256 rest = amount;
        for (uint256 i; i < order.length && rest != 0; ++i) {
            Funding memory f = order[i];
            if (kindOf[address(f.source)] != CASH) continue;
            uint256 t = f.source.charge(owner, f.position, legId(ref, i), rest, false);
            if (t != 0) (rest, legs) = (rest - t, legs | 1 << i);
        }
        return (amount - rest, legs);
    }

    /// @notice Ends every leg.
    function release(Funding[] storage order, bytes32 ref, address owner, uint256 legs) public {
        for (uint256 i; i < order.length; ++i) {
            if (legs >> i & 1 != 0) order[i].source.release(owner, order[i].position, legId(ref, i));
        }
    }

    /// @notice Refunds `units` of `token`, pulled from the caller: legs that bound what they take back in reverse
    ///         order first, then the first leg (else order entry) that takes any amount, the rest.
    function refund(Funding[] storage order, bytes32 ref, address owner, uint256 legs, uint256 units, address token)
        external
    {
        uint256 taker = NONE;
        for (uint256 i = order.length; i != 0 && units != 0;) {
            --i;
            if (legs >> i & 1 == 0) continue;
            Funding memory f = order[i];
            bytes32 id = legId(ref, i);
            uint256 room = f.source.refundable(owner, f.position, id);
            if (room == NONE) {
                taker = i;
                continue;
            }
            room = _min(units, room);
            if (room != 0) _refundLeg(f, token, owner, id, room);
            units -= room;
        }
        if (units == 0) return;
        for (uint256 i; i < order.length && taker == NONE; ++i) {
            if (order[i].source.refundable(owner, order[i].position, legId(ref, i)) == NONE) taker = i;
        }
        if (taker == NONE) revert InvalidAmount();
        _refundLeg(order[taker], token, owner, legId(ref, taker), units);
    }

    /// @notice The ABI encoding of the legs' sources, positions and leg ids.
    function legsOf(Funding[] storage order, bytes32 ref, uint256 legs) external view returns (bytes memory) {
        address[] memory sources;
        bytes32[] memory positions;
        bytes32[] memory ids;
        uint256 n;
        for (uint256 i; i < order.length; ++i) {
            if (legs >> i & 1 != 0) ++n;
        }
        (sources, positions, ids) = (new address[](n), new bytes32[](n), new bytes32[](n));
        n = 0;
        for (uint256 i; i < order.length; ++i) {
            if (legs >> i & 1 == 0) continue;
            (sources[n], positions[n], ids[n]) = (address(order[i].source), order[i].position, legId(ref, i));
            ++n;
        }
        return abi.encode(sources, positions, ids);
    }

    /// @notice The ABI encoding of the ICardAuth.PurchaseView of purchase word `word` (laid out as CardAuth packs it);
    ///         all zero for an empty word.
    function purchaseView(uint256 word, address owner, bytes32 card, address token)
        external
        pure
        returns (bytes memory)
    {
        ICardAuth.PurchaseView memory v;
        if (word != 0) {
            bool open = word >> 248 & 1 != 0;
            uint256 amount = uint48(word >> 32);
            uint256 captured = uint48(word >> 80);
            v = ICardAuth.PurchaseView({
                owner: owner,
                card: card,
                token: token,
                expiresAt: uint32(word >> 176),
                held: uint64(open ? amount - captured : 0),
                captured: uint64(captured),
                refunded: uint48(word >> 128),
                open: open,
                standIn: word >> 249 & 1 != 0,
                charged: word >> 250 & 1 != 0
            });
        }
        return abi.encode(v);
    }

    /// @notice The ABI encoding of an order.
    // forge-lint: disable-next-line(mixed-case-function)
    function encode(Funding[] storage order) external view returns (bytes memory) {
        Funding[] memory copy = order;
        return abi.encode(copy);
    }

    /// @notice The id order entry `i` of purchase `ref` holds under at its source.
    function legId(bytes32 ref, uint256 i) internal pure returns (bytes32 id) {
        assembly ("memory-safe") {
            mstore(0, ref)
            mstore8(32, i)
            id := keccak256(0, 33)
        }
    }

    function _refundLeg(Funding memory f, address token, address owner, bytes32 id, uint256 units) private {
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(f.source), units);
        f.source.refund(owner, f.position, id, units);
    }

    function _lowBit(uint256 x) private pure returns (uint256 i) {
        if (x == 0) return 0;
        while (x >> i & 1 == 0) {
            ++i;
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
// forge-lint: disable-end(reentrancy-no-eth, calls-loop)
