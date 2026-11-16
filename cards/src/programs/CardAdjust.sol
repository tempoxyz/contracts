// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

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

    uint256 private constant RATE_ONE = 1e18;

    /// @notice Moves open purchase `p` to `amount` settlement units. An increase checks the card, the owner's grant and
    ///         every limit on the new total and reserves the difference on the cash leg `id`; a decrease gives back
    ///         what the cash leg still holds of it. Returns what the cash leg holds afterwards, in tokens.
    function adjust(
        IReservationCore core,
        CardProgram.Purchase storage p,
        CardProgram.Card storage c,
        CardLimits.Grant storage g,
        CardLimits.Usage storage u,
        address token,
        uint256 rate,
        bytes32 id,
        uint128 amount
    ) external returns (uint256 cash) {
        if (!p.open) revert CardProgram.PurchaseNotOpen();
        // Expiries are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.expiresAt) revert CardProgram.PurchaseExpired();
        if (amount == 0 || amount > type(uint64).max || p.standIn) revert CardProgram.InvalidAmount();
        address owner = p.owner;
        uint256 previous = p.amount;
        uint256 held = core.getHold(owner, id).held;
        if (amount > previous) {
            if (c.status != CardProgram.Status.Active || !g.active) revert CardProgram.CardNotActive();
            uint256 more = amount - previous;
            uint256 tokens = _toTokenUp(more, rate);
            CardProgram.Limits memory l = c.limits;
            CardLimits.spend(g, u, c.window, [uint256(l.perPurchase), l.daily, l.monthly], amount, more, true);
            // An increase lands on the cash leg, which must exist.
            if (p.legs & 1 == 0 || core.available(owner, token) < tokens) revert CardProgram.InsufficientFunds(more);
            cash = held + tokens;
            // forge-lint: disable-next-line(unsafe-typecast)
            p.held += uint64(more);
        } else {
            uint256 less = previous - amount;
            uint256 tokens = _toTokenUp(less, rate);
            if (p.legs & 1 == 0 || tokens > held || less > p.held) revert CardProgram.InvalidAmount();
            cash = held - tokens;
            if (less != 0) CardLimits.giveBack(g, u, c.window, p.epoch, p.day, p.month, less);
            // forge-lint: disable-next-line(unsafe-typecast)
            p.held -= uint64(less);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        core.adjust(owner, id, uint128(cash));
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
        if (g.epoch == 0) revert CardProgram.NoTerms();
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

    function _toTokenUp(uint256 units, uint256 rate) private pure returns (uint256) {
        return rate == RATE_ONE ? units : units.mulDivUp(RATE_ONE, rate);
    }
}
