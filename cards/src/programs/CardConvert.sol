// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

import { CardProgram } from "./CardProgram.sol";
import { Conversion } from "./Conversion.sol";
import { SavingsFacility } from "./SavingsFacility.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

/// @title CardConvert
/// @notice Legs held in a token other than the one the program settles in: the rate each leg locked when it was
///         placed, the price a capture converts at (the lock while the market stays within the owner's tolerance,
///         today's quote once it moves past it), the swap that pays the issuer exactly what it captured, and refunds
///         that convert back at the reference rate. Runs in the program's context, like CardFunding, which calls it.
// Loops run over a purchase's legs (at most MAX_SOURCES) and call only the fixed core, the program itself, its
// issuer-set Conversion and issuer-approved facilities.
// forge-lint: disable-start(calls-loop)
library CardConvert {
    using FixedPointMathLib for uint256;

    uint8 internal constant CASH = 1;
    uint8 internal constant SAVINGS = 2;
    uint8 internal constant CREDIT = 4;
    uint8 internal constant TOKEN = 64;
    uint256 internal constant RATE_ONE = 1e18;
    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    bytes32 private constant SLOT = keccak256("tempo.cards.CardConvert.v1");

    struct Layout {
        /// @dev The rate a converted leg locked: settlement units per token unit, scaled by 1e18.
        mapping(bytes32 legId => uint256) locked;
    }

    /// @notice A captured leg converted into the settlement token: what the owner paid in its token, what the issuer
    ///         received and what the issuer absorbed because the market moved within the rate lock, in settlement units.
    event Converted(
        bytes32 indexed purchaseRef,
        address indexed token,
        uint256 tokens,
        address settlementToken,
        uint256 paid,
        uint256 slippage
    );

    /// @notice The venue a cash or token leg in token swaps through at capture; zero when it needs none.
    function swapper(address token, uint8 kind) public view returns (address) {
        if (kind != CASH && kind != TOKEN) return address(0);
        CardProgram program = CardProgram(address(this));
        if (token == program.settlementToken() || program.rateOf(token) != 0) return address(0);
        return program.conversion();
    }

    /// @notice Settlement units per token unit for a leg: the rate it locked, else one for the settlement token, the
    ///         issuer's rate where it set one, or what the program's venue pays now, net of its cost.
    function rateOf(address token, bytes32 legId) external view returns (uint256 rate) {
        rate = _layout().locked[legId];
        if (rate == 0) rate = current(token);
    }

    /// @notice Settlement units per token unit now, ignoring any lock.
    function current(address token) public view returns (uint256 rate) {
        CardProgram program = CardProgram(address(this));
        address settlement = program.settlementToken();
        if (token == settlement) return RATE_ONE;
        rate = program.rateOf(token);
        if (rate == 0) {
            Conversion c = Conversion(program.conversion());
            if (address(c) != address(0) && c.converts(token, settlement)) rate = c.rate(token, settlement);
        }
        if (rate == 0) revert CardProgram.TokenNotAccepted(token);
    }

    /// @notice Whether converting token at rate costs more than maxBps.
    function tooCostly(address token, uint256 rate, uint256 maxBps) external view returns (bool) {
        return _tooCostly(token, rate, maxBps);
    }

    function _tooCostly(address token, uint256 rate, uint256 maxBps) private view returns (bool) {
        address c = swapper(token, TOKEN);
        return c != address(0) && Conversion(c).costBps(token, _settlement(), rate) > maxBps;
    }

    /// @notice Records the rate a converted leg holds at.
    function lock(bytes32 legId, address token, uint8 kind, uint256 rate) external {
        if (swapper(token, kind) == address(0)) return;
        Layout storage L = _layout();
        if (L.locked[legId] != rate) L.locked[legId] = rate;
    }

    /// @notice How a capture of up to rest settlement units converts a leg holding held tokens at its locked rate. The
    ///         lock holds while the market stays within the owner's tolerance (never for a leg the capture places).
    ///         Under it, when the market moved against the issuer the owner pays the locked share of the hold and the
    ///         issuer takes what it buys now (exactIn), carrying the slippage. The rest, and all of it once the lock
    ///         lapsed, pays the issuer exactly what it captured at today's price (exactOut). Returns [take, tokens paid,
    ///         exactIn, exactOut, held, rate the leg holds at].
    function price(address owner, address token, uint256 rest, uint256 held, uint256 rate, bool exists)
        external
        view
        returns (uint256[6] memory v)
    {
        Conversion c = Conversion(CardProgram(address(this)).conversion());
        address settlement = _settlement();
        uint256 now_ = c.rate(token, settlement);
        bool lapsed = !exists || c.lapsed(owner, rate, now_);
        if (lapsed) rate = now_;
        uint256 take;
        uint256 exactIn;
        if (!lapsed && held != 0) {
            uint256 value = held.mulDiv(rate, RATE_ONE);
            uint256 locked = rest < value ? rest : value;
            uint256 tokens = locked == value ? held : held.mulDivUp(locked, value);
            if (locked != 0 && c.quoteIn(token, settlement, tokens) < locked) (exactIn, take) = (tokens, locked);
        }
        uint256 left = held + CORE.available(owner, token) - exactIn;
        uint256 worth = left == 0 ? 0 : c.quoteIn(token, settlement, left);
        uint256 exactOut = _min(rest - take, worth);
        take += exactOut;
        v = [take, exactIn + c.quoteOut(token, settlement, exactOut), exactIn, exactOut, held, rate];
    }

    /// @notice After a part capture, what a converted leg still holds re-prices at today's rate: it holds the value the
    ///         purchase has left, within what the owner can spend.
    function _replan(address owner, bytes32 legId, address token, uint256 value, uint256 most) private {
        uint256 rate = current(token);
        uint256 tokens = _min(value.mulDivUp(RATE_ONE, rate), most);
        if (CORE.getHold(owner, legId).held != tokens) {
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.adjust(owner, legId, uint128(tokens));
        }
        Layout storage L = _layout();
        if (L.locked[legId] != rate) L.locked[legId] = rate;
    }

    /// @notice Completes a converted leg's capture as price planned it (v) and, for a part capture leaving tokens
    ///         held, re-prices what the purchase has left at today's rate.
    function finish(bytes32 ref, address owner, bytes32 legId, address token, uint256[6] calldata v, bool isFinal)
        external
    {
        _swap(ref, token, v[0], v[1], v[2], v[3]);
        if (isFinal || v[1] >= v[4]) return;
        uint256 worth = v[4].mulDiv(v[5], RATE_ONE);
        _replan(owner, legId, token, worth > v[0] ? worth - v[0] : 0, v[4] - v[1] + CORE.available(owner, token));
    }

    /// @notice How far a converted leg holding held tokens at rate grows for up to rest more settlement units, with free
    ///         more tokens to spend: the whole leg re-prices at today's rate and holds its old value plus the increment.
    ///         Returns the units taken, the tokens the leg holds after, and today's rate; nothing past maxBps of cost.
    function growth(address token, uint256 maxBps, uint256 held, uint256 rate, uint256 free, uint256 rest)
        external
        view
        returns (uint256 take, uint256 total, uint256 now_)
    {
        now_ = current(token);
        if (maxBps < 10_000 && _tooCostly(token, now_, maxBps)) return (0, 0, now_);
        uint256 before = held.mulDiv(rate, RATE_ONE);
        uint256 units = held + free;
        uint256 cap = units.mulDiv(now_, RATE_ONE);
        uint256 room = cap > before ? cap - before : 0;
        take = rest < room ? rest : room;
        if (take != 0) total = _min((before + take).mulDivUp(RATE_ONE, now_), units);
    }

    /// @notice The rate a converted leg locked, settlement units per token unit scaled by 1e18; zero for none.
    function lockOf(bytes32 legId) external view returns (uint256) {
        return _layout().locked[legId];
    }

    /// @notice The token capture debt is owed in: the settlement token where cash converts into it, else cash.
    function debtToken(address cashToken) external view returns (address) {
        return cashToken != address(0) && swapper(cashToken, CASH) != address(0) ? _settlement() : cashToken;
    }

    /// @notice Swaps what a converted leg captured into the settlement token for the settlement account, as price
    ///         planned, and reports what the issuer absorbed.
    function _swap(bytes32 ref, address token, uint256 take, uint256 pay, uint256 exactIn, uint256 exactOut) private {
        CardProgram program = CardProgram(address(this));
        address c = program.conversion();
        address settlement = program.settlementToken();
        address account = program.SETTLEMENT_ACCOUNT();
        SafeTransferLib.safeApprove(token, c, pay);
        uint256 paid = exactOut;
        if (exactIn != 0) paid += Conversion(c).swapExactIn(token, settlement, exactIn, 0, account);
        if (exactOut != 0) Conversion(c).swapExactOut(token, settlement, exactOut, pay - exactIn, account);
        emit Converted(ref, token, pay, settlement, paid, take > paid ? take - paid : 0);
    }

    /// @notice Converts what a savings or credit leg's capture paid the program in another token into exactly take
    ///         settlement units for the settlement account, or all of it when the market moved and it falls short. Any
    ///         rounding left over goes to the settlement account in that token with the rest of the capture.
    function settle(bytes32 ref, uint8 kind, address source, address legToken, uint256 take) external {
        if (kind != SAVINGS && kind != CREDIT) return;
        address token = kind == SAVINGS ? SavingsFacility(source).ASSET() : legToken;
        address c = swapper(token, CASH);
        if (c == address(0) || take == 0) return;
        CardProgram program = CardProgram(address(this));
        address settlement = program.settlementToken();
        address account = program.SETTLEMENT_ACCOUNT();
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        uint256 need = Conversion(c).quoteOut(token, settlement, take);
        SafeTransferLib.safeApprove(token, c, balance);
        uint256 paid = take;
        if (need <= balance) Conversion(c).swapExactOut(token, settlement, take, need, account);
        else paid = Conversion(c).swapExactIn(token, settlement, balance, 0, account);
        emit Converted(ref, token, need <= balance ? need : balance, settlement, paid, take > paid ? take - paid : 0);
    }

    /// @notice Refunds take settlement units onto a converted leg: the caller pays them in the settlement token, which
    ///         converts at the reference rate, and whatever exceeds what the leg can take back lands with the owner.
    function refund(bytes32 ref, address owner, bytes32 legId, address token, uint256 refundable, uint256 take)
        external
        returns (uint256 tokens)
    {
        CardProgram program = CardProgram(address(this));
        address settlement = program.settlementToken();
        address booked = program.purchaseToken(ref);
        Conversion c = Conversion(program.conversion());
        // A purchase booked in an earlier settlement token refunds in its units, paid in today's at the reference rate.
        uint256 paying = booked == settlement ? take : take.mulDivUp(c.mid(booked, settlement), RATE_ONE);
        SafeTransferLib.safeTransferFrom(settlement, msg.sender, address(this), paying);
        SafeTransferLib.safeApprove(settlement, address(c), paying);
        uint256 out = c.convertAtMid(settlement, token, paying, address(this));
        tokens = _min(out, refundable);
        // forge-lint: disable-next-line(unsafe-typecast)
        if (tokens != 0) CORE.refund(owner, legId, uint128(tokens));
        if (out > tokens) SafeTransferLib.safeTransfer(token, owner, out - tokens);
    }

    function _settlement() private view returns (address) {
        return CardProgram(address(this)).settlementToken();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _layout() private pure returns (Layout storage L) {
        bytes32 slot = SLOT;
        assembly {
            L.slot := slot
        }
    }
}
// forge-lint: disable-end(calls-loop)
