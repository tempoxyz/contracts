// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Conversion } from "./Conversion.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IReservationCore, MAX_CREDITORS, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { ISettlementTokenGuard } from "./interfaces/ISettlementTokenGuard.sol";
import { CAPTURE_BEYOND, CAPTURE_FINAL, CAPTURE_FREE, ISource } from "./interfaces/ISource.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

/// @title CashSource
/// @notice A card program's cash funding source: holds on a cardholder's stablecoin balance in the core, placed and
///         captured by this contract, which is also their payee. Captures past a hold take the owner's free balance
///         and then core debt to this contract within the caps the owner set for it (the offline cap for a stand-in);
///         charges do the same with no hold. A leg in a stablecoin other than the program's settlement token locks
///         the conversion rate when it is placed (only while the Conversion quotes it against a fresh reference rate
///         within the owner's maximum cost) and converts what it captures through the program's Conversion. The owner
///         pays the locked price while the venue stays within FX_BAND_BPS of it, the issuer carrying an adverse
///         difference and keeping a favourable one; past the band the owner pays the venue's price less FX_BAND_BPS in
///         the owner's favour. The owner never pays past the hold's capture limit; what it does not buy falls to the
///         issuer. A late charge of a purchase whose hold expired prices the same way against the rate it locked.
///         Converted legs never create debt. A refund of a converted leg pays the token back at the rate its
///         captures and charges paid, whatever the market or the reference rates do since.
/// @dev `position`: the token in its low 160 bits and the owner's maximum conversion cost in basis points in the 16
///      bits above. Everything this contract receives in the settlement token is paid on to the settlement account in
///      the same call; repayments of debt arrive later and `sweep` forwards them. Not upgradeable.
/// @custom:reentrancy-guard _locked
// Calls go to the fixed core, the program's own Conversion and its tokens, inside program-driven steps.
// forge-lint: disable-start(reentrancy-no-eth, calls-loop)
contract CashSource is ISource, ISettlementTokenGuard {
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant LOW = type(uint128).max;
    /// @notice How far the venue may move from a converted leg's locked rate before its owner shares the move.
    uint256 public constant FX_BAND_BPS = 200;

    /// @notice What the source is: cash.
    uint8 public constant KIND = 1;
    uint8 internal constant IN_USE_DEBT = 3;
    /// @notice The card authorization contract this source serves.
    ICardAuth public immutable PROGRAM;
    /// @notice Where every capture and charge is paid.
    address public immutable SETTLEMENT_ACCOUNT;

    /// @notice What a converted leg's captures and charges spent of its token and covered in a settlement token, less
    ///         what refunds gave back: the rate its refunds pay the token back at.
    struct Paid {
        uint128 tokens;
        uint128 units;
    }

    /// @dev A converted leg's locked rate (settlement units per token unit, 18 decimals) in the low 128 bits and, in
    ///      the high 128, the settlement value its open hold counts toward openConverted. An expired hold keeps its
    ///      rate, valued at zero, for a late charge.
    mapping(bytes32 legId => uint256) private _locks;
    /// @notice What a converted leg paid in each settlement token, which its refunds in that token convert back at.
    mapping(bytes32 legId => mapping(address settlement => Paid)) public paidOf;
    /// @notice Whether `owner` is among the debtors listed for `token`.
    mapping(address token => mapping(address owner => bool)) public isDebtor;
    /// @notice Who may owe this source core debt in each token: everyone a capture or charge left owing it, until
    ///         pruneDebtors finds they owe nothing.
    mapping(address token => address[]) public debtors;
    /// @notice The settlement value of every open converted hold, at the rates they locked.
    uint256 public openConverted;

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
        return _locks[legId] & LOW;
    }

    function held(address owner, bytes32, bytes32 legId) public view returns (uint256) {
        uint256 tokens = CORE.getHold(owner, address(this), legId).held;
        uint256 rate = lockedRate(legId);
        return rate == 0 ? tokens : tokens.mulDiv(rate, ONE);
    }

    function owed(address owner, bytes32 position) external view returns (uint256) {
        (address token,) = _decode(position);
        (uint256 debt,) = _owed(owner, token);
        address settlement = PROGRAM.settlementToken();
        if (debt == 0 || token == settlement) return debt;
        (uint256 rate,) = _rate(token, settlement, BPS);
        return debt.mulDiv(rate, ONE);
    }

    function refundable(address, bytes32, bytes32) external pure returns (uint256) {
        return type(uint256).max;
    }

    function toleranceBps(address owner, bytes32 position) external view returns (uint16) {
        (address token,) = _decode(position);
        return CORE.payeeTerms(owner, address(this), token).toleranceBps;
    }

    // Program.

    function hold(address owner, bytes32 position, bytes32 legId, uint256 units, uint64 expiresAt, bool standIn)
        external
        onlyProgram
        returns (uint256)
    {
        (address token, uint256 maxCost) = _decode(position);
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        bool live = h.token != address(0);
        if (units == 0) {
            if (live) _release(owner, legId);
            return 0;
        }
        address settlement = PROGRAM.settlementToken();
        uint256 rate = ONE;
        uint256 tokens = units;
        if (token != settlement) {
            uint256 locked = lockedRate(legId);
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
        if (standIn) {
            // A stand-in reserves what is free and captures the rest as debt within the offline cap.
            uint256 most = (live ? h.held : 0) + CORE.available(owner, token);
            if (tokens > most) tokens = most;
            uint256 placed = h.held;
            if (live) {
                if (tokens < placed) _resize(owner, legId, placed = tokens);
            } else {
                placed = units.mulDivUp(ONE, rate);
                CORE.holdFrom(owner, _request(token, legId, placed, expiresAt, true));
            }
            if (token != settlement) _setLock(legId, rate, placed);
            return units;
        }
        uint256 cap = (live ? h.held : 0) + CORE.available(owner, token);
        if (tokens > cap) {
            tokens = cap;
            units = tokens.mulDiv(rate, ONE);
        }
        if (tokens == 0) {
            if (live) _release(owner, legId);
            return 0;
        }
        if (!live) CORE.holdFrom(owner, _request(token, legId, tokens, expiresAt, false));
        else if (tokens != h.held) _resize(owner, legId, tokens);
        if (token != settlement) _setLock(legId, rate, tokens);
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
        bool beyond = flags & CAPTURE_BEYOND != 0;
        address settlement = PROGRAM.settlementToken();
        uint256 rate = lockedRate(legId);
        if (rate == 0) {
            uint256 amount = units < h.held ? units : h.held;
            // Past the hold: free cash, and with CAPTURE_BEYOND debt within the owner's caps.
            if (units > h.held && (beyond || flags & CAPTURE_FREE != 0)) {
                amount = h.held + _excessRoom(owner, token, h.standIn, units - h.held, beyond);
            }
            // A short capture of free funds stays live: debt may follow through CAPTURE_BEYOND.
            if (isFinal && !beyond && amount < units) isFinal = false;
            if (amount != 0 || isFinal) _take(owner, token, legId, h, amount, isFinal);
            if (amount > h.held) _noteDebtor(owner, token);
            _forward(settlement);
            return (amount, amount);
        }
        // A converted leg never takes debt: past its hold it takes free tokens either way.
        (paid, covered) = _captureConverted(
            owner, token, settlement, legId, h, units, rate, flags & (CAPTURE_BEYOND | CAPTURE_FREE) != 0
        );
        if (isFinal && (beyond || covered >= units)) _release(owner, legId);
    }

    function charge(address owner, bytes32 position, bytes32 legId, uint256 units, bool standIn)
        external
        onlyProgram
        returns (uint256 paid, uint256 covered)
    {
        (address token, uint256 maxCost) = _decode(position);
        address settlement = PROGRAM.settlementToken();
        if (token == settlement) {
            paid = _excessRoom(owner, token, standIn, units, true);
            if (paid == 0) return (0, 0);
            CORE.charge(owner, token, legId, paid.toUint128(), address(this), standIn);
            _noteDebtor(owner, token);
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
            // owner's tolerance on what that rate promised standing in for the capture limit.
            _setLock(legId, 0, 0);
            tolerance = CORE.payeeTerms(owner, address(this), token).toleranceBps;
            band = FX_BAND_BPS + tolerance;
            cost = _anchoredCost(c, token, settlement, units, rate, band);
        }
        if (cost == 0) {
            band = 0;
            (, bool ok) = _rate(token, settlement, maxCost);
            if (!ok) return (0, 0);
            cost = c.quoteOut(token, settlement, units);
        }
        uint256 price = rate == 0 ? cost : _bandPrice(units, rate, cost);
        uint256 most = _excessRoom(owner, token, false, price, false);
        // The owner's tolerance on the locked price caps what it pays; the issuer pays the rest of the purchase.
        uint256 limit = rate == 0 ? price : units.mulDivUp(ONE, rate).mulDiv(BPS + tolerance, BPS);
        bool capped = most > limit;
        if (capped) most = limit;
        if (most == 0) return (0, 0);
        CORE.charge(owner, token, legId, most.toUint128(), address(this), false);
        paid = _swap(c, token, settlement, legId, units, most, cost, rate, band);
        // Short of the price, the owner's tokens cover their share of it and the rest falls to later sources.
        covered = capped || most == price ? units : units.mulDiv(most, price);
        // What the swap fetched past that (a favourable move, or rounding) stays with the settlement account.
        if (paid > covered) paid = covered;
        _paid(legId, settlement, most, covered);
    }

    /// @notice Ends a leg. A converted leg whose hold expired (or that the core already ended) keeps its locked rate
    ///         for a late charge; any other drops it. Either way it no longer counts toward openConverted.
    function release(address owner, bytes32, bytes32 legId) external onlyProgram {
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        // Expiries are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        bool expired = h.token == address(0) || block.timestamp >= h.expiresAt;
        if (h.token != address(0)) CORE.release(owner, address(this), legId);
        uint256 rate = lockedRate(legId);
        if (rate != 0) _setLock(legId, expired ? rate : 0, 0);
    }

    /// @dev A converted leg pays back, for what its captures and charges covered in today's settlement token, the
    ///      tokens they spent at the same rate, out of the Conversion's float (or, when it is short or does not trust
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

    /// @notice Core debt anyone owes this source in the settlement token keeps that token from changing (reason 3).
    ///         It reads the listed debtors until one owes; pruneDebtors keeps the list to those who may.
    // At most the listed debtors, one core read each.
    // forge-lint: disable-next-item(calls-loop)
    function settlementTokenInUse(address) external view returns (uint8) {
        address token = PROGRAM.settlementToken();
        address[] storage list = debtors[token];
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            (uint256 owed,) = _owed(list[i], token);
            if (owed != 0) return IN_USE_DEBT;
        }
        return 0;
    }

    /// @notice Reads up to `count` debtors listed for `token` from index `start` on and drops those who owe this
    ///         source nothing in it, moving the last listed debtor into each one's place. Anyone may call it.
    // At most count core reads.
    // forge-lint: disable-next-item(calls-loop)
    function pruneDebtors(address token, uint256 start, uint256 count) external returns (uint256 dropped) {
        address[] storage list = debtors[token];
        uint256 i = start;
        for (uint256 k; k < count && i < list.length; ++k) {
            address owner = list[i];
            (uint256 owed,) = _owed(owner, token);
            if (owed != 0) {
                ++i;
                continue;
            }
            isDebtor[token][owner] = false;
            list[i] = list[list.length - 1];
            list.pop();
            ++dropped;
        }
    }

    function debtorCount(address token) external view returns (uint256) {
        return debtors[token].length;
    }

    /// @notice Pays what this source holds of `token` (debt repaid to it) on to the settlement account.
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
        bool beyond
    ) private returns (uint256 paid, uint256 covered) {
        Conversion c = _conversion();
        uint256 band = FX_BAND_BPS + CORE.payeeTerms(owner, address(this), token).toleranceBps;
        uint256 cost = _anchoredCost(c, token, settlement, units, rate, band);
        if (cost == 0) {
            // Past the band and the owner's tolerance the venue prices only while the reference rates agree with it.
            band = 0;
            cost = c.quoteOut(token, settlement, units);
        }
        // What the owner can put toward the band price: its hold and, past it, free tokens.
        uint256 price = _bandPrice(units, rate, cost);
        uint256 tokens = price;
        if (tokens > h.held) tokens = h.held + (beyond ? _excessRoom(owner, token, false, tokens - h.held, false) : 0);
        bool capped = tokens > h.captureLimit;
        if (capped) tokens = h.captureLimit;
        if (tokens == 0) return (0, 0);
        CORE.capture(owner, address(this), legId, tokens.toUint128(), false);
        _setLock(legId, rate, tokens < h.held ? h.held - tokens : 0);
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
        _paid(legId, settlement, tokens, covered);
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

    /// @dev Adds what a converted capture or charge spent and covered to the rate the leg's refunds pay back at.
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
        if (extra != 0) CORE.charge(owner, token, legId, extra.toUint128(), address(this), h.standIn);
    }

    /// @dev What a capture or charge may take past a hold, up to `want`: the owner's free balance, the owner's budget
    ///      for this source and, with `debt`, core debt within the owner's cap for this source.
    function _excessRoom(address owner, address token, bool standIn, uint256 want, bool debt)
        private
        view
        returns (uint256 room)
    {
        room = CORE.available(owner, token);
        if (debt) {
            IReservationCore.PayeeTerms memory t = CORE.payeeTerms(owner, address(this), token);
            uint256 cap = standIn && t.offlineCap > t.debtCap ? t.offlineCap : t.debtCap;
            (uint256 owed, uint256 creditors) = _owed(owner, token);
            if (cap > owed && (owed != 0 || creditors < MAX_CREDITORS)) room += cap - owed;
        }
        IReservationCore.Budget memory b = CORE.budget(owner, address(this), token);
        uint256 used = uint256(b.spent) + b.outstanding;
        uint256 budget = b.limit > used ? b.limit - used : 0;
        if (room > budget) room = budget;
        if (room > want) room = want;
    }

    /// @dev Lists `owner` among the debtors in `token` once a capture or charge left them owing this source.
    function _noteDebtor(address owner, address token) private {
        if (isDebtor[token][owner]) return;
        (uint256 owed,) = _owed(owner, token);
        if (owed == 0) return;
        isDebtor[token][owner] = true;
        debtors[token].push(owner);
    }

    /// @dev What `owner` owes this source in `token`, and how many creditors they owe.
    function _owed(address owner, address token) private view returns (uint256 owed, uint256 creditors) {
        IReservationCore.Debt[] memory debts = CORE.debtOf(owner, token);
        creditors = debts.length;
        for (uint256 i; i < debts.length; ++i) {
            if (debts[i].creditor == address(this)) return (debts[i].amount, creditors);
        }
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

    /// @dev Sets a converted leg's locked `rate` (zero drops it) with `tokens` open in its hold, keeping openConverted
    ///      in step.
    function _setLock(bytes32 legId, uint256 rate, uint256 tokens) private {
        uint256 word = _locks[legId];
        uint256 value = tokens.mulDiv(rate, ONE);
        uint256 before = word >> 128;
        if (value != before) openConverted = openConverted + value - before;
        uint256 next = rate == 0 ? 0 : rate.toUint128() | uint256(value.toUint128()) << 128;
        if (next != word) _locks[legId] = next;
    }

    function _resize(address owner, bytes32 legId, uint256 tokens) private {
        if (tokens == 0) _release(owner, legId);
        else CORE.adjust(owner, address(this), legId, tokens.toUint128());
    }

    function _release(address owner, bytes32 legId) private {
        CORE.release(owner, address(this), legId);
        if (_locks[legId] != 0) _setLock(legId, 0, 0);
    }

    function _forward(address token) private {
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance != 0) SafeTransferLib.safeTransfer(token, SETTLEMENT_ACCOUNT, balance);
    }

    function _request(address token, bytes32 legId, uint256 tokens, uint64 expiresAt, bool standIn)
        private
        view
        returns (IReservationCore.HoldRequest memory)
    {
        return IReservationCore.HoldRequest(token, legId, tokens.toUint128(), expiresAt, address(this), standIn);
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
