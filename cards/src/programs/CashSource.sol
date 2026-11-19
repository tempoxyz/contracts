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
///         the conversion rate when it is placed, and again for its rest after a part capture, and converts what it
///         captures through the program's Conversion: at
///         the locked rate while the market stays within the owner's tolerance (the issuer absorbing any shortfall),
///         at today's price once it moves past it, never past the owner's maximum cost, and always above the
///         Conversion's slippage floor. Converted legs never create debt. A refund of a converted leg pays the token
///         back at the rate its captures and charges paid, whatever the market or the reference rates do since. A
///         token whose rate the Conversion cannot quote (stale, missing or straying from its venue) covers nothing.
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

    /// @notice The rate a converted leg locked: settlement units per token unit, with 18 decimals.
    mapping(bytes32 legId => uint256) public lockedRate;
    /// @notice What a converted leg paid in each settlement token, which its refunds in that token convert back at.
    mapping(bytes32 legId => mapping(address settlement => Paid)) public paidOf;
    /// @notice Whether `owner` is among the debtors listed for `token`.
    mapping(address token => mapping(address owner => bool)) public isDebtor;
    /// @notice Who may owe this source core debt in each token: everyone a capture or charge left owing it, until
    ///         pruneDebtors finds they owe nothing.
    mapping(address token => address[]) public debtors;

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

    function held(address owner, bytes32 position, bytes32 legId) public view returns (uint256) {
        (address token,) = _decode(position);
        uint256 tokens = CORE.getHold(owner, address(this), legId).held;
        uint256 rate = lockedRate[legId];
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
            uint256 locked = lockedRate[legId];
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
            if (live) {
                if (tokens < h.held) _resize(owner, legId, tokens);
            } else {
                CORE.holdFrom(owner, _request(token, legId, units.mulDivUp(ONE, rate), expiresAt, true));
            }
            _lock(legId, rate, settlement == token);
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
        _lock(legId, rate, settlement == token);
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
        uint256 rate = lockedRate[legId];
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
        else if (!isFinal) _relock(owner, position, settlement, legId, uint256(h.held).mulDiv(rate, ONE), covered);
    }

    /// @dev After a part capture the rest of a converted leg is planned again at today's rate, as a new lock, within
    ///      what the owner holds; a rate past the owner's maximum cost keeps the old lock.
    function _relock(
        address owner,
        bytes32 position,
        address settlement,
        bytes32 legId,
        uint256 before,
        uint256 covered
    ) private {
        if (covered >= before) return;
        (address token, uint256 maxCost) = _decode(position);
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        if (h.token == address(0)) return;
        (uint256 rate, bool ok) = _rate(token, settlement, maxCost);
        if (!ok) return;
        uint256 rest = before - covered;
        uint256 tokens = _tokensFor(token, settlement, rest, rate);
        if (tokens > rest.mulDivUp(ONE, rate)) rate = rest.mulDivUp(ONE, tokens);
        uint256 cap = h.held + CORE.available(owner, token);
        if (tokens > cap) tokens = cap;
        if (tokens == 0) return;
        if (tokens != h.held) _resize(owner, legId, tokens);
        _lock(legId, rate, false);
    }

    function charge(address owner, bytes32 position, bytes32 legId, uint256 units, bool standIn)
        external
        onlyProgram
        returns (uint256 taken)
    {
        (address token, uint256 maxCost) = _decode(position);
        address settlement = PROGRAM.settlementToken();
        if (token == settlement) {
            taken = _excessRoom(owner, token, standIn, units, true);
            if (taken == 0) return 0;
            CORE.charge(owner, token, legId, taken.toUint128(), address(this), standIn);
            _noteDebtor(owner, token);
            _forward(settlement);
            return taken;
        }
        (, bool ok) = _rate(token, settlement, maxCost);
        if (!ok) return 0;
        Conversion c = _conversion();
        uint256 tokens = c.quoteOut(token, settlement, units);
        uint256 most = _excessRoom(owner, token, false, tokens, false);
        if (most == 0) return 0;
        CORE.charge(owner, token, legId, most.toUint128(), address(this), false);
        taken = _swap(c, token, settlement, legId, units, most);
        _paid(legId, settlement, most, taken);
    }

    function release(address owner, bytes32, bytes32 legId) external onlyProgram {
        if (CORE.getHold(owner, address(this), legId).token != address(0)) _release(owner, legId);
        else if (lockedRate[legId] != 0) delete lockedRate[legId];
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
        uint256 needed = c.quoteOut(token, settlement, units);
        // The lock holds while the market stays within the owner's tolerance: the owner pays at most the locked price.
        bool locked = !c.lapsed(owner, rate, c.rate(token, settlement));
        if (locked) {
            uint256 promised = units.mulDivUp(ONE, rate);
            if (needed > promised) needed = promised;
        }
        uint256 tokens = needed < h.held ? needed : h.held;
        // At the rate it locked, a capture of the whole leg spends the whole hold: the owner pays what the lock promised
        // and the venue's rounding left over goes to the settlement account with the capture.
        if (
            locked && tokens < h.held && c.rate(token, settlement) == rate && units >= uint256(h.held).mulDiv(rate, ONE)
        ) {
            tokens = h.held;
        }
        if (beyond && needed > h.held) {
            tokens = h.held + _excessRoom(owner, token, false, needed - h.held, false);
            // Tokens past the hold are bounded by the hold's own tolerance: a lapsed rate never costs the owner more.
            if (tokens > h.captureLimit) tokens = h.captureLimit;
        }
        if (tokens == 0) return (0, 0);
        CORE.capture(owner, address(this), legId, tokens.toUint128(), false);
        paid = _swap(c, token, settlement, legId, units, tokens);
        covered = paid;
        // Within the lock the owner covers what the tokens buy at the locked rate; the issuer carries the slippage.
        if (locked) {
            uint256 atLock = tokens.mulDiv(rate, ONE);
            if (atLock > units) atLock = units;
            if (atLock > covered) covered = atLock;
        }
        _paid(legId, settlement, tokens, covered);
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

    /// @dev Converts `tokens` into the settlement token for the settlement account: exactly `units` when they buy it,
    ///      else all of them (the Conversion's floor bounding the price). Returns the settlement units paid.
    function _swap(Conversion c, address token, address settlement, bytes32 legId, uint256 units, uint256 tokens)
        private
        returns (uint256 paid)
    {
        SafeTransferLib.safeApprove(token, address(c), tokens);
        if (c.quoteOut(token, settlement, units) <= tokens) {
            uint256 spent = c.swapExactOut(token, settlement, units, tokens, SETTLEMENT_ACCOUNT);
            // The venue's rounding left over goes with the capture.
            if (tokens > spent) SafeTransferLib.safeTransfer(token, SETTLEMENT_ACCOUNT, tokens - spent);
            paid = units;
        } else {
            paid = c.swapExactIn(token, settlement, tokens, 0, SETTLEMENT_ACCOUNT);
            // The venue quoted less than `units` for these tokens; a unit of rounding past it goes with the capture,
            // which never pays more than it asked.
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

    function _lock(bytes32 legId, uint256 rate, bool plain) private {
        if (plain) return;
        if (lockedRate[legId] != rate) lockedRate[legId] = rate;
    }

    function _resize(address owner, bytes32 legId, uint256 tokens) private {
        if (tokens == 0) _release(owner, legId);
        else CORE.adjust(owner, address(this), legId, tokens.toUint128());
    }

    function _release(address owner, bytes32 legId) private {
        CORE.release(owner, address(this), legId);
        if (lockedRate[legId] != 0) delete lockedRate[legId];
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
