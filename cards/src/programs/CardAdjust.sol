// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { AccountLifecycle } from "./AccountLifecycle.sol";
import { CardLimits } from "./CardLimits.sol";
import { CardProgram } from "./CardProgram.sol";
import { CreditLine } from "./CreditLine.sol";
import { SavingsFacility } from "./SavingsFacility.sol";
import { IReservationCore } from "./interfaces/IReservationCore.sol";

/// @title CardAdjust
/// @notice A card program's incremental authorizations, partial reversals and late charges, linked as an external library so the
///         program keeps its runtime code small. It runs in the program's context.
library CardAdjust {
    using FixedPointMathLib for uint256;

    /// @dev CardProgram's event, emitted in the program's context.
    event LimitsSet(bytes32 indexed card, CardProgram.Limits limits, CardProgram.Limits ceiling);
    event CardIssued(bytes32 indexed card, address indexed owner, uint40 expiry, CardProgram.Limits limits, uint8 legs);
    event CardReplaced(bytes32 indexed oldCard, bytes32 indexed newCard, uint40 expiry);
    event CardStatusSet(bytes32 indexed card, CardProgram.Status status);

    uint256 private constant RATE_ONE = 1e18;

    /// @notice Moves open purchase `p` to `amount` settlement units in the program's records. An increase checks the card,
    ///         the owner's grant and every limit on the new total; a decrease gives the difference back to the limits.
    ///         The program then moves the purchase's legs with CardFunding.resize.
    function adjust(
        CardProgram.Purchase storage p,
        CardProgram.Card storage c,
        CardLimits.Grant storage g,
        CardLimits.Usage storage u,
        uint128 amount
    ) external {
        if (!p.open) revert CardProgram.PurchaseNotOpen();
        // Expiries are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.expiresAt) revert CardProgram.PurchaseExpired();
        // A stand-in's amount was approved offline: it can come down but never go up.
        if (amount == 0 || amount > type(uint64).max || (p.standIn && amount > p.amount)) {
            revert CardProgram.InvalidAmount();
        }
        uint256 previous = p.amount;
        if (amount > previous) {
            if (c.status != CardProgram.Status.Active) revert CardProgram.CardNotActive();
            // A revoked grant stops increments as it stops new purchases; captures, releases and refunds still run.
            if (!g.active) revert CardProgram.NoTerms();
            uint256 more = amount - previous;
            CardProgram.Limits memory l = c.limits;
            CardLimits.spend(g, u, c.window, [uint256(l.perPurchase), l.daily, l.monthly], amount, more, true);
            // forge-lint: disable-next-line(unsafe-typecast)
            p.held += uint64(more);
        } else {
            uint256 less = previous - amount;
            if (less > p.held) revert CardProgram.InvalidAmount();
            if (less != 0) CardLimits.giveBack(g, u, c.window, p.epoch, p.day, p.month, less);
            // forge-lint: disable-next-line(unsafe-typecast)
            p.held -= uint64(less);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        p.amount = uint64(amount);
    }

    /// @notice Charges `amount` settlement units for purchase `p` as one core charge `id` on the owner's cash token,
    ///         paid to the program, and counts the whole amount toward the owner's limits. The charge takes what the
    ///         owner has available plus what the debt cap the owner set for the program still allows; the issuer
    ///         absorbs the rest. Returns the tokens charged and the settlement units absorbed.
    function charge(
        IReservationCore core,
        CardProgram.Purchase storage p,
        CardProgram.Card storage c,
        CardLimits.Grant storage g,
        CardLimits.Usage storage u,
        address token,
        uint256 rate,
        bytes32 id,
        uint128 amount
    ) external returns (uint256 tokens, uint256 absorbed) {
        // A late charge on an authorized purchase needs only past terms; one that opens a purchase (a force post) needs
        // the owner's grant to be active, as an authorization does.
        if (g.epoch == 0 || (p.epoch == 0 && !g.active)) revert CardProgram.NoTerms();
        address owner = p.owner;
        uint256 wanted = _toTokenUp(amount, rate);
        tokens = _chargeable(core, owner, token, wanted);
        if (tokens != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            core.charge(owner, token, id, uint128(tokens), address(this), false);
        }
        // Bit 16 marks a late charge that took nothing from the owner, so the reference can't be charged again.
        p.legs |= tokens != 0 ? 8 : 16;
        if (tokens < wanted) {
            uint256 paid = rate == RATE_ONE ? tokens : tokens.mulDiv(rate, RATE_ONE);
            absorbed = amount - paid;
        }
        p.captured = true;
        CardProgram.Limits memory l = c.limits;
        CardLimits.spend(g, u, c.window, [uint256(l.perPurchase), l.daily, l.monthly], 0, amount, false);
    }

    /// @dev What a charge of `wanted` tokens can take from `owner`: its available balance, then the program's debt cap
    ///      less the debt the owner already carries to it. Debt to another creditor leaves no room for new debt here.
    function _chargeable(IReservationCore core, address owner, address token, uint256 wanted)
        private
        view
        returns (uint256)
    {
        uint256 room = core.available(owner, token);
        (address creditor, uint256 debt) = core.debtOf(owner, token);
        if (debt == 0 || creditor == address(this)) {
            uint256 cap = core.debtCap(owner, address(this), token);
            if (cap > debt) room += cap - debt;
        }
        return wanted < room ? wanted : room;
    }

    /// @notice Refunds `amount` settlement units across legs `l` (cash, savings, credit, late charge) in reverse order,
    ///         pulling each leg's token from the caller, and returns the cash (with any late charge), share and credit
    ///         tokens refunded.
    function refund(IReservationCore core, CardProgram.Leg[4] memory l, address creditLine, uint256 amount)
        external
        returns (uint256[3] memory tokens)
    {
        uint256 rest = amount;
        uint256[4] memory take;
        for (uint256 i = 4; i > 0; --i) {
            take[i - 1] = rest < l[i - 1].value ? rest : l[i - 1].value;
            rest -= take[i - 1];
        }
        if (rest != 0) revert CardProgram.RefundExceedsCapture(rest);

        if (take[3] != 0) tokens[0] = _refundLeg(core, l[3], take[3]);
        if (take[2] != 0) {
            tokens[2] = _refundLeg(core, l[2], take[2]);
            CreditLine(creditLine).sync(l[2].id);
        }
        if (take[1] != 0) {
            SavingsFacility facility = SavingsFacility(core.getHold(l[1].holdOwner, l[1].id).payee);
            uint256 assets = _toTokenUp(take[1], l[1].rate);
            SafeTransferLib.safeTransferFrom(facility.ASSET(), msg.sender, address(this), assets);
            SafeTransferLib.safeApprove(facility.ASSET(), address(facility), assets);
            tokens[1] = facility.refund(l[1].holdOwner, l[1].id, assets);
        }
        if (take[0] != 0) tokens[0] += _refundLeg(core, l[0], take[0]);
    }

    /// @dev Pulls a cash, credit or charge leg's tokens for `take` settlement units from the caller and refunds the leg
    ///      as its payee.
    function _refundLeg(IReservationCore core, CardProgram.Leg memory leg, uint256 take)
        private
        returns (uint256 tokens)
    {
        tokens = take == leg.value ? leg.refundable : _toTokenUp(take, leg.rate);
        if (tokens > leg.refundable) tokens = leg.refundable;
        SafeTransferLib.safeTransferFrom(leg.token, msg.sender, address(this), tokens);
        // forge-lint: disable-next-line(unsafe-typecast)
        core.refund(leg.holdOwner, leg.id, uint128(tokens));
    }

    /// @notice Issues a card to owner; its ceiling starts at the issued limits, in SETTLEMENT_TOKEN units.
    function issueCard(
        CardProgram.Card storage c,
        bytes32 card,
        address owner,
        uint40 expiry,
        CardProgram.Limits memory limits,
        uint8 legs
    ) external {
        if (c.status != CardProgram.Status.None) revert CardProgram.CardExists();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // Legs are CASH | SAVINGS | CREDIT at most (7).
        // forge-lint: disable-next-line(block-timestamp)
        if (owner == address(0) || expiry <= block.timestamp || legs == 0 || legs > 7) {
            revert CardProgram.InvalidCard();
        }
        c.owner = owner;
        c.expiry = expiry;
        c.status = CardProgram.Status.Active;
        c.legs = legs;
        c.limits = limits;
        c.ceiling = limits;
        emit CardIssued(card, owner, expiry, limits, legs);
    }

    /// @notice Copies an active or frozen card to an unissued one with a new expiry, and closes the old card.
    function replaceCard(
        CardProgram.Card storage old,
        CardProgram.Card storage c,
        bytes32 oldCard,
        bytes32 newCard,
        uint40 expiry
    ) external {
        if (old.status != CardProgram.Status.Active && old.status != CardProgram.Status.Frozen) {
            revert CardProgram.CardNotActive();
        }
        if (c.status != CardProgram.Status.None) revert CardProgram.CardExists();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (expiry <= block.timestamp) revert CardProgram.InvalidCard();
        c.owner = old.owner;
        c.status = old.status;
        c.legs = old.legs;
        c.limits = old.limits;
        c.ceiling = old.ceiling;
        c.window = old.window;
        c.expiry = expiry;
        old.status = CardProgram.Status.Closed;
        emit CardReplaced(oldCard, newCard, expiry);
        emit CardStatusSet(oldCard, CardProgram.Status.Closed);
    }

    /// @notice Reports activity on owner's account to its lifecycle; with admit, declines unless the account takes
    ///         new holds (dormant accounts decline as inactive, closed accounts and estates as closed).
    function noteActivity(address lifecycle, address owner, bool admit) external {
        AccountLifecycle.Status account = AccountLifecycle(lifecycle).noteActivity(owner);
        if (!admit) return;
        if (account == AccountLifecycle.Status.Dormant) revert CardProgram.AccountInactive();
        if (account == AccountLifecycle.Status.Closed || account == AccountLifecycle.Status.Estate) {
            revert CardProgram.CardsClosed();
        }
    }

    /// @notice Raises (or sets) a card's limits up to its ceiling. Amounts are in SETTLEMENT_TOKEN units.
    function raiseLimits(CardProgram.Card storage c, bytes32 card, CardProgram.Limits memory limits) external {
        CardProgram.Limits memory ceiling = c.ceiling;
        if (
            limits.perPurchase > ceiling.perPurchase || limits.daily > ceiling.daily || limits.monthly > ceiling.monthly
        ) revert CardProgram.LimitAboveCeiling();
        c.limits = limits;
        emit LimitsSet(card, limits, ceiling);
    }

    /// @notice Lowers a card's limits, bringing its ceiling down with them.
    function lowerLimits(CardProgram.Card storage c, bytes32 card, CardProgram.Limits memory limits) external {
        CardProgram.Limits memory current = c.limits;
        if (
            limits.perPurchase > current.perPurchase || limits.daily > current.daily || limits.monthly > current.monthly
        ) revert CardProgram.LimitAboveCeiling();
        c.limits = limits;
        CardProgram.Limits memory ceiling = c.ceiling;
        ceiling.perPurchase = _min80(ceiling.perPurchase, limits.perPurchase);
        ceiling.daily = _min80(ceiling.daily, limits.daily);
        ceiling.monthly = _min80(ceiling.monthly, limits.monthly);
        c.ceiling = ceiling;
        emit LimitsSet(card, limits, ceiling);
    }

    /// @notice Sets how far the issuer may raise a card's limits; limits above it come down to it.
    function allowLimits(CardProgram.Card storage c, bytes32 card, CardProgram.Limits memory ceiling) external {
        c.ceiling = ceiling;
        CardProgram.Limits memory limits = c.limits;
        limits.perPurchase = _min80(limits.perPurchase, ceiling.perPurchase);
        limits.daily = _min80(limits.daily, ceiling.daily);
        limits.monthly = _min80(limits.monthly, ceiling.monthly);
        c.limits = limits;
        emit LimitsSet(card, limits, ceiling);
    }

    /// @notice Carries an owner's counted usage, its cards' windows and its merchant mandates' spend from another
    ///         instance of the program into this one's storage. Counts only rise; every card must be the owner's.
    function carryUsage(
        mapping(bytes32 => CardProgram.Card) storage cards,
        mapping(address => CardLimits.Mandate) storage ownerMandates,
        CardLimits.Usage storage u,
        address owner,
        CardLimits.Usage calldata usage,
        bytes32[] calldata cardIds,
        CardLimits.Window[] calldata windows,
        address[] calldata merchants,
        CardLimits.Mandate[] calldata spent
    ) external {
        if (cardIds.length != windows.length || merchants.length != spent.length) {
            revert CardProgram.InvalidAmount();
        }
        CardLimits.carryUsage(u, usage);
        // CardLimits is a linked library over the program's own storage; the issuer names a handful of entries.
        // forge-lint: disable-start(calls-loop)
        for (uint256 i; i < cardIds.length; ++i) {
            CardProgram.Card storage c = cards[cardIds[i]];
            if (c.owner != owner) revert CardProgram.InvalidCard();
            CardLimits.carryWindow(c.window, windows[i]);
        }
        for (uint256 i; i < merchants.length; ++i) {
            CardLimits.carryMandate(ownerMandates[merchants[i]], spent[i]);
        }
        // forge-lint: disable-end(calls-loop)
    }

    function _min80(uint80 a, uint80 b) private pure returns (uint80) {
        return a < b ? a : b;
    }

    function _toTokenUp(uint256 units, uint256 rate) private pure returns (uint256) {
        return rate == RATE_ONE ? units : units.mulDivUp(RATE_ONE, rate);
    }
}
