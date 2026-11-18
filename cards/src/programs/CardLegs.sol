// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { CAPTURE_BEYOND, CAPTURE_FINAL, CAPTURE_FREE, ISource } from "./interfaces/ISource.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

/// @title CardLegs
/// @notice How a card authorization contract (CardAuth) moves a purchase across its funding legs: one leg per entry
///         of the owner's funding order that the purchase drew on, each held, captured, released and refunded by its
///         source.
/// @dev Linked as an external library so CardAuth keeps its runtime code small; it runs in CardAuth's context, so the
///      sources see CardAuth as the caller. Leg sets are bitmasks over order entries.
// Sources are contracts the issuer approved; every call here runs inside a role-gated purchase step.
// Packed purchase fields are read at the widths CardAuth stores them, and a new scale is checked to fit 96 bits.
// forge-lint: disable-start(reentrancy-no-eth, calls-loop, unsafe-typecast)
library CardLegs {
    /// @notice Source kinds.
    uint8 internal constant CASH = 1;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant NONE = type(uint256).max;
    /// @dev One cent in settlement units (six decimals).
    uint256 internal constant CENT = 1e4;

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

    /// @notice Counts `settles` units of a purchase booked in `era` against settlement as a refund and returns them
    ///         in today's settlement token; negative adds to what the program owes.
    function creditBack(
        mapping(uint8 => Era) storage eras,
        State storage s,
        Ledger storage l,
        uint8 era,
        int128 settles
    ) external returns (int256 pay) {
        uint8 current = s.era;
        pay = settles;
        if (era != current) pay = pay * int256(uint256(eras[current].scale)) / int256(uint256(eras[era].scale));
        // At most |settles| times the ratio of two era scales, both uint96, so it fits int128.
        // forge-lint: disable-next-line(unsafe-typecast)
        l.net -= int128(pay);
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
        uint256[MAX_LEGS] memory placed;
        for (uint256 i; i < order.length && held < amount; ++i) {
            Funding memory f = order[i];
            uint8 kind = kindOf[address(f.source)];
            if (kind & kinds == 0 || (standIn && kind != CASH)) continue;
            uint256 h = f.source.hold(owner, f.position, legId(ref, i), amount - held, expiresAt, standIn);
            if (h != 0) (held, legs, placed[i]) = (held + h, legs | 1 << i, h);
            if (standIn) break;
        }
        // A partial approval is whole cents: the last legs give back the fraction of a cent.
        if (standIn || held >= amount) return (held, legs);
        uint256 cut = held % CENT;
        for (uint256 i = order.length; cut != 0 && i != 0;) {
            if (legs >> --i & 1 == 0) continue;
            Funding memory f = order[i];
            uint256 take = _min(placed[i], cut);
            if (f.source.hold(owner, f.position, legId(ref, i), placed[i] - take, expiresAt, false) == 0) {
                legs &= ~(1 << i);
            }
            (held, cut) = (held - take, cut - take);
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

    /// @notice Shrinks what the legs hold to `open` in total: cash legs give back first, from the last cash leg, then
    ///         the other legs from the last drawn. Legs are sized against what they hold now, so a leg whose value
    ///         drifted since it was placed never releases more than the purchase gives up. A stand-in holds `open`.
    function shrink(
        Funding[] storage order,
        mapping(address => uint8) storage kindOf,
        bytes32 ref,
        address owner,
        uint256 legs,
        uint256 open,
        bool standIn,
        uint64 expiresAt
    ) external {
        uint256 n = order.length;
        uint256[MAX_LEGS] memory cur;
        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (legs >> i & 1 == 0) continue;
            Funding memory f = order[i];
            if (standIn) {
                f.source.hold(owner, f.position, legId(ref, i), open, expiresAt, true);
                return;
            }
            cur[i] = f.source.held(owner, f.position, legId(ref, i));
            total += cur[i];
        }
        if (total <= open) return;
        uint256 less = total - open;
        // Cash gives back first (pass 0), then the other legs (pass 1), each from the last; one leg needs no kind.
        bool single = legs & (legs - 1) == 0;
        for (uint256 pass; pass < 2 && less != 0; ++pass) {
            for (uint256 i = n; i != 0 && less != 0;) {
                --i;
                if (cur[i] == 0) continue;
                Funding memory f = order[i];
                if (!single && (pass == 0) != (kindOf[address(f.source)] == CASH)) continue;
                uint256 take = _min(cur[i], less);
                f.source.hold(owner, f.position, legId(ref, i), cur[i] - take, expiresAt, false);
                cur[i] = 0;
                less -= take;
            }
        }
    }

    /// @notice Captures `amount` walking the order: each entry the card allows takes what it holds and what its source
    ///         can still cover for the owner, placing or growing its leg as needed, so free funds of earlier entries
    ///         go before later legs' holds. What no entry covers is charged to the first cash entry: free cash, then
    ///         debt within the owner's terms; the issuer absorbs the rest. Past `open` plus the tolerance on `total`
    ///         it reverts (a stand-in has none and captures from its one cash leg). `amounts` is amount, open,
    ///         total, the card's kinds and the expiry of legs it places. Returns the units covered and the legs.
    function capture(
        Funding[] storage order,
        mapping(address => uint8) storage kindOf,
        bytes32 ref,
        address owner,
        uint256 legs,
        uint256[5] memory amounts,
        bool isFinal,
        bool standIn
    ) external returns (uint256 covered, uint256) {
        uint256 amount = amounts[0];
        if (amount > amounts[1] || standIn) {
            // The leg whose tolerance bounds the purchase: the first cash leg, else the first leg.
            uint256 lead = _lowBit(legs);
            for (uint256 i = lead; i < order.length; ++i) {
                if (legs >> i & 1 != 0 && kindOf[address(order[i].source)] == CASH) {
                    lead = i;
                    break;
                }
            }
            Funding memory f = order[lead];
            if (standIn) {
                if (amount > amounts[1]) revert CaptureLimitExceeded();
                uint8 flags = CAPTURE_BEYOND | (isFinal ? CAPTURE_FINAL : 0);
                (covered,) = f.source.capture(owner, f.position, legId(ref, lead), amount, flags);
                return (covered, legs);
            }
            uint256 tolerance = f.source.toleranceBps(owner, f.position);
            if (amount > amounts[1] + amounts[2] * tolerance / BPS) revert CaptureLimitExceeded();
        }
        // The last leg the purchase drew on captures as final, as does any leg placed past it; a leg that covers less
        // than it is asked stays live for the debt below and is released after it.
        uint256 top = _highBit(legs);
        uint256 finals;
        uint256 rest = amount;
        for (uint256 i; i < order.length && rest != 0; ++i) {
            Funding memory g = order[i];
            bytes32 id = legId(ref, i);
            if (legs >> i & 1 == 0) {
                if (kindOf[address(g.source)] & amounts[3] == 0) continue;
                if (g.source.hold(owner, g.position, id, rest, uint64(amounts[4]), false) == 0) continue;
                legs |= 1 << i;
            }
            bool last = isFinal && i >= top;
            (uint256 paid, uint256 took) =
                g.source.capture(owner, g.position, id, rest, CAPTURE_FREE | (last ? CAPTURE_FINAL : 0));
            (covered, rest) = (covered + paid, rest - took);
            if (last && rest == 0) finals |= 1 << i;
        }
        if (rest != 0 && amounts[3] & CASH != 0) {
            // What no source covered is debt on the first cash entry: through its live leg, else a charge.
            for (uint256 i; i < order.length; ++i) {
                Funding memory g = order[i];
                if (kindOf[address(g.source)] != CASH) continue;
                bytes32 id = legId(ref, i);
                if (legs >> i & 1 != 0) {
                    (uint256 paid,) =
                        g.source.capture(owner, g.position, id, rest, CAPTURE_BEYOND | (isFinal ? CAPTURE_FINAL : 0));
                    if (isFinal) finals |= 1 << i;
                    covered += paid;
                } else {
                    uint256 t = g.source.charge(owner, g.position, id, rest, false);
                    if (t != 0) (covered, legs, finals) = (covered + t, legs | 1 << i, finals | 1 << i);
                }
                break;
            }
        }
        if (isFinal && legs & ~finals != 0) release(order, ref, owner, legs & ~finals);
        return (covered, legs);
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

    /// @notice Refunds `units` of `token`, pulled from the caller. What the owner owes the first cash leg's source
    ///         (else the first cash entry's) as debt is repaid first through that leg. The rest walks the legs in
    ///         reverse order, each taking back at most what it still nets: a bounded leg (savings, credit) its own
    ///         refundable, the first cash leg what the purchase still nets (`remaining`) past the bounded legs. The
    ///         first cash leg takes whatever is left.
    function refund(
        Funding[] storage order,
        bytes32 ref,
        address owner,
        uint256 legs,
        uint256 units,
        uint256 remaining,
        address token
    ) external {
        uint256 n = order.length;
        uint256[MAX_LEGS] memory room;
        uint256 bounded;
        uint256 taker = NONE;
        for (uint256 i; i < n; ++i) {
            if (legs >> i & 1 == 0) continue;
            uint256 r = order[i].source.refundable(owner, order[i].position, legId(ref, i));
            room[i] = r;
            if (r != NONE) bounded += r;
            else if (taker == NONE) taker = i;
        }
        for (uint256 i; i < n && taker == NONE; ++i) {
            if (order[i].source.refundable(owner, order[i].position, legId(ref, i)) == NONE) taker = i;
        }
        if (taker == NONE) {
            if (_refundBounded(order, ref, owner, legs, room, units, token) != 0) revert InvalidAmount();
            return;
        }
        Funding memory f = order[taker];
        bytes32 id = legId(ref, taker);
        uint256 first = _min(units, f.source.owed(owner, f.position));
        if (first != 0) {
            _refundLeg(f, token, owner, id, first);
            (units, remaining) = (units - first, remaining - _min(first, remaining));
        }
        // Cash bounds nothing itself: the first cash leg nets what the bounded legs don't, later cash legs nothing.
        if (legs >> taker & 1 != 0) room[taker] = remaining > bounded ? remaining - bounded : 0;
        units = _refundBounded(order, ref, owner, legs, room, units, token);
        if (units != 0) _refundLeg(f, token, owner, id, units);
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

    /// @dev Refunds up to `units` to the legs in reverse order, each up to its room; returns what is left.
    function _refundBounded(
        Funding[] storage order,
        bytes32 ref,
        address owner,
        uint256 legs,
        uint256[MAX_LEGS] memory room,
        uint256 units,
        address token
    ) private returns (uint256) {
        for (uint256 i = order.length; i != 0 && units != 0;) {
            --i;
            if (legs >> i & 1 == 0 || room[i] == NONE) continue;
            uint256 take = _min(units, room[i]);
            if (take == 0) continue;
            _refundLeg(order[i], token, owner, legId(ref, i), take);
            units -= take;
        }
        return units;
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

    function _highBit(uint256 x) private pure returns (uint256 i) {
        while (x >> (i + 1) != 0) {
            ++i;
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
// forge-lint: disable-end(reentrancy-no-eth, calls-loop, unsafe-typecast)
