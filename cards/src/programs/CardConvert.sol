// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

import { CardProgram } from "./CardProgram.sol";
import { Conversion } from "./Conversion.sol";
import { SavingsFacility } from "./SavingsFacility.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { ISettlementTokenGuard } from "./interfaces/ISettlementTokenGuard.sol";

interface ITIP20PayOut {
    function transferFromWithMemo(address from, address to, uint256 amount, bytes32 memo) external returns (bool);
}

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
    /// @dev CardProgram's SettlementTokenInUse reason for a held or liened settlement balance.
    uint8 internal constant IN_USE_HELD = 6;
    /// @dev CardProgram's SettlementTokenInUse reason when the settlement account cannot owe its debt in the new token.
    uint8 internal constant IN_USE_ISSUER_DEBT = 8;
    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    bytes32 private constant SLOT = keccak256("tempo.cards.CardConvert.v1");
    /// @dev Transient: the earlier settlement token a refund in progress is booked in, which rates then read in.
    bytes32 internal constant BOOKED_SLOT = keccak256("tempo.cards.CardConvert.booked");

    struct Layout {
        /// @dev The rate a converted leg locked: settlement units per token unit, scaled by 1e18.
        mapping(bytes32 legId => uint256) locked;
        /// @dev How many debts the program has charged the settlement account, which names each charge.
        uint256 issuerCharges;
    }

    /// @notice The settlement account paid `amount` to `to`, of which the program advanced `advanced`, which the
    ///         account now owes it as core debt.
    event IssuerPaid(address indexed to, address indexed token, uint256 amount, uint256 advanced, bytes32 memo);

    /// @notice A settlement token change carried what the settlement account owed the program in `token` into
    ///         `carried` of `next`, at the venue's price rounded up for the program.
    event IssuerDebtCarried(address indexed token, uint256 owed, address indexed next, uint256 carried);

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
        bytes32 slot = BOOKED_SLOT;
        address booked;
        assembly {
            booked := tload(slot)
        }
        if (booked == address(0)) return _current(token);
        // A refund on a purchase booked in an earlier token values everything in that token's units, at the reference
        // rates the refund converts at.
        if (token == booked) return RATE_ONE;
        address c = CardProgram(address(this)).conversion();
        if (c.code.length != 0 && Conversion(c).converts(token, booked)) return Conversion(c).mid(token, booked);
        return _current(token).mulDiv(RATE_ONE, _current(booked));
    }

    function _current(address token) private view returns (uint256 rate) {
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
        // Only a market that moved against the lock is carried by the issuer: at an unchanged or better rate, the take
        // converts exactly, so venue rounding never short-changes it.
        if (!lapsed && held != 0 && now_ < rate) {
            uint256 value = held.mulDiv(rate, RATE_ONE);
            uint256 locked = rest < value ? rest : value;
            uint256 tokens = locked == value ? held : held.mulDivUp(locked, value);
            if (locked != 0 && c.quoteIn(token, settlement, tokens) < locked) (exactIn, take) = (tokens, locked);
        }
        uint256 left = held + CORE.available(owner, token) - exactIn;
        uint256 worth = left == 0 ? 0 : c.quoteIn(token, settlement, left);
        uint256 exactOut = _min(rest - take, worth);
        take += exactOut;
        uint256 pay = exactIn + c.quoteOut(token, settlement, exactOut);
        // At the rate it locked, a capture of the whole leg spends the whole hold, so the owner pays what the lock
        // promised; the venue's rounding left over goes to the settlement account with the capture.
        if (!lapsed && now_ == rate && exactIn == 0 && exactOut == held.mulDiv(rate, RATE_ONE) && pay < held) {
            pay = held;
        }
        v = [take, pay, exactIn, exactOut, held, rate];
    }

    /// @notice After a part capture, what a converted leg still holds re-prices at today's rate: it holds the value the
    ///         purchase has left, within what the owner can spend.
    function _replan(address owner, bytes32 legId, address token, uint256 value, uint256 most) private {
        uint256 rate = current(token);
        uint256 tokens = _min(_tokensFor(token, value, rate), most);
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
        if (take != 0) total = _min(_tokensFor(token, before + take, now_), units);
    }

    /// @dev The tokens a leg holds for value at rate: at least what the venue charges for it today, so a capture at an
    ///      unchanged market converts exactly what the leg holds.
    /// @notice The tokens, or for savings the vault shares, a leg needs for take settlement units at rate, within units.
    function tokensFor(address token, address savings, uint256 take, uint256 rate, uint256 units)
        external
        view
        returns (uint256 tokens)
    {
        tokens = _tokensFor(token, take, rate);
        if (savings != address(0)) tokens = SavingsFacility(savings).VAULT().previewWithdraw(tokens);
        if (tokens > units) tokens = units;
    }

    function _tokensFor(address token, uint256 value, uint256 rate) private view returns (uint256 tokens) {
        tokens = value.mulDivUp(RATE_ONE, rate);
        CardProgram program = CardProgram(address(this));
        address settlement = program.settlementToken();
        address c = program.conversion();
        if (token == settlement || program.rateOf(token) != 0 || c.code.length == 0) return tokens;
        // A venue that can't quote the whole value leaves the leg at the rate's size.
        try Conversion(c).quoteOut(token, settlement, value) returns (uint256 cost) {
            if (cost > tokens) tokens = cost;
        } catch { }
    }

    /// @notice The rate a converted leg locked, settlement units per token unit scaled by 1e18; zero for none.
    function lockOf(bytes32 legId) external view returns (uint256) {
        return _layout().locked[legId];
    }

    /// @notice Repays capture debt the owner owes the program in the settlement token from the owner's cash in another
    ///         token, converted through the program's venue: what the owner can spend, up to what the debt costs today.
    ///         The settlement token lands with the owner, so the core repays the debt from it, and the program forwards
    ///         what it was repaid to the settlement account. Returns the settlement units repaid.
    function repay(address owner) external returns (uint256 repaid) {
        CardProgram program = CardProgram(address(this));
        address cash = program.fundingOf(owner);
        address settlement = _settlement();
        address c = cash == address(0) ? address(0) : swapper(cash, CASH);
        if (c == address(0)) return 0;
        (address creditor, uint128 owed) = CORE.debtOf(owner, settlement);
        if (creditor != address(this) || owed == 0) return 0;
        uint256 need = Conversion(c).quoteOut(cash, settlement, owed);
        uint256 pay = _min(need, CORE.available(owner, cash));
        if (pay == 0) return 0;
        bytes32 id;
        for (uint256 k;; ++k) {
            id = keccak256(abi.encode(address(this), owner, "repay", k));
            if (CORE.getHold(owner, id).token == address(0)) break;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        CORE.charge(owner, cash, id, uint128(pay), address(this), false);
        SafeTransferLib.safeApprove(cash, c, pay);
        if (pay == need) Conversion(c).swapExactOut(cash, settlement, owed, pay, owner);
        else Conversion(c).swapExactIn(cash, settlement, pay, 0, owner);
        (, uint128 left) = CORE.debtOf(owner, settlement);
        repaid = owed - left;
        uint256 landed = IERC20Like(settlement).balanceOf(address(this));
        if (landed != 0) SafeTransferLib.safeTransfer(settlement, program.SETTLEMENT_ACCOUNT(), landed);
        emit Converted(bytes32(0), cash, pay, settlement, repaid, 0);
    }

    /// @notice Pays a force post of `amount` settlement units from the owner's cash where it converts and covers the whole
    ///         post at the venue's price, landing the settlement token with the settlement account. Returns the cash
    ///         taken, zero when the post can't be paid that way.
    function chargeCash(address owner, bytes32 ref, bytes32 id, uint256 amount) external returns (uint256 tokens) {
        CardProgram program = CardProgram(address(this));
        address cash = program.fundingOf(owner);
        address c = cash == address(0) ? address(0) : swapper(cash, CASH);
        if (c == address(0)) return 0;
        address settlement = _settlement();
        tokens = Conversion(c).quoteOut(cash, settlement, amount);
        if (tokens == 0 || tokens > CORE.available(owner, cash)) return 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        CORE.charge(owner, cash, id, uint128(tokens), address(this), false);
        SafeTransferLib.safeApprove(cash, c, tokens);
        Conversion(c).swapExactOut(cash, settlement, amount, tokens, program.SETTLEMENT_ACCOUNT());
        // A refund gives the cash back at today's reference rate, which the leg keeps.
        _layout().locked[id] = Conversion(c).mid(cash, settlement);
        emit Converted(ref, cash, tokens, settlement, amount, 0);
    }

    /// @notice The token capture debt is owed in: the settlement token where cash converts into it, else cash.
    function debtToken(address cashToken) external view returns (address) {
        return cashToken != address(0) && swapper(cashToken, CASH) != address(0) ? _settlement() : cashToken;
    }

    /// @notice Reverts with CardProgram.SettlementTokenInUse while the settlement account holds or liens the current
    ///         settlement token, or a token guard still sizes money in it. The program checks its own purchases, debt
    ///         and collateral first.
    function checkUnused(address[] storage guards, address account, address current) external view {
        // What a guard names (an open dispute, an open credit line) explains a held balance, so it comes first.
        for (uint256 i; i < guards.length; ++i) {
            // Guards are the issuer's own contracts, a short list it sets.
            uint8 reason = ISettlementTokenGuard(guards[i]).settlementTokenInUse(address(this));
            if (reason != 0) revert CardProgram.SettlementTokenInUse(reason);
        }
        if (CORE.reserved(account, current) != 0 || CORE.liened(account, current) != 0) {
            revert CardProgram.SettlementTokenInUse(IN_USE_HELD);
        }
    }

    /// @notice Pays `amount` of the settlement token from the settlement account to `to` with `memo`. What the
    ///         account lacks, the program advances from its own funds, and the account owes it to the program as core
    ///         debt, within the cap the account set; the core repays it first from what the account receives.
    function payOut(address to, uint256 amount, bytes32 memo) external returns (uint256 advanced) {
        CardProgram program = CardProgram(address(this));
        address token = program.settlementToken();
        address account = program.SETTLEMENT_ACCOUNT();
        uint256 free = CORE.available(account, token);
        if (amount > free) {
            advanced = amount - free;
            (address creditor, uint128 owed) = CORE.debtOf(account, token);
            uint256 prior = creditor == address(this) ? owed : 0;
            // What the account already owes comes straight back as repayment, leaving the advance free to pay out.
            SafeTransferLib.safeTransfer(token, account, advanced + prior);
            ITIP20PayOut(token).transferFromWithMemo(account, to, amount, memo);
            _chargeIssuer(account, token, advanced + prior);
        } else {
            ITIP20PayOut(token).transferFromWithMemo(account, to, amount, memo);
        }
        emit IssuerPaid(to, token, amount, advanced, memo);
    }

    /// @notice Carries what the settlement account owes the program in `current` into `next`: the units of `next`
    ///         that buy it back at the venue, rounded up. Reverts when the account cannot owe that in `next`.
    function carryIssuerDebt(address current, address next) external {
        CardProgram program = CardProgram(address(this));
        address account = program.SETTLEMENT_ACCOUNT();
        (address creditor, uint128 owed) = CORE.debtOf(account, current);
        if (creditor != address(this) || owed == 0) return;
        uint256 carried = Conversion(program.conversion()).quoteOut(next, current, owed);
        // What the program sends comes straight back as repayment, which clears the debt in `current`.
        SafeTransferLib.safeTransfer(current, account, owed);
        if (!_tryChargeIssuer(account, next, carried)) revert CardProgram.SettlementTokenInUse(IN_USE_ISSUER_DEBT);
        emit IssuerDebtCarried(current, owed, next, carried);
    }

    /// @dev Charges the settlement account `amount` for the program; what it cannot pay becomes its debt.
    function _chargeIssuer(address account, address token, uint256 amount) private {
        // forge-lint: disable-next-line(unsafe-typecast)
        CORE.charge(account, token, _issuerChargeId(), uint128(amount), address(this), false);
    }

    function _tryChargeIssuer(address account, address token, uint256 amount) private returns (bool) {
        if (amount > type(uint128).max) return false;
        // forge-lint: disable-next-line(unsafe-typecast)
        try CORE.charge(account, token, _issuerChargeId(), uint128(amount), address(this), false) {
            return true;
        } catch {
            return false;
        }
    }

    function _issuerChargeId() private returns (bytes32) {
        return keccak256(abi.encode("tempo.cards.issuer-debt", address(this), ++_layout().issuerCharges));
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
        uint256 spent = exactIn;
        if (exactOut != 0) spent += Conversion(c).swapExactOut(token, settlement, exactOut, pay - exactIn, account);
        if (pay > spent) SafeTransferLib.safeTransfer(token, account, pay - spent);
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
