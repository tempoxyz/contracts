// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

import { CardConvert } from "./CardConvert.sol";
import { CardProgram } from "./CardProgram.sol";
import { CreditLine } from "./CreditLine.sol";
import { SavingsFacility } from "./SavingsFacility.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

/// @notice What a program's collateral is worth to it, in settlement units.
interface ICollateral {
    function valueOf(address program) external view returns (uint256);
}

/// @title CardFunding
/// @notice A card program's funding: each owner's funding order across cash, savings facilities and credit lines,
///         the legs a purchase places on them, the capture waterfall, refunds and the program's exposure. Linked as an
///         external library, it runs in the program's context and keeps its state in its own storage slot.
/// @dev A purchase's legs are holds whose ids derive from the purchase and the source's index in the order it was
///      placed under, so they are read back from the core rather than recorded.
// Loops run over a funding order (at most MAX_SOURCES entries) or a purchase's charges, and call only the fixed core,
// issuer-approved facilities and credit lines, and the program itself.
// forge-lint: disable-start(calls-loop)
library CardFunding {
    using FixedPointMathLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 private constant RATE_ONE = 1e18;
    /// @dev One cent in settlement units (six decimals).
    uint256 private constant CENT = 1e4;
    uint256 private constant BPS = 10_000;
    uint256 internal constant MAX_SOURCES = 8;
    /// @dev Leg hold tags: 16 + the source's index for legs, 64 + a count for capture debt charges.
    uint256 private constant LEG_TAG = 16;
    uint256 private constant FIRST = type(uint256).max;
    uint256 private constant DEBT_TAG = 64;

    uint8 internal constant CASH = 1;
    uint8 internal constant SAVINGS = 2;
    uint8 internal constant CREDIT = 4;
    uint8 internal constant CHARGED = 8;
    /// @dev A capture left part of the purchase as the owner's capped debt.
    uint8 internal constant DEBT = 32;
    /// @dev Another stablecoin the owner holds; the entry's lineId is the most it may cost to convert, in basis points.
    uint8 internal constant TOKEN = 64;
    uint8 private constant ALL_KINDS = CASH | SAVINGS | CREDIT;

    uint8 internal constant STEP_HOLD = 0;
    uint8 internal constant STEP_ADJUST = 1;
    uint8 internal constant STEP_CAPTURE = 2;
    uint8 internal constant STEP_REFUND = 3;
    uint8 internal constant STEP_RELEASE = 4;

    /// @notice One entry of a funding order: the cash token, a savings facility, or a credit line and its id.
    struct Source {
        uint8 kind;
        address source;
        uint64 lineId;
    }

    /// @notice What one source took in a purchase step: settlement units and the source token's units.
    struct Part {
        uint8 kind;
        address source;
        uint64 lineId;
        uint256 amount;
        uint256 tokens;
    }

    /// @dev One leg's hold as a step reads it.
    struct Leg {
        address holdOwner;
        address token;
        bytes32 id;
        uint256 rate;
        uint128 held;
        uint128 refundable;
        bool exists;
        bool settled;
    }

    struct Layout {
        mapping(address owner => uint32) version;
        mapping(address owner => mapping(uint32 version => Source[])) orders;
        /// @dev Kinds of source the program accepts; zero accepts every kind.
        uint8 assets;
        address collateral;
        /// @dev Settlement units open purchases still count as held.
        uint128 held;
        address[] debtors;
        mapping(address owner => bool) isDebtor;
    }

    bytes32 private constant SLOT = keccak256("tempo.cards.CardFunding.v1");

    event FundingOrderSet(address indexed owner, address cashToken, uint32 version, Source[] order);
    event AssetsSet(uint8 kinds);
    event CollateralSet(address collateral);
    /// @notice What each source took in one purchase step, what became capped debt and what the issuer absorbed.
    event Funded(bytes32 indexed purchaseRef, uint8 step, Part[] parts, uint256 debt, uint256 absorbed);

    error InvalidOrder();
    error OverExposure(uint256 total, uint256 collateral);

    // Every entry point runs inside the program's transient lock, and the core, facilities and credit lines it calls
    // are fixed or issuer-approved.
    // forge-lint: disable-start(reentrancy-no-eth)

    // Settings.

    /// @notice Sets the caller's funding order; purchases keep the order they were placed under.
    function setOrder(address owner, address cashToken, Source[] calldata order) external {
        if (order.length > MAX_SOURCES) revert InvalidOrder();
        Layout storage L = _layout();
        uint32 version = ++L.version[owner];
        Source[] storage stored = L.orders[owner][version];
        CardProgram program = CardProgram(address(this));
        for (uint256 i; i < order.length; ++i) {
            Source calldata s = order[i];
            if (s.kind == CASH) {
                if (s.source != cashToken) revert InvalidOrder();
            } else if (s.kind == TOKEN) {
                if (s.source == address(0) || s.source == cashToken || s.lineId > BPS) revert InvalidOrder();
            } else if (s.kind == SAVINGS || s.kind == CREDIT) {
                if (!program.approvedSource(s.source)) revert CardProgram.SourceNotApproved(s.source);
            } else {
                revert InvalidOrder();
            }
            stored.push(s);
        }
        emit FundingOrderSet(owner, cashToken, version, order);
    }

    function setAssets(uint8 kinds) external {
        if (kinds & ~ALL_KINDS != 0) revert InvalidOrder();
        _layout().assets = kinds;
        emit AssetsSet(kinds);
    }

    function setCollateral(address collateral_) external {
        _layout().collateral = collateral_;
        emit CollateralSet(collateral_);
    }

    /// @notice Counts `owner` among the program's debtors once it owes the program capped debt.
    function noteDebtor(address owner) public {
        Layout storage L = _layout();
        if (!L.isDebtor[owner]) {
            L.isDebtor[owner] = true;
            L.debtors.push(owner);
        }
    }

    // Purchase steps.

    /// @notice Places a purchase's legs on its owner's funding order, as far as free funds go. A partial approval
    ///         covers whole cents; a stand-in holds what cash is available and approves it all. Returns the approved
    ///         amount and the cash, share and credit tokens held.
    function place(
        CardProgram.Purchase storage p,
        bytes32 ref,
        address owner,
        uint256 amount,
        uint8 cardLegs,
        uint64 expiresAt,
        uint8 flags
    ) external returns (uint256 approved, uint256[3] memory sums) {
        Layout storage L = _layout();
        uint32 version = L.version[owner];
        p.version = version;
        Source[] storage order = L.orders[owner][version];
        uint8 allowed = _allowed(L, cardLegs);
        Part[] memory parts = new Part[](order.length);
        uint8 legs;
        if (flags & 1 != 0) {
            // Stand-in: the core reserves what is available and caps the capture at the full approval.
            (uint256 i, bool found) = _cashIndex(order, allowed);
            if (!found) revert CardProgram.InsufficientFunds(amount);
            Source memory s = order[i];
            Leg memory leg = _leg(owner, ref, _key(order, i), s);
            uint256 tokens = _toTokenUp(amount, leg.rate);
            _hold(leg, s, owner, ref, _key(order, i), tokens, expiresAt, true);
            parts[i] = _part(s, amount, tokens);
            sums[0] = tokens;
            legs = CASH;
            approved = amount;
        } else {
            uint256 covered = _coverable(order, owner, ref, allowed, amount);
            approved = amount;
            if (covered < amount) {
                if (flags & 2 == 0) revert CardProgram.InsufficientFunds(amount - covered);
                approved = covered - covered % CENT;
                if (approved == 0) revert CardProgram.InsufficientFunds(amount);
            }
            uint256 rest = approved;
            for (uint256 i; i < order.length && rest != 0; ++i) {
                Source memory s = order[i];
                if (allowed & s.kind == 0) continue;
                Leg memory leg = _leg(owner, ref, _key(order, i), s);
                uint256 free = _free(leg, s, owner);
                uint256 value = _value(leg, s, free);
                uint256 take = rest < value ? rest : value;
                if (take == 0) continue;
                uint256 tokens = _tokensFor(leg, s, take, value, free);
                _hold(leg, s, owner, ref, _key(order, i), tokens, expiresAt, false);
                parts[i] = _part(s, take, tokens);
                sums[_sumIndex(s.kind)] += tokens;
                legs |= s.kind;
                rest -= take;
            }
            if (rest != 0) revert CardProgram.InsufficientFunds(rest);
        }
        p.legs = legs;
        // Bounded by 64-bit purchase amounts.
        // forge-lint: disable-next-line(unsafe-typecast)
        L.held += uint128(approved);
        _checkExposure(L);
        emit Funded(ref, STEP_HOLD, parts, 0, 0);
    }

    /// @notice Captures a purchase, re-planned on its funding order at capture time: each source pays what its leg
    ///         holds plus what is free on it now, then capped debt on the cash token, and the issuer absorbs the rest.
    ///         A final capture releases what it leaves held. Returns the cash, share and credit tokens captured, the
    ///         debt and the absorbed shortfall in settlement units.
    function capture(
        CardProgram.Purchase storage p,
        bytes32 ref,
        uint256 amount,
        bool isFinal,
        uint8 cardLegs,
        address cashToken
    ) external returns (uint256[3] memory sums, uint256 debt, uint256 absorbed) {
        Layout storage L = _layout();
        address owner = p.owner;
        Source[] storage order = L.orders[owner][p.version];
        Part[] memory parts = new Part[](order.length);
        if (p.standIn) {
            // The core caps a stand-in capture at its approval and turns any shortfall into debt.
            (uint256 i,) = _cashIndex(order, CASH);
            Source memory s = order[i];
            Leg memory leg = _leg(owner, ref, _key(order, i), s);
            uint256 tokens = _toTokenUp(amount, leg.rate);
            _captureLeg(leg, s, tokens, isFinal);
            parts[i] = _part(s, amount, tokens);
            sums[0] = tokens;
        } else {
            // Over-capture (tips) stays within the owner's tolerance for this program, as the core holds each leg to it.
            uint256 tolerance = cashToken == address(0) ? 0 : CORE.captureTolerance(owner, address(this), cashToken);
            if (amount > uint256(p.held) + uint256(p.amount) * tolerance / BPS) {
                revert IReservationCore.ToleranceExceeded();
            }
            uint256 rest = amount;
            uint8 allowed = _allowed(L, cardLegs) | (p.legs & ALL_KINDS);
            for (uint256 i; i < order.length; ++i) {
                Source memory s = order[i];
                Leg memory leg = _leg(owner, ref, _key(order, i), s);
                uint256 tokens;
                uint256[6] memory cv;
                bool converts = CardConvert.swapper(leg.token, s.kind) != address(0);
                if (rest != 0 && allowed & s.kind != 0 && !leg.settled) {
                    uint256 units = leg.held + _free(leg, s, owner);
                    uint256 take;
                    if (converts) {
                        cv = CardConvert.price(owner, leg.token, rest, leg.held, leg.rate, leg.exists);
                        (take, tokens, leg.rate) = (cv[0], cv[1], cv[5]);
                    } else {
                        uint256 value = _value(leg, s, units);
                        take = rest < value ? rest : value;
                        if (take != 0) tokens = _tokensFor(leg, s, take, value, units);
                    }
                    if (take != 0) {
                        if (tokens > leg.held) {
                            _hold(leg, s, owner, ref, _key(order, i), tokens, p.expiresAt, false);
                            leg.exists = true;
                        }
                        rest -= take;
                        parts[i] = _part(s, take, tokens);
                        sums[_sumIndex(s.kind)] += tokens;
                        p.legs |= s.kind;
                    }
                }
                if (tokens != 0 || (isFinal && leg.exists && !leg.settled)) _captureLeg(leg, s, tokens, isFinal);
                if (cv[0] != 0) CardConvert.finish(ref, owner, leg.id, leg.token, cv, isFinal);
                else if (tokens != 0) CardConvert.settle(ref, s.kind, s.source, leg.token, parts[i].amount);
            }
            if (rest != 0) {
                uint256 charged;
                (debt, charged) = _chargeDebt(p, ref, owner, CardConvert.debtToken(cashToken), rest);
                sums[0] += charged;
                absorbed = rest - debt;
            }
        }
        _forwardAll(order, cashToken);
        emit Funded(ref, STEP_CAPTURE, parts, debt, absorbed);
        // A partial capture leaves the rest held: the program reports what each source still holds.
        if (!isFinal) emit Funded(ref, STEP_ADJUST, _heldParts(order, owner, ref), 0, 0);

        // The held part already counted toward the total held; a final capture frees what it leaves held.
        uint256 counted = p.held;
        uint256 fromHeld = amount < counted ? amount : counted;
        // forge-lint: disable-next-line(unsafe-typecast)
        L.held -= uint128(isFinal ? counted : fromHeld);
    }

    /// @notice Refunds a purchase: first the owner's debt to the program from its cash legs, then every leg in
    ///         reverse of the order it was drawn. Pulls each leg's token from the caller.
    function refund(CardProgram.Purchase storage p, bytes32 ref, uint256 amount, address cashToken)
        external
        returns (uint256[3] memory sums)
    {
        Layout storage L = _layout();
        address owner = p.owner;
        Source[] storage order = L.orders[owner][p.version];
        // The last part collects the purchase's charges.
        Part[] memory parts = new Part[](order.length + 1);
        uint256 rest = amount;
        uint256 rate = _rate(cashToken);
        // Nothing moves unless the purchase can refund all of it.
        uint256 refundable = _refundable(order, owner, ref, cashToken, rate);
        if (amount > refundable) revert CardProgram.RefundExceedsCapture(amount - refundable);

        // The owner's debt to this program first: a cash refund repays it as it lands.
        (address creditor, uint128 owed) = CORE.debtOf(owner, cashToken);
        if (creditor == address(this) && owed != 0) {
            uint256 first = _toSettlement(owed, rate);
            if (first > rest) first = rest;
            uint256 left = _refundCharges(ref, owner, cashToken, rate, first, parts);
            for (uint256 i = order.length; i > 0 && left != 0; --i) {
                if (order[i - 1].kind == CASH) {
                    left = _refundLeg(owner, ref, i - 1, _key(order, i - 1), order[i - 1], left, parts);
                }
            }
            rest -= first - left;
        }
        rest = _refundCharges(ref, owner, cashToken, rate, rest, parts);
        for (uint256 i = order.length; i > 0 && rest != 0; --i) {
            rest = _refundLeg(owner, ref, i - 1, _key(order, i - 1), order[i - 1], rest, parts);
        }
        if (rest != 0) revert CardProgram.RefundExceedsCapture(rest);
        for (uint256 i; i < parts.length; ++i) {
            if (parts[i].tokens != 0) sums[_sumIndex(parts[i].kind)] += parts[i].tokens;
        }
        _forwardAll(order, cashToken);
        emit Funded(ref, STEP_REFUND, parts, 0, 0);
    }

    /// @notice Releases every leg a purchase still holds (once expired, as anyone may) and returns the cash, share and
    ///         credit tokens released.
    function end(CardProgram.Purchase storage p, bytes32 ref, bool expired) external returns (uint256[3] memory sums) {
        Layout storage L = _layout();
        address owner = p.owner;
        Source[] storage order = L.orders[owner][p.version];
        Part[] memory parts = new Part[](order.length);
        for (uint256 i; i < order.length; ++i) {
            Source memory s = order[i];
            Leg memory leg = _leg(owner, ref, _key(order, i), s);
            if (!leg.exists || leg.settled) continue;
            if (expired) CORE.releaseExpired(leg.holdOwner, leg.id);
            else CORE.release(leg.holdOwner, leg.id);
            if (s.kind == CREDIT) CreditLine(s.source).sync(leg.id);
            parts[i] = _part(s, _value(leg, s, leg.held), leg.held);
            sums[_sumIndex(s.kind)] += leg.held;
        }
        L.held -= p.held;
        emit Funded(ref, STEP_RELEASE, parts, 0, 0);
    }

    /// @notice Moves an open purchase's legs to `amount` settlement units, before the program records the new
    ///         amount. An increase places the difference on the funding order's free funds; a decrease frees cash
    ///         first, then the other legs from the last drawn; a stand-in only decreases. Returns the cash tokens held.
    function resize(CardProgram.Purchase storage p, bytes32 ref, uint256 previous, uint256 amount)
        external
        returns (uint256 cash)
    {
        Layout storage L = _layout();
        if (p.standIn && amount > previous) revert CardProgram.InvalidAmount();
        Source[] storage order = L.orders[p.owner][p.version];
        Part[] memory parts = new Part[](order.length);
        Leg[] memory legs = new Leg[](order.length);
        uint256 current;
        for (uint256 i; i < order.length; ++i) {
            legs[i] = _leg(p.owner, ref, _key(order, i), order[i]);
            current += _value(legs[i], order[i], legs[i].held);
        }
        // An increase places only the increment, even on legs a vault's loss left short; a decrease frees only what
        // the legs hold past the new amount, so lowering a purchase never needs more coverage.
        if (amount > previous) {
            _grow(p, ref, order, legs, parts, amount - previous, amount - previous);
        } else if (amount < current) {
            uint256 less = current - amount;
            // Cash first, then the other legs from the last drawn.
            for (uint256 pass; pass < 2 && less != 0; ++pass) {
                for (uint256 i = order.length; i > 0 && less != 0; --i) {
                    Source memory s = order[i - 1];
                    if ((pass == 0) != (s.kind == CASH)) continue;
                    less = _shrinkLeg(legs[i - 1], s, less, parts, i - 1);
                }
            }
        }
        for (uint256 i; i < order.length; ++i) {
            if (order[i].kind == CASH) cash += legs[i].held;
        }
        // The program moves the purchase's held amount by the same difference.
        // forge-lint: disable-next-line(unsafe-typecast)
        L.held = amount > previous ? L.held + uint128(amount - previous) : L.held - uint128(previous - amount);
        if (amount > previous) _checkExposure(L);
        emit Funded(ref, STEP_ADJUST, parts, 0, 0);
    }

    // Views.

    function orderOf(address owner) external view returns (uint32 version, Source[] memory order) {
        Layout storage L = _layout();
        version = L.version[owner];
        order = L.orders[owner][version];
    }

    function orderAt(address owner, uint32 version) external view returns (Source[] memory) {
        return _layout().orders[owner][version];
    }

    function settings() external view returns (uint8 kinds, address collateral_) {
        Layout storage L = _layout();
        return (L.assets, L.collateral);
    }

    /// @notice Settlement units the program's open purchases hold, its cardholders' capped debt to it and how many owe.
    function outstanding() public view returns (uint256 held, uint256 debt, uint256 debtors) {
        Layout storage L = _layout();
        held = L.held;
        CardProgram program = CardProgram(address(this));
        for (uint256 i; i < L.debtors.length; ++i) {
            address owner = L.debtors[i];
            address token = CardConvert.debtToken(program.fundingOf(owner));
            if (token == address(0)) continue;
            (address creditor, uint128 owed) = CORE.debtOf(owner, token);
            if (creditor == address(this) && owed != 0) {
                debt += _toSettlement(owed, _rate(token));
                ++debtors;
            }
        }
    }

    /// @notice The program's live exposure (open holds, capped debt and the given unsettled captures) and the value of
    ///         the collateral its sponsor posted, in settlement units.
    function exposure(uint256 unsettled)
        public
        view
        returns (uint256 holds, uint256 debt, uint256 collateralValue, uint256 total)
    {
        (holds, debt,) = outstanding();
        total = holds + debt + unsettled;
        address c = _layout().collateral;
        if (c != address(0)) collateralValue = ICollateral(c).valueOf(address(this));
    }

    // Internals.

    function _layout() private pure returns (Layout storage L) {
        bytes32 slot = SLOT;
        assembly {
            L.slot := slot
        }
    }

    function _allowed(Layout storage L, uint8 cardLegs) private view returns (uint8) {
        uint8 kinds = L.assets;
        uint8 allowed = cardLegs & (kinds == 0 ? ALL_KINDS : kinds);
        // Other stablecoins spend wherever cash does.
        return allowed & CASH != 0 ? allowed | TOKEN : allowed;
    }

    function _checkExposure(Layout storage L) private view {
        if (L.collateral == address(0)) return;
        (,, uint128 net, uint128 settledNet) = CardProgram(address(this)).ledger();
        (,, uint256 value, uint256 total) = exposure(net > settledNet ? net - settledNet : 0);
        if (total > value) revert OverExposure(total, value);
    }

    function _grow(
        CardProgram.Purchase storage p,
        bytes32 ref,
        Source[] storage order,
        Leg[] memory legs,
        Part[] memory parts,
        uint256 rest,
        uint256 increment
    ) private {
        uint8 allowed = _allowed(_layout(), CardProgram(address(this)).cardOf(p.card).legs);
        for (uint256 i; i < order.length && rest != 0; ++i) {
            Source memory s = order[i];
            Leg memory leg = legs[i];
            if (allowed & s.kind == 0 || leg.settled) continue;
            uint256 free = _free(leg, s, p.owner);
            if (CardConvert.swapper(leg.token, s.kind) != address(0)) {
                rest = _regrow(p, ref, _key(order, i), s, leg, parts, i, free, rest);
                continue;
            }
            uint256 value = _value(leg, s, free);
            uint256 take = rest < value ? rest : value;
            if (take == 0) continue;
            uint256 more = _tokensFor(leg, s, take, value, free);
            _hold(leg, s, p.owner, ref, _key(order, i), leg.held + more, p.expiresAt, false);
            // forge-lint: disable-next-line(unsafe-typecast)
            leg.held += uint128(more);
            parts[i] = _part(s, take, more);
            p.legs |= s.kind;
            rest -= take;
        }
        if (rest != 0) revert CardProgram.InsufficientFunds(increment);
    }

    function _heldParts(Source[] storage order, address owner, bytes32 ref) private view returns (Part[] memory parts) {
        parts = new Part[](order.length);
        for (uint256 i; i < order.length; ++i) {
            Source memory s = order[i];
            Leg memory leg = _leg(owner, ref, _key(order, i), s);
            if (leg.held != 0) parts[i] = _part(s, _value(leg, s, leg.held), leg.held);
        }
    }

    function _cashIndex(Source[] storage order, uint8 allowed) private view returns (uint256, bool) {
        if (allowed & CASH == 0) return (0, false);
        for (uint256 i; i < order.length; ++i) {
            if (order[i].kind == CASH) return (i, true);
        }
        return (0, false);
    }

    function _coverable(Source[] storage order, address owner, bytes32 ref, uint8 allowed, uint256 amount)
        private
        view
        returns (uint256 covered)
    {
        for (uint256 i; i < order.length && covered < amount; ++i) {
            Source memory s = order[i];
            if (allowed & s.kind == 0) continue;
            Leg memory leg = _leg(owner, ref, _key(order, i), s);
            covered += _value(leg, s, _free(leg, s, owner));
        }
        if (covered > amount) covered = amount;
    }

    /// @dev The first source of each kind keys its leg by the kind alone; later ones by their index in the order.
    function _key(Source[] storage order, uint256 i) private view returns (uint256) {
        uint8 kind = order[i].kind;
        for (uint256 j; j < i; ++j) {
            if (order[j].kind == kind) return i;
        }
        return FIRST;
    }

    function _leg(address owner, bytes32 ref, uint256 key, Source memory s) private view returns (Leg memory leg) {
        if (s.kind == CREDIT) {
            CreditLine line = CreditLine(s.source);
            (address lender, address token) = line.partiesOf(s.lineId);
            leg.holdOwner = lender;
            leg.token = token;
            leg.id = line.holdIdOf(address(this), _drawRef(ref, key));
            leg.rate = _rate(token);
        } else {
            leg.holdOwner = owner;
            leg.id = _legId(ref, key == FIRST ? s.kind : LEG_TAG + key);
            if (s.kind == SAVINGS) {
                SavingsFacility facility = SavingsFacility(s.source);
                leg.token = facility.SHARE();
                leg.rate = _rate(facility.ASSET());
            } else {
                leg.token = s.source;
                leg.rate = CardConvert.rateOf(s.source, leg.id);
            }
        }
        _readHold(leg);
    }

    function _readHold(Leg memory leg) private view {
        IReservationCore.HoldRecord memory h = CORE.getHold(leg.holdOwner, leg.id);
        leg.exists = h.token != address(0);
        leg.settled = h.settled;
        leg.held = h.settled ? 0 : h.held;
        leg.refundable = h.captured - h.refunded;
    }

    /// @dev Token units the source could add now: free cash or shares, or the line's undrawn credit.
    function _free(Leg memory leg, Source memory s, address owner) private view returns (uint256) {
        if (s.kind == CREDIT) return CreditLine(s.source).availableCredit(s.lineId);
        return CORE.available(owner, leg.token);
    }

    function _value(Leg memory leg, Source memory s, uint256 units) private view returns (uint256) {
        if (units == 0) return 0;
        // A new leg in another stablecoin is skipped while converting it costs more than the owner allows.
        if (s.kind == TOKEN && !leg.exists && CardConvert.tooCostly(leg.token, leg.rate, s.lineId)) return 0;
        if (s.kind == SAVINGS) units = SavingsFacility(s.source).VAULT().previewRedeem(units);
        return _toSettlement(units, leg.rate);
    }

    /// @dev Token units that pay `take` settlement units out of `units` worth `value`.
    function _tokensFor(Leg memory leg, Source memory s, uint256 take, uint256 value, uint256 units)
        private
        view
        returns (uint256 tokens)
    {
        if (take >= value) return units;
        tokens = _toTokenUp(take, leg.rate);
        if (s.kind == SAVINGS) tokens = SavingsFacility(s.source).VAULT().previewWithdraw(tokens);
        if (tokens > units) tokens = units;
    }

    /// @dev Sets the leg's hold to `tokens`, placing it if new.
    function _hold(
        Leg memory leg,
        Source memory s,
        address owner,
        bytes32 ref,
        uint256 key,
        uint256 tokens,
        uint64 expiresAt,
        bool standIn
    ) private {
        if (s.kind == CREDIT) {
            CreditLine line = CreditLine(s.source);
            if (!leg.exists && !CardProgram(address(this)).approvedSource(s.source)) {
                revert CardProgram.SourceNotApproved(s.source);
            }
            // forge-lint: disable-next-line(unsafe-typecast)
            if (leg.exists) line.resize(leg.id, uint128(tokens));
            // forge-lint: disable-next-line(unsafe-typecast)
            else line.draw(s.lineId, owner, _drawRef(ref, key), uint128(tokens), expiresAt);
        } else if (leg.exists) {
            CardConvert.lock(leg.id, leg.token, s.kind, leg.rate);
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.adjust(owner, leg.id, uint128(tokens));
        } else {
            CardConvert.lock(leg.id, leg.token, s.kind, leg.rate);
            if (s.kind == SAVINGS && !CardProgram(address(this)).approvedSource(s.source)) {
                revert CardProgram.SourceNotApproved(s.source);
            }
            CORE.holdFrom(
                owner,
                IReservationCore.HoldRequest({
                    token: leg.token,
                    id: leg.id,
                    // Leg amounts derive from 64-bit purchases at recorded rates.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    amount: uint128(tokens),
                    expiresAt: expiresAt,
                    payee: s.kind == SAVINGS ? s.source : address(this),
                    standIn: standIn
                })
            );
        }
    }

    function _captureLeg(Leg memory leg, Source memory s, uint256 tokens, bool isFinal) private {
        if (s.kind == SAVINGS) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (tokens != 0) SavingsFacility(s.source).capture(leg.holdOwner, leg.id, uint128(tokens), isFinal);
            else CORE.release(leg.holdOwner, leg.id);
            return;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        if (tokens != 0) CORE.capture(leg.holdOwner, leg.id, uint128(tokens), isFinal);
        else CORE.release(leg.holdOwner, leg.id);
        if (s.kind == CREDIT) CreditLine(s.source).sync(leg.id);
    }

    /// @dev Charges what the capture still needs to the owner's cash token as capped debt, within the cap's headroom.
    function _chargeDebt(CardProgram.Purchase storage p, bytes32 ref, address owner, address cashToken, uint256 rest)
        private
        returns (uint256 debt, uint256 tokens)
    {
        if (cashToken == address(0)) return (0, 0);
        uint256 rate = _rate(cashToken);
        (address creditor, uint128 owed) = CORE.debtOf(owner, cashToken);
        if (owed != 0 && creditor != address(this)) return (0, 0);
        uint256 cap = CORE.debtCap(owner, address(this), cashToken);
        uint256 headroom = cap > owed ? cap - owed : 0;
        tokens = _toTokenUp(rest, rate);
        if (tokens > headroom) {
            tokens = headroom;
            debt = _toSettlement(tokens, rate);
        } else {
            debt = rest;
        }
        if (tokens == 0) return (0, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        CORE.charge(owner, cashToken, _nextDebtId(ref, owner), uint128(tokens), address(this), false);
        p.legs |= DEBT;
        noteDebtor(owner);
    }

    function _nextDebtId(bytes32 ref, address owner) private view returns (bytes32 id) {
        for (uint256 k;; ++k) {
            id = _legId(ref, DEBT_TAG + k);
            if (CORE.getHold(owner, id).token == address(0)) return id;
        }
    }

    /// @dev Refunds up to `rest` from the purchase's capture debt charges, latest first, then its late charge.
    function _refundCharges(
        bytes32 ref,
        address owner,
        address cashToken,
        uint256 rate,
        uint256 rest,
        Part[] memory parts
    ) private returns (uint256) {
        uint256 count;
        while (CORE.getHold(owner, _legId(ref, DEBT_TAG + count)).token != address(0)) ++count;
        Part memory part = parts[parts.length - 1];
        for (uint256 k = count + 1; k > 0 && rest != 0; --k) {
            // The late charge (tag 8) refunds after every capture charge.
            Leg memory leg;
            leg.holdOwner = owner;
            leg.token = cashToken;
            leg.id = k == 1 ? _legId(ref, CHARGED) : _legId(ref, DEBT_TAG + k - 2);
            leg.rate = rate;
            _readHold(leg);
            if (leg.refundable == 0) continue;
            uint256 value = _toSettlement(leg.refundable, rate);
            uint256 take = rest < value ? rest : value;
            uint256 tokens = take >= value ? leg.refundable : _min(_toTokenUp(take, rate), leg.refundable);
            SafeTransferLib.safeTransferFrom(cashToken, msg.sender, address(this), tokens);
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.refund(owner, leg.id, uint128(tokens));
            part.kind = CASH;
            part.source = cashToken;
            part.amount += take;
            part.tokens += tokens;
            rest -= take;
        }
        return rest;
    }

    function _refundable(Source[] storage order, address owner, bytes32 ref, address cashToken, uint256 rate)
        private
        view
        returns (uint256 total)
    {
        for (uint256 i; i < order.length; ++i) {
            Leg memory leg = _leg(owner, ref, _key(order, i), order[i]);
            total += _value(leg, order[i], leg.refundable);
        }
        uint256 count;
        while (CORE.getHold(owner, _legId(ref, DEBT_TAG + count)).token != address(0)) ++count;
        for (uint256 k; k <= count; ++k) {
            IReservationCore.HoldRecord memory h =
                CORE.getHold(owner, k == count ? _legId(ref, CHARGED) : _legId(ref, DEBT_TAG + k));
            if (h.token == cashToken) total += _toSettlement(h.captured - h.refunded, rate);
        }
    }

    function _refundLeg(
        address owner,
        bytes32 ref,
        uint256 i,
        uint256 key,
        Source memory s,
        uint256 rest,
        Part[] memory parts
    ) private returns (uint256) {
        Leg memory leg = _leg(owner, ref, key, s);
        if (leg.refundable == 0) return rest;
        uint256 value = _value(leg, s, leg.refundable);
        uint256 take = rest < value ? rest : value;
        if (take == 0) return rest;
        uint256 tokens;
        if (s.kind == SAVINGS) {
            SavingsFacility facility = SavingsFacility(s.source);
            address asset = facility.ASSET();
            uint256 paid = _toTokenUp(take, leg.rate);
            SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), paid);
            SafeTransferLib.safeApprove(asset, address(facility), paid);
            tokens = facility.refund(owner, leg.id, paid);
        } else if (CardConvert.swapper(leg.token, s.kind) != address(0)) {
            tokens = CardConvert.refund(owner, leg.id, leg.token, leg.refundable, take);
        } else {
            tokens = take >= value ? leg.refundable : _min(_toTokenUp(take, leg.rate), leg.refundable);
            SafeTransferLib.safeTransferFrom(leg.token, msg.sender, address(this), tokens);
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.refund(leg.holdOwner, leg.id, uint128(tokens));
            if (s.kind == CREDIT) CreditLine(s.source).sync(leg.id);
        }
        Part memory part = parts[i];
        part.kind = s.kind;
        part.source = s.source;
        part.lineId = s.lineId;
        part.amount += take;
        part.tokens += tokens;
        return rest - take;
    }

    function _shrinkLeg(Leg memory leg, Source memory s, uint256 less, Part[] memory parts, uint256 i)
        private
        returns (uint256)
    {
        if (!leg.exists || leg.settled || leg.held == 0) return less;
        uint256 value = _value(leg, s, leg.held);
        uint256 take = less < value ? less : value;
        uint256 tokens = _tokensFor(leg, s, take, value, leg.held);
        // A converted leg keeps its share of the purchase at the locked rate, rounded up.
        if (take < value && (s.kind == CASH || s.kind == TOKEN) && leg.rate != RATE_ONE) {
            tokens = leg.held - uint256(leg.held).mulDivUp(value - take, value);
        }
        if (tokens == 0) return less;
        uint256 keep = leg.held - tokens;
        if (keep == 0) {
            CORE.release(leg.holdOwner, leg.id);
            if (s.kind == CREDIT) CreditLine(s.source).sync(leg.id);
            leg.settled = true;
        } else if (s.kind == CREDIT) {
            // forge-lint: disable-next-line(unsafe-typecast)
            CreditLine(s.source).resize(leg.id, uint128(keep));
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.adjust(leg.holdOwner, leg.id, uint128(keep));
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        leg.held = uint128(keep);
        parts[i] = _part(s, take, tokens);
        return less - take;
    }

    function _forwardAll(Source[] storage order, address cashToken) private {
        address to = CardProgram(address(this)).SETTLEMENT_ACCOUNT();
        if (cashToken != address(0)) _forward(cashToken, to);
        for (uint256 i; i < order.length; ++i) {
            uint8 kind = order[i].kind;
            if (kind == CREDIT) _forward(CreditLine(order[i].source).tokenOf(order[i].lineId), to);
            else if (kind == TOKEN) _forward(order[i].source, to);
        }
    }

    function _forward(address token, address to) private {
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance != 0) SafeTransferLib.safeTransfer(token, to, balance);
    }

    function _part(Source memory s, uint256 amount, uint256 tokens) private pure returns (Part memory) {
        return Part({ kind: s.kind, source: s.source, lineId: s.lineId, amount: amount, tokens: tokens });
    }

    function _sumIndex(uint8 kind) private pure returns (uint256) {
        return kind == CASH || kind == TOKEN ? 0 : kind == SAVINGS ? 1 : 2;
    }

    function _drawRef(bytes32 ref, uint256 key) private pure returns (bytes32) {
        return key == FIRST ? ref : keccak256(abi.encode(ref, key));
    }

    function _legId(bytes32 ref, uint256 tag) private view returns (bytes32) {
        // Tags fit in a byte: legs use 16 + an index below 8, charges 64 and up, the late charge 8.
        // forge-lint: disable-next-line(unsafe-typecast)
        return keccak256(abi.encode(address(this), ref, uint8(tag)));
    }

    function _rate(address token) private view returns (uint256) {
        return CardConvert.current(token);
    }

    /// @dev Grows a converted leg by up to rest settlement units: the whole leg re-prices at today's rate and holds
    ///      what its old value plus the increment needs. Returns what is left to place.
    function _regrow(
        CardProgram.Purchase storage p,
        bytes32 ref,
        uint256 key,
        Source memory s,
        Leg memory leg,
        Part[] memory parts,
        uint256 i,
        uint256 free,
        uint256 rest
    ) private returns (uint256) {
        (uint256 take, uint256 total, uint256 rate) = CardConvert.growth(
            leg.token, s.kind == TOKEN && !leg.exists ? s.lineId : BPS, leg.held, leg.rate, free, rest
        );
        if (take == 0) return rest;
        leg.rate = rate;
        _hold(leg, s, p.owner, ref, key, total, p.expiresAt, false);
        leg.exists = true;
        // forge-lint: disable-next-line(unsafe-typecast)
        leg.held = uint128(total);
        parts[i] = _part(s, take, total);
        p.legs |= s.kind;
        return rest - take;
    }

    function _toSettlement(uint256 tokens, uint256 rate) private pure returns (uint256) {
        return rate == RATE_ONE ? tokens : tokens.mulDiv(rate, RATE_ONE);
    }

    function _toTokenUp(uint256 units, uint256 rate) private pure returns (uint256) {
        return rate == RATE_ONE ? units : units.mulDivUp(RATE_ONE, rate);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
    // forge-lint: disable-end(reentrancy-no-eth)
}
// forge-lint: disable-end(calls-loop)
