// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { Conversion } from "./Conversion.sol";
import { ICardAuth } from "./interfaces/ICardAuth.sol";
import { IReservationCore, MAX_CREDITORS, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { CAPTURE_BEYOND, CAPTURE_FINAL, ISource } from "./interfaces/ISource.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solady/utils/SafeCastLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

/// @title CashSource
/// @notice A card program's cash funding source: holds on a cardholder's stablecoin balance in the core, placed and
///         captured by this contract, which is also their payee. Captures past a hold take the owner's free balance
///         and then core debt to this contract within the caps the owner set for it (the offline cap for a stand-in);
///         charges do the same with no hold. A leg in a stablecoin other than the program's settlement token locks
///         the conversion rate when it is placed and converts what it captures through the program's Conversion: at
///         the locked rate while the market stays within the owner's tolerance (the issuer absorbing any shortfall),
///         at today's price once it moves past it, never past the owner's maximum cost, and always above the
///         Conversion's slippage floor. Converted legs never create debt.
/// @dev `position`: the token in its low 160 bits and the owner's maximum conversion cost in basis points in the 16
///      bits above. Everything this contract receives in the settlement token is paid on to the settlement account in
///      the same call; repayments of debt arrive later and `sweep` forwards them. Not upgradeable.
/// @custom:reentrancy-guard _locked
// Calls go to the fixed core, the program's own Conversion and its tokens, inside program-driven steps.
// forge-lint: disable-start(reentrancy-no-eth, calls-loop)
contract CashSource is ISource {
    using FixedPointMathLib for uint256;
    using SafeCastLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice What the source is: cash.
    uint8 public constant KIND = 1;
    /// @notice The card authorization contract this source serves.
    ICardAuth public immutable PROGRAM;
    /// @notice Where every capture and charge is paid.
    address public immutable SETTLEMENT_ACCOUNT;

    /// @notice The rate a converted leg locked: settlement units per token unit, with 18 decimals.
    mapping(bytes32 legId => uint256) public lockedRate;

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
        returns (uint256 taken)
    {
        (address token,) = _decode(position);
        IReservationCore.HoldRecord memory h = CORE.getHold(owner, address(this), legId);
        if (h.token == address(0)) return 0;
        bool isFinal = flags & CAPTURE_FINAL != 0;
        bool beyond = flags & CAPTURE_BEYOND != 0;
        address settlement = PROGRAM.settlementToken();
        uint256 rate = lockedRate[legId];
        if (rate == 0) {
            uint256 amount = units < h.held ? units : h.held;
            if (beyond && units > h.held) amount = h.held + _excessRoom(owner, token, h.standIn, units - h.held, true);
            _take(owner, token, legId, h, amount, isFinal);
            _forward(settlement);
            return amount;
        }
        taken = _captureConverted(owner, token, settlement, legId, h, units, rate, beyond);
        if (isFinal) {
            _release(owner, legId);
        }
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
        // A refund converts back at today's reference rate, which the leg keeps.
        lockedRate[legId] = c.mid(token, settlement);
    }

    function release(address owner, bytes32, bytes32 legId) external onlyProgram {
        if (CORE.getHold(owner, address(this), legId).token != address(0)) _release(owner, legId);
        else if (lockedRate[legId] != 0) delete lockedRate[legId];
    }

    function refund(address owner, bytes32 position, bytes32 legId, uint256 units) external onlyProgram {
        (address token,) = _decode(position);
        address settlement = PROGRAM.settlementToken();
        uint256 tokens = units;
        if (token != settlement) {
            Conversion c = _conversion();
            SafeTransferLib.safeApprove(settlement, address(c), units);
            tokens = c.trusted(address(this))
                ? c.convertAtMid(settlement, token, units, address(this))
                : c.swapExactIn(settlement, token, units, 0, address(this));
        }
        if (tokens != 0) CORE.refund(owner, token, address(this), legId, tokens.toUint128());
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
    ) private returns (uint256) {
        Conversion c = _conversion();
        uint256 needed = c.quoteOut(token, settlement, units);
        // The lock holds while the market stays within the owner's tolerance: the owner pays at most the locked price.
        if (!c.lapsed(owner, rate, c.rate(token, settlement))) {
            uint256 promised = units.mulDivUp(ONE, rate);
            if (needed > promised) needed = promised;
        }
        uint256 tokens = needed < h.held ? needed : h.held;
        if (beyond && needed > h.held) {
            tokens = h.held + _excessRoom(owner, token, false, needed - h.held, false);
            // Tokens past the hold are bounded by the hold's own tolerance: a lapsed rate never costs the owner more.
            if (tokens > h.captureLimit) tokens = h.captureLimit;
        }
        if (tokens == 0) return 0;
        CORE.capture(owner, address(this), legId, tokens.toUint128(), false);
        return _swap(c, token, settlement, legId, units, tokens);
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

    /// @dev What `owner` owes this source in `token`, and how many creditors they owe.
    function _owed(address owner, address token) private view returns (uint256 owed, uint256 creditors) {
        IReservationCore.Debt[] memory debts = CORE.debtOf(owner, token);
        creditors = debts.length;
        for (uint256 i; i < debts.length; ++i) {
            if (debts[i].creditor == address(this)) return (debts[i].amount, creditors);
        }
    }

    /// @dev Settlement units per token unit now, and whether converting at it costs at most `maxCost`.
    function _rate(address token, address settlement, uint256 maxCost) private view returns (uint256 rate, bool ok) {
        Conversion c = _conversion();
        if (address(c) == address(0) || !c.converts(token, settlement)) return (0, false);
        rate = c.rate(token, settlement);
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
