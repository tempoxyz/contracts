// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { PullOutcome, SpendRail } from "./SpendRail.sol";

/// @notice Model of a Stripe Issuing card program run by Bridge on top of a rail.
/// @dev Mirrors what monorail does today for noncustodial just-in-time cards: every authorization
///      pulls its hold (amount, MCC buffer and estimated fee) synchronously before Stripe answers;
///      a capture above the hold pulls the difference; the final capture, a reversal or an expiry
///      returns the unused hold; refunds and won disputes are credited back. When a pull fails
///      after the card was approved, the platform reserve settles with the network and the
///      cardholder carries a negative balance.
abstract contract CardProgram is SpendRail {
    // Merchant category codes the program treats specially.
    uint16 internal constant MCC_GROCERY = 5411;
    uint16 internal constant MCC_RESTAURANT = 5812;
    uint16 internal constant MCC_BAR = 5813;
    uint16 internal constant MCC_FAST_FOOD = 5814;
    uint16 internal constant MCC_TAXI = 4121;
    uint16 internal constant MCC_CAR_RENTAL = 7512;
    uint16 internal constant MCC_HOTEL = 7011;
    uint16 internal constant MCC_AIRLINE = 4511;
    uint16 internal constant MCC_FUEL_PUMP = 5542;
    uint16 internal constant MCC_ATM = 6011;

    uint256 internal constant TIP_BUFFER_BPS = 2000;
    uint256 internal constant FUEL_PREAUTH_HOLD = 100e6;
    uint256 internal constant FUEL_PREAUTH_THRESHOLD = 1e6;

    enum AuthStatus {
        None,
        Declined,
        Pending,
        Closed
    }

    struct Authorization {
        address cardholder;
        uint16 mcc;
        uint16 feeBps;
        AuthStatus status;
        uint64 expiresAt;
        uint256 authorized;
        /// Funds the program holds for this authorization (settled pulls plus reserve cover).
        uint256 held;
        uint256 captured;
        uint256 fees;
        uint256 returned;
        uint256 refunded;
        uint256 reserveCovered;
    }

    mapping(uint256 id => Authorization) internal auths;
    uint256 internal authCount;
    uint256 private _pullSeq;

    /// Σ pulls that reached settlement.
    uint256 internal settledPulls;
    /// Σ returned holds, refunds and dispute credits paid back to cardholders.
    uint256 internal creditedToCardholders;
    /// Σ reserve draws that covered failed pulls.
    uint256 internal reserveDrawn;
    mapping(address cardholder => uint256) internal cardholderDebt;

    /// @dev When set, the cardholder moves their funds between Bridge's preflight and the pull.
    mapping(address cardholder => bool) internal frontRunNextPull;
    /// @dev When set, the next pull is retried with the same action ID after it settles, as a
    ///      Bridge worker retrying a timed-out submission would.
    bool internal retryNextPull;
    uint256 internal lastRetrySettled;

    // ------------------------------------------------------------------
    // Card lifecycle
    // ------------------------------------------------------------------

    function _authorize(address cardholder, uint256 amount, uint16 mcc) internal returns (uint256 id, bool approved) {
        return _authorizeWithFee(cardholder, amount, mcc, 0);
    }

    /// @param feeBps Card fee (e.g. cross-border plus FX) pulled with the principal.
    function _authorizeWithFee(address cardholder, uint256 amount, uint16 mcc, uint16 feeBps)
        internal
        returns (uint256 id, bool approved)
    {
        id = ++authCount;
        Authorization storage a = auths[id];
        a.cardholder = cardholder;
        a.mcc = mcc;
        a.feeBps = feeBps;
        a.authorized = amount;
        a.expiresAt = uint64(block.timestamp + _expiryWindow(mcc));
        uint256 hold = _holdFor(amount, mcc) + _fee(amount, feeBps);

        PullOutcome outcome = _pull(cardholder, hold);
        if (outcome == PullOutcome.Rejected) {
            a.status = AuthStatus.Declined;
            return (id, false);
        }
        if (outcome == PullOutcome.FailedAfterApproval) _coverWithReserve(id, hold);
        a.held = hold;
        a.status = AuthStatus.Pending;
        return (id, true);
    }

    /// @notice Hotels and rentals raise an open authorization.
    function _incrementAuthorization(uint256 id, uint256 extra) internal returns (bool approved) {
        Authorization storage a = _pending(id);
        uint256 hold = extra + _fee(extra, a.feeBps);
        PullOutcome outcome = _pull(a.cardholder, hold);
        if (outcome == PullOutcome.Rejected) return false;
        if (outcome == PullOutcome.FailedAfterApproval) _coverWithReserve(id, hold);
        a.authorized += extra;
        a.held += hold;
        return true;
    }

    /// @notice Captures `amount` (which may exceed the authorization, e.g. a tip). A capture the
    ///         hold cannot cover pulls the difference; the network must be paid either way.
    function _capture(uint256 id, uint256 amount, bool isFinal) internal {
        Authorization storage a = _pending(id);
        a.captured += amount;
        a.fees += _fee(amount, a.feeBps);
        uint256 owed = a.captured + a.fees;
        if (owed > a.held) {
            uint256 shortfall = owed - a.held;
            PullOutcome outcome = _pull(a.cardholder, shortfall);
            if (outcome != PullOutcome.Settled) _coverWithReserve(id, shortfall);
            a.held += shortfall;
        }
        if (isFinal) _close(id);
    }

    function _reverse(uint256 id) internal {
        _close(id);
    }

    function _expire(uint256 id) internal {
        Authorization storage a = _pending(id);
        require(block.timestamp >= a.expiresAt, "authorization not expired");
        _close(id);
    }

    /// @notice Merchant refund after capture.
    function _refundCapture(uint256 id, uint256 amount) internal {
        Authorization storage a = auths[id];
        require(a.status == AuthStatus.Closed, "refund before close");
        require(a.refunded + amount <= a.captured, "refund exceeds capture");
        a.refunded += amount;
        _credit(a.cardholder, amount);
    }

    /// @notice Stripe resolves a cardholder dispute. A won dispute credits the cardholder.
    function _resolveDispute(uint256 id, uint256 amount, bool won) internal {
        Authorization storage a = auths[id];
        require(a.status == AuthStatus.Closed, "dispute before close");
        require(a.refunded + amount <= a.captured, "dispute exceeds capture");
        if (!won) return;
        a.refunded += amount;
        _credit(a.cardholder, amount);
    }

    /// @notice A capture with no prior authorization (offline or force post).
    function _forceCapture(address cardholder, uint256 amount, uint16 mcc) internal returns (uint256 id) {
        id = ++authCount;
        Authorization storage a = auths[id];
        a.cardholder = cardholder;
        a.mcc = mcc;
        a.status = AuthStatus.Pending;
        a.expiresAt = uint64(block.timestamp);
        _capture(id, amount, true);
    }

    function _atmWithdrawal(address cardholder, uint256 amount, uint256 atmFee)
        internal
        returns (uint256 id, bool approved)
    {
        (id, approved) = _authorize(cardholder, amount + atmFee, MCC_ATM);
        if (approved) _capture(id, amount + atmFee, true);
    }

    // ------------------------------------------------------------------
    // Money movement
    // ------------------------------------------------------------------

    function _pull(address cardholder, uint256 amount) internal returns (PullOutcome outcome) {
        bytes32 actionId = keccak256(abi.encode("card.pull", ++_pullSeq));
        if (frontRunNextPull[cardholder]) {
            // Bridge's preflight saw enough funds and approved; the cardholder then moved them.
            frontRunNextPull[cardholder] = false;
            _railDrain(cardholder);
            outcome = _railPull(cardholder, amount, actionId);
            if (outcome == PullOutcome.Rejected) outcome = PullOutcome.FailedAfterApproval;
        } else {
            outcome = _railPull(cardholder, amount, actionId);
        }
        if (outcome == PullOutcome.Settled) {
            settledPulls += amount;
            if (retryNextPull) {
                retryNextPull = false;
                if (_railPull(cardholder, amount, actionId) == PullOutcome.Settled) {
                    settledPulls += amount;
                    lastRetrySettled = amount;
                }
            }
        }
    }

    function _credit(address cardholder, uint256 amount) internal {
        if (amount == 0) return;
        bytes32 actionId = keccak256(abi.encode("card.credit", ++_pullSeq));
        _railCredit(cardholder, amount, actionId);
        creditedToCardholders += amount;
    }

    function _coverWithReserve(uint256 id, uint256 amount) private {
        Authorization storage a = auths[id];
        a.reserveCovered += amount;
        reserveDrawn += amount;
        cardholderDebt[a.cardholder] += amount;
        vm.prank(reserveWallet);
        usd.transfer(settlement, amount);
    }

    function _close(uint256 id) private {
        Authorization storage a = _pending(id);
        uint256 owed = a.captured + a.fees;
        uint256 unused = a.held - owed;
        a.status = AuthStatus.Closed;
        // Unused hold the reserve covered was never the cardholder's cash: it reduces their debt.
        uint256 offset = unused < a.reserveCovered ? unused : a.reserveCovered;
        cardholderDebt[a.cardholder] -= offset;
        uint256 refundable = unused - offset;
        if (refundable != 0) {
            a.returned += refundable;
            _credit(a.cardholder, refundable);
        }
    }

    // ------------------------------------------------------------------
    // Program rules
    // ------------------------------------------------------------------

    function _holdFor(uint256 amount, uint16 mcc) internal pure returns (uint256) {
        if (mcc == MCC_FUEL_PUMP && amount <= FUEL_PREAUTH_THRESHOLD) return FUEL_PREAUTH_HOLD;
        if (mcc == MCC_RESTAURANT || mcc == MCC_BAR || mcc == MCC_FAST_FOOD || mcc == MCC_TAXI || mcc == MCC_CAR_RENTAL)
        {
            return amount + amount * TIP_BUFFER_BPS / 10_000;
        }
        return amount;
    }

    function _expiryWindow(uint16 mcc) internal pure returns (uint256) {
        if (mcc == MCC_HOTEL || mcc == MCC_AIRLINE || mcc == MCC_CAR_RENTAL) return 31 days;
        return 7 days;
    }

    function _fee(uint256 amount, uint16 feeBps) internal pure returns (uint256) {
        return (amount * feeBps + 9999) / 10_000;
    }

    function _pending(uint256 id) internal view returns (Authorization storage a) {
        a = auths[id];
        require(a.status == AuthStatus.Pending, "authorization not pending");
    }
}
