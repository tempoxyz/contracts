// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Conversion } from "./Conversion.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { CAPTURE_FINAL, CAPTURE_FREE, ISource } from "./interfaces/ISource.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

/// @title CashSource
/// @notice A card program's cash funding source: holds on a cardholder's stablecoin balance in the core, placed and
///         captured by this contract, which is also their payee. Captures past a hold take the owner's free balance,
///         within the budget the owner gave this contract; charges do the same with no hold. Nothing is taken past the
///         owner's free balance: the program's issuer absorbs what the owner cannot pay. A leg in a stablecoin other than the program's settlement token locks
///         the conversion rate when it is placed (only while the Conversion quotes it against a fresh reference rate
///         within the owner's maximum cost) and converts what it captures through the program's Conversion. The owner
///         pays the locked price while the venue stays within FX_BAND_BPS of it, the issuer carrying an adverse
///         difference and keeping a favourable one; past the band the owner pays the venue's price less FX_BAND_BPS in
///         the owner's favour. The owner never pays past the hold's capture limit; what it does not buy falls to the
///         issuer. A late charge of a purchase whose hold expired prices the same way against the rate it locked.
///         The band's tolerance is the one the core fixed into the hold when it was placed, never the owner's terms at
///         capture. A refund of a converted leg pays the token back at the rate its
///         captures and charges paid the settlement account, whatever the market or the reference rates do since.
/// @dev `position`: the token in its low 160 bits and the owner's maximum conversion cost in basis points in the 16
///      bits above. Everything this contract receives in the settlement token is paid on to the settlement account in
///      the same call, and `sweep` forwards anything sent to it otherwise. Not upgradeable.
/// @custom:reentrancy-guard _locked
// Calls go to the fixed core, the program's own Conversion and its tokens, inside program-driven steps.
// forge-lint: disable-start(reentrancy-no-eth, calls-loop)
contract CashSource is ISource {
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant RATE_MASK = type(uint112).max;
    /// @notice How far the venue may move from a converted leg's locked rate before its owner shares the move.
    uint256 public constant FX_BAND_BPS = 200;
    /// @dev The widest band around a locked rate this source asks for, tolerance included: Conversion's
    ///      MAX_ANCHOR_BAND_BPS.
    uint256 internal constant MAX_ANCHOR_BAND_BPS = 2000;
    /// @notice The most converted tokens this source keeps open totals for at once. A token whose open total is zero
    ///         gives its place to the next one; with every place taken by open holds, a leg in another token is not
    ///         placed and the purchase falls through to its next source.
    uint256 public constant MAX_CONVERTED_TOKENS = 8;

    /// @notice What the source is: cash.
    uint8 public constant KIND = 1;
    /// @notice The card authorization contract this source serves.
    ICardAuth public immutable PROGRAM;
    /// @notice Where every capture and charge is paid.
    address public immutable SETTLEMENT_ACCOUNT;

    /// @notice What a converted leg's captures and charges spent of its token and paid the settlement account in a
    ///         settlement token (never what the issuer absorbed), less what refunds gave back: the rate its refunds pay
    ///         the token back at.
    struct Paid {
        uint128 tokens;
        uint128 units;
    }

    /// @dev A converted leg's locked rate (settlement units per token unit, 18 decimals) in the low 112 bits, the
    ///      capture tolerance in basis points the core fixed into its hold when it was placed in the 16 above, and, in
    ///      the high 128, the settlement value its open hold counts toward openConverted. An expired hold keeps its
    ///      rate and tolerance, valued at zero, for a late charge.
    mapping(bytes32 legId => uint256) private _locks;
    /// @notice What a converted leg paid in each settlement token, which its refunds in that token convert back at.
    mapping(bytes32 legId => mapping(address settlement => Paid)) public paidOf;
    /// @dev Per converted token: the settlement value of its open converted holds at the rates they locked, above
    ///      the low 8 bits, which hold its place in _convertedTokens plus one (zero while it has none). A token keeps
    ///      its place, and so its slot, while its total is zero, until another token needs the place.
    mapping(address token => uint256) private _converted;
    /// @dev The converted tokens with a place, at most MAX_CONVERTED_TOKENS.
    address[] private _convertedTokens;

    bool private transient _locked;

    /// @notice A converted leg's capture or charge spent `tokens` of `token` for `paid` settlement units.
    event Converted(bytes32 indexed legId, address indexed token, uint256 tokens, uint256 paid);

    error NotProgram();
    error Reentrancy();
    error ZeroAddress();

    modifier onlyProgram() {
        if (msg.sender != address(PROGRAM)) revert NotProgram();
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(ICardAuth program) {
        if (address(program) == address(0)) revert ZeroAddress();
        PROGRAM = program;
        SETTLEMENT_ACCOUNT = program.SETTLEMENT_ACCOUNT();
    }

    // Views.

    function coverable(address owner, bytes32 position) external view returns (uint256) {
        (address token, uint256 maxCost) = _decode(position);
        uint256 free = CORE.available(owner, token);
        address settlement = PROGRAM.settlementToken();
        if (token == settlement) return free;
        (uint256 rate, bool ok) = _rate(token, settlement, maxCost);
        return ok ? free.mulDiv(rate, ONE) : 0;
    }

    /// @notice The rate a converted leg locked: settlement units per token unit, with 18 decimals; zero for none.
    function lockedRate(bytes32 legId) public view returns (uint256) {
        return _locks[legId] & RATE_MASK;
    }

    /// @notice The capture tolerance in basis points a converted leg's hold was placed with: what its band and late
    ///         charge use, whatever the owner's terms say since; zero for none.
    function lockedTolerance(bytes32 legId) public view returns (uint256) {
        return _locks[legId] >> 112 & type(uint16).max;
    }

    /// @notice The settlement value of every open converted hold, at the rates they locked: the sum of
    ///         openConvertedOf over convertedTokens.
    function openConverted() external view returns (uint256 open) {
        address[] storage tokens = _convertedTokens;
        for (uint256 i; i < tokens.length; ++i) {
            open += _converted[tokens[i]] >> 8;
        }
    }

    /// @notice The settlement value of the open converted holds in `token`, at the rates they locked.
    function openConvertedOf(address token) external view returns (uint256) {
        return _converted[token] >> 8;
    }

    /// @notice The converted tokens this source keeps open totals for (at most MAX_CONVERTED_TOKENS), each with its
    ///         openConvertedOf, which is zero for a token whose holds all closed until another token takes its place.
    function convertedTokens() external view returns (address[] memory tokens, uint256[] memory open) {
        tokens = _convertedTokens;
        open = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            open[i] = _converted[tokens[i]] >> 8;
        }
    }

    function held(address owner, bytes32, bytes32 legId) public view returns (uint256) {
        uint256 tokens = CORE.getHold(owner, address(this), legId).held;
        uint256 rate = lockedRate(legId);
        return rate == 0 ? tokens : tokens.mulDiv(rate, ONE);
    }

    function refundable(address, bytes32, bytes32) external pure returns (uint256) {
        return type(uint256).max;
    }

    function toleranceBps(address owner, bytes32 position) external view returns (uint16) {
        (address token,) = _decode(position);
        return CORE.captureTolerance(owner, address(this), token);
    }

    // Program.

    function hold(address owner, bytes32 position, bytes32 legId, uint256 units, uint64 expiresAt)
        external
        onlyProgram
        returns (uint256)
    {
        (address token, uint256 maxCost) = _decode(position);
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        bool live = h.token != address(0);
        if (units == 0) {
            if (live) _release(owner, token, legId);
            return 0;
        }
        address settlement = PROGRAM.settlementToken();
        uint256 rate = ONE;
        uint256 tokens = units;
        uint256 tolerance;
        if (token != settlement) {
            uint256 locked = lockedRate(legId);
            // Every place taken by another token's open holds: the leg stays as it is.
            if (_placeOf(token) == 0) return live ? uint256(h.held).mulDiv(locked, ONE) : 0;
            // The core fixes a hold's tolerance when it places it, from the owner's terms then; a live hold keeps it.
            tolerance =
                live && locked != 0 ? lockedTolerance(legId) : CORE.captureTolerance(owner, address(this), token);
            if (live && units <= uint256(h.held).mulDiv(locked, ONE)) {
                // A smaller leg keeps the rate it locked.
                rate = locked;
                tokens = units.mulDivUp(ONE, rate);
            } else {
                bool ok;
                (rate, ok) = _rate(token, settlement, maxCost);
                if (!ok) return live ? uint256(h.held).mulDiv(locked, ONE) : 0;
                tokens = _tokensFor(token, settlement, units, rate);
                // When the venue asks more than the rate implies, the lock is the price the hold reserved, so a
                // capture within it takes what the hold holds.
                if (tokens > units.mulDivUp(ONE, rate)) rate = units.mulDivUp(ONE, tokens);
            }
        }
        uint256 cap = (live ? h.held : 0) + CORE.available(owner, token);
        if (tokens > cap) {
            tokens = cap;
            units = tokens.mulDiv(rate, ONE);
        }
        if (tokens == 0) {
            if (live) _release(owner, token, legId);
            return 0;
        }
        if (!live) CORE.holdFrom(owner, _request(token, legId, tokens, expiresAt));
        else if (tokens != h.held) _resize(owner, token, legId, tokens);
        if (token != settlement) _lock(token, legId, rate, tokens, tolerance);
        return units;
    }

    function capture(address owner, bytes32 position, bytes32 legId, uint256 units, uint8 flags)
        external
        onlyProgram
        returns (uint256 paid, uint256 covered)
    {
        (address token,) = _decode(position);
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        if (h.token == address(0)) return (0, 0);
        bool isFinal = flags & CAPTURE_FINAL != 0;
        bool free = flags & CAPTURE_FREE != 0;
        address settlement = PROGRAM.settlementToken();
        uint256 rate = lockedRate(legId);
        if (rate == 0) {
            uint256 amount = units < h.held ? units : h.held;
            // Past the hold, CAPTURE_FREE also takes the owner's free cash.
            if (units > h.held && free) amount = h.held + _excessRoom(owner, token, units - h.held);
            if (amount != 0 || isFinal) _take(owner, token, legId, h, amount, isFinal);
            _forward(settlement);
            return (amount, amount);
        }
        (paid, covered) = _captureConverted(owner, token, settlement, legId, h, units, rate, free);
        if (isFinal) _release(owner, token, legId);
    }

    function charge(address owner, bytes32 position, bytes32 legId, uint256 units)
        external
        onlyProgram
        returns (uint256 paid, uint256 covered)
    {
        (address token, uint256 maxCost) = _decode(position);
        address settlement = PROGRAM.settlementToken();
        if (token == settlement) {
            paid = _excessRoom(owner, token, units);
            if (paid == 0) return (0, 0);
            CORE.charge(owner, token, legId, paid.toUint128(), address(this));
            _forward(settlement);
            return (paid, paid);
        }
        Conversion c = _conversion();
        uint256 rate = lockedRate(legId);
        uint256 band;
        uint256 cost;
        uint256 tolerance;
        if (rate != 0) {
            // A late charge consumes the rate its expired hold locked and prices against it as a capture would, the
            // tolerance the hold was placed with on what that rate promised standing in for the capture limit.
            tolerance = lockedTolerance(legId);
            _setLock(token, legId, 0, 0, 0);
            band = _band(tolerance);
            cost = _anchoredCost(c, token, settlement, units, rate, band);
        }
        if (cost == 0) {
            band = 0;
            (, bool ok) = _rate(token, settlement, maxCost);
            if (!ok) return (0, 0);
            cost = c.quoteOut(token, settlement, units);
        }
        uint256 price = rate == 0 ? cost : _bandPrice(units, rate, cost);
        uint256 most = _excessRoom(owner, token, price);
        // The hold's tolerance on the locked price caps what the owner pays; the issuer pays the rest of the purchase.
        uint256 limit = rate == 0 ? price : units.mulDivUp(ONE, rate).mulDiv(BPS + tolerance, BPS);
        bool capped = most > limit;
        if (capped) most = limit;
        if (most == 0) return (0, 0);
        CORE.charge(owner, token, legId, most.toUint128(), address(this));
        paid = _swap(c, token, settlement, legId, units, most, cost, rate, band);
        // Short of the price, the owner's tokens cover their share of it and the rest falls to later sources.
        covered = capped || most == price ? units : units.mulDiv(most, price);
        // What the swap fetched past that (a favourable move, or rounding) stays with the settlement account.
        if (paid > covered) paid = covered;
        _paid(legId, settlement, most, paid);
    }

    /// @notice Ends a leg. A converted leg whose hold expired (or that the core already ended) keeps its locked rate
    ///         for a late charge; any other drops it. Either way it no longer counts toward openConverted.
    function release(address owner, bytes32 position, bytes32 legId) external onlyProgram {
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        address token = h.token;
        // Expiries are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        bool expired = token == address(0) || block.timestamp >= h.expiresAt;
        if (token != address(0)) CORE.release(owner, address(this), legId);
        // A hold the core already ended counts toward the token its position names, which placed it.
        else (token,) = _decode(position);
        uint256 rate = lockedRate(legId);
        if (rate != 0) _setLock(token, legId, expired ? rate : 0, 0, lockedTolerance(legId));
    }

    /// @dev A converted leg pays back, for what its captures and charges paid in today's settlement token, the tokens
    ///      they spent at the same rate, out of the Conversion's float (or, when it is short or does not trust
    ///      this source, bought at the venue); a refund past that converts at today's price.
    function refund(address owner, bytes32 position, bytes32 legId, uint256 units) external onlyProgram {
        (address token,) = _decode(position);
        address settlement = PROGRAM.settlementToken();
        uint256 tokens = units;
        if (token != settlement) {
            Conversion c = _conversion();
            SafeTransferLib.safeApprove(settlement, address(c), units);
            Paid storage p = paidOf[legId][settlement];
            uint256 within = units < p.units ? units : p.units;
            tokens = 0;
            if (within != 0) {
                uint256 due = within.mulDiv(p.tokens, p.units);
                (p.tokens, p.units) = (p.tokens - due.toUint128(), p.units - within.toUint128());
                tokens = _payBack(c, token, settlement, within, due);
            }
            if (units > within) tokens += _convert(c, settlement, token, units - within);
            SafeTransferLib.safeApprove(settlement, address(c), 0);
            // What buying the tokens did not spend goes back with the rest of the settlement token.
            _forward(settlement);
        }
        if (tokens != 0) CORE.refund(owner, token, address(this), legId, tokens.toUint128());
    }

    /// @notice Pays what this source holds of `token` (anything sent to it outside a capture or charge) on to the
    ///         settlement account.
    function sweep(address token) external {
        if (_locked) revert Reentrancy();
        _forward(token);
    }

    // Internals.

    /// @dev Captures `units` of a converted leg at the band price around its locked `rate`: the owner's tokens are
    ///      capped by the hold's capture limit (the issuer pays what the cap leaves) and by what the owner has (the
    ///      rest stays for the purchase's other legs). Returns the settlement units paid and the units it covered.
    function _captureConverted(
        address owner,
        address token,
        address settlement,
        bytes32 legId,
        IReservationCore.HoldRecord memory h,
        uint256 units,
        uint256 rate,
        bool free
    ) private returns (uint256 paid, uint256 covered) {
        Conversion c = _conversion();
        uint256 band = _band(lockedTolerance(legId));
        uint256 cost = _anchoredCost(c, token, settlement, units, rate, band);
        if (cost == 0) {
            // Past the band and the owner's tolerance the venue prices only while the reference rates agree with it.
            band = 0;
            cost = c.quoteOut(token, settlement, units);
        }
        // What the owner can put toward the band price: its hold and, past it, free tokens.
        uint256 price = _bandPrice(units, rate, cost);
        uint256 tokens = price;
        if (tokens > h.held) tokens = h.held + (free ? _excessRoom(owner, token, tokens - h.held) : 0);
        bool capped = tokens > h.captureLimit;
        if (capped) tokens = h.captureLimit;
        if (tokens == 0) return (0, 0);
        CORE.capture(owner, address(this), legId, tokens.toUint128(), false);
        _setLock(token, legId, rate, tokens < h.held ? h.held - tokens : 0, lockedTolerance(legId));
        paid = _swap(c, token, settlement, legId, units, tokens, cost, rate, band);
        // The owner's tokens cover their share of the band price; the rest falls to the purchase's later legs.
        covered = tokens == price ? units : units.mulDiv(tokens, price);
        if (capped) {
            // Stopped by the capture limit, the issuer pays the rest of what the hold was placed for (its tokens at the
            // locked rate), never the part of the purchase beyond it.
            uint256 own = uint256(h.held).mulDiv(rate, ONE);
            if (own > units) own = units;
            if (own > covered) covered = own;
        }
        // What the swap fetched past that (a favourable move, or rounding) stays with the settlement account.
        if (paid > covered) paid = covered;
        // Refunds of what the settlement account was paid give back every token spent; the issuer's share is never
        // refunded.
        _paid(legId, settlement, tokens, paid);
    }

    /// @dev The tokens `units` cost at the venue, checked against the locked `rate` within `band` basis points when
    ///      the Conversion trusts this source; zero when it does not, or the venue strays past the band.
    function _anchoredCost(Conversion c, address token, address settlement, uint256 units, uint256 rate, uint256 band)
        private
        view
        returns (uint256)
    {
        if (!c.trusted(address(this))) return 0;
        try c.quoteOutAnchored(token, settlement, units, rate, band) returns (uint256 cost) {
            return cost;
        } catch {
            return 0;
        }
    }

    /// @dev The band around a locked rate for a hold placed with `tolerance`: FX_BAND_BPS plus the tolerance, at most
    ///      the widest band the Conversion accepts.
    function _band(uint256 tolerance) private pure returns (uint256) {
        uint256 most = MAX_ANCHOR_BAND_BPS - FX_BAND_BPS;
        return FX_BAND_BPS + (tolerance < most ? tolerance : most);
    }

    /// @dev What the owner pays in tokens for `units` the venue sells for `cost`, against the locked `rate`: the
    ///      locked price while the venue is within FX_BAND_BPS of it, else the venue's price moved FX_BAND_BPS toward
    ///      the owner (fewer tokens on an adverse move, more on a favourable one).
    function _bandPrice(uint256 units, uint256 rate, uint256 cost) private pure returns (uint256) {
        uint256 locked = units.mulDivUp(ONE, rate);
        uint256 low = cost.mulDiv(BPS - FX_BAND_BPS, BPS);
        if (low > locked) return low;
        uint256 high = cost.mulDivUp(BPS + FX_BAND_BPS, BPS);
        return high < locked ? high : locked;
    }

    /// @dev Adds what a converted capture or charge spent and paid to the rate the leg's refunds pay back at.
    function _paid(bytes32 legId, address settlement, uint256 tokens, uint256 units) private {
        Paid storage p = paidOf[legId][settlement];
        (p.tokens, p.units) = (p.tokens + tokens.toUint128(), p.units + units.toUint128());
    }

    /// @dev Turns `units` of the settlement token this source holds into `due` tokens for a refund: from the
    ///      Conversion's float when it trusts this source and holds them, else exactly `due` at the venue when `units`
    ///      buys it, else all `units` buy. Returns the tokens it got.
    function _payBack(Conversion c, address token, address settlement, uint256 units, uint256 due)
        private
        returns (uint256)
    {
        if (due == 0) return 0;
        if (c.trusted(address(this)) && IERC20Like(token).balanceOf(address(c)) >= due) {
            c.convertAt(settlement, token, units, due, address(this));
            return due;
        }
        if (c.quoteOut(settlement, token, due) > units) {
            return c.swapExactIn(settlement, token, units, 0, address(this));
        }
        c.swapExactOut(settlement, token, due, units, address(this));
        return due;
    }

    /// @dev Converts `units` of the settlement token at today's reference rate out of the float when the Conversion
    ///      trusts this source, else at the venue.
    function _convert(Conversion c, address settlement, address token, uint256 units) private returns (uint256) {
        return c.trusted(address(this))
            ? c.convertAtMid(settlement, token, units, address(this))
            : c.swapExactIn(settlement, token, units, 0, address(this));
    }

    /// @dev Converts `tokens` into the settlement token for the settlement account: exactly `units` when they buy it
    ///      (`cost` being the venue's price for them), else all of them. With a band it trades against the locked
    ///      `rate` within it; without, within the Conversion's floor on the reference rates. Returns the settlement
    ///      units paid, at most `units`.
    function _swap(
        Conversion c,
        address token,
        address settlement,
        bytes32 legId,
        uint256 units,
        uint256 tokens,
        uint256 cost,
        uint256 rate,
        uint256 band
    ) private returns (uint256 paid) {
        SafeTransferLib.safeApprove(token, address(c), tokens);
        if (cost <= tokens) {
            uint256 spent = band != 0
                ? c.swapExactOutAnchored(token, settlement, units, tokens, rate, band, SETTLEMENT_ACCOUNT)
                : c.swapExactOut(token, settlement, units, tokens, SETTLEMENT_ACCOUNT);
            // What the owner paid past the venue's price (a favourable move, or rounding) goes with the capture.
            if (tokens > spent) SafeTransferLib.safeTransfer(token, SETTLEMENT_ACCOUNT, tokens - spent);
            paid = units;
        } else {
            paid = band != 0
                ? c.swapExactInAnchored(token, settlement, tokens, rate, band, SETTLEMENT_ACCOUNT)
                : c.swapExactIn(token, settlement, tokens, 0, SETTLEMENT_ACCOUNT);
            // A unit of rounding past `units` goes with the capture, which never pays more than it asked.
            if (paid > units) paid = units;
        }
        emit Converted(legId, token, tokens, paid);
    }

    /// @dev Takes `amount` for a leg: a capture up to the hold's capture limit, and a charge for the rest. The core
    ///      bounds a hold's overage by its own tolerance, but a purchase spread across legs takes its overage on this
    ///      leg, which CardAuth checked against the purchase's tolerance. Only settlement-token legs take it.
    function _take(
        address owner,
        address token,
        bytes32 legId,
        IReservationCore.HoldRecord memory h,
        uint256 amount,
        bool isFinal
    ) private {
        uint256 extra = amount > h.captureLimit ? amount - h.captureLimit : 0;
        amount -= extra;
        if (amount != 0 || isFinal) CORE.capture(owner, address(this), legId, amount.toUint128(), isFinal);
        if (extra != 0) CORE.charge(owner, token, legId, extra.toUint128(), address(this));
    }

    /// @dev What a capture or charge may take past a hold, up to `want`: the owner's free balance, within the
    ///      owner's budget for this source.
    function _excessRoom(address owner, address token, uint256 want) private view returns (uint256 room) {
        room = CORE.available(owner, token);
        IReservationCore.Budget memory b = CORE.budget(owner, address(this), token);
        uint256 used = uint256(b.spent) + b.outstanding;
        uint256 budget = b.limit > used ? b.limit - used : 0;
        if (room > budget) room = budget;
        if (room > want) room = want;
    }

    /// @dev Settlement units per token unit now, and whether converting at it costs at most `maxCost`; zero when the
    ///      Conversion cannot quote it (no venue, a stale or missing reference rate, or a venue straying from it).
    function _rate(address token, address settlement, uint256 maxCost) private view returns (uint256 rate, bool ok) {
        Conversion c = _conversion();
        if (address(c) == address(0) || !c.converts(token, settlement)) return (0, false);
        try c.rate(token, settlement) returns (uint256 r) {
            rate = r;
        } catch {
            return (0, false);
        }
        ok = rate != 0 && c.costBps(token, settlement, rate) <= maxCost;
    }

    /// @dev The tokens a leg holds for `units` at `rate`: at least what the venue charges for them today.
    function _tokensFor(address token, address settlement, uint256 units, uint256 rate)
        private
        view
        returns (uint256 tokens)
    {
        tokens = units.mulDivUp(ONE, rate);
        uint256 cost = _conversion().quoteOut(token, settlement, units);
        if (cost > tokens) tokens = cost;
    }

    /// @dev Sets a converted leg's locked `rate` (zero drops it) and its hold's `tolerance` with `tokens` open in its
    ///      hold, keeping the open total of its `token` in step. Only hold raises a leg's value, after _place.
    function _setLock(address token, bytes32 legId, uint256 rate, uint256 tokens, uint256 tolerance) private {
        uint256 word = _locks[legId];
        uint256 value = tokens.mulDiv(rate, ONE);
        uint256 before = word >> 128;
        // Both values fit in 128 bits, so shifting them past the place bits loses nothing.
        if (value != before) _converted[token] = _converted[token] + (value << 8) - (before << 8);
        uint256 next =
            rate == 0 ? 0 : rate.toUint112() | uint256(tolerance.toUint16()) << 112 | uint256(value.toUint128()) << 128;
        if (next != word) _locks[legId] = next;
    }

    /// @dev Locks a converted leg as _setLock does, first giving its `token` the place _placeOf found unless it has
    ///      one. Hold calls it only after _placeOf found a place, so a leg that never holds writes no place.
    function _lock(address token, bytes32 legId, uint256 rate, uint256 tokens, uint256 tolerance) private {
        if (_converted[token] == 0) {
            uint256 place = _placeOf(token);
            address[] storage list = _convertedTokens;
            if (place > list.length) {
                list.push(token);
            } else {
                delete _converted[list[place - 1]];
                list[place - 1] = token;
            }
            _converted[token] = place;
        }
        _setLock(token, legId, rate, tokens, tolerance);
    }

    /// @dev The place `token` has or would take among the converted tokens, plus one: its own, else a new one while
    ///      fewer than MAX_CONVERTED_TOKENS exist, else that of the first token whose open total is zero. Zero when
    ///      every place holds open value.
    function _placeOf(address token) private view returns (uint256) {
        uint256 word = _converted[token];
        if (word != 0) return word & 0xff;
        address[] storage list = _convertedTokens;
        uint256 n = list.length;
        if (n < MAX_CONVERTED_TOKENS) return n + 1;
        for (uint256 i; i < n; ++i) {
            if (_converted[list[i]] >> 8 == 0) return i + 1;
        }
        return 0;
    }

    function _resize(address owner, address token, bytes32 legId, uint256 tokens) private {
        if (tokens == 0) _release(owner, token, legId);
        else CORE.adjust(owner, address(this), legId, tokens.toUint128());
    }

    function _release(address owner, address token, bytes32 legId) private {
        CORE.release(owner, address(this), legId);
        if (_locks[legId] != 0) _setLock(token, legId, 0, 0, 0);
    }

    function _forward(address token) private {
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance != 0) SafeTransferLib.safeTransfer(token, SETTLEMENT_ACCOUNT, balance);
    }

    function _request(address token, bytes32 legId, uint256 tokens, uint64 expiresAt)
        private
        view
        returns (IReservationCore.HoldRequest memory)
    {
        return IReservationCore.HoldRequest(token, legId, tokens.toUint128(), expiresAt, address(this));
    }

    function _conversion() private view returns (Conversion) {
        return Conversion(PROGRAM.conversion());
    }

    function _decode(bytes32 position) private pure returns (address token, uint256 maxCost) {
        token = address(uint160(uint256(position)));
        maxCost = uint16(uint256(position) >> 160);
    }
}
// forge-lint: disable-end(reentrancy-no-eth, calls-loop)
