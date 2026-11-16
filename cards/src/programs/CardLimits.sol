// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title CardLimits
/// @notice Spend accounting for card programs: an owner's terms and usage, a card's windows, and merchant mandates.
/// @dev Linked as an external library so a program keeps its runtime code small. Windows are calendar days and months
///      at the owner's UTC offset. Amounts are settlement units; a zero term means no limit.
library CardLimits {
    /// @notice What an owner allows a program across all their cards. Zero means no limit.
    struct Terms {
        uint64 limit;
        uint64 perPurchase;
        uint64 daily;
        uint64 monthly;
        /// @dev Seconds east of UTC where the owner's calendar days and months start.
        int32 utcOffset;
    }

    struct Grant {
        Terms terms;
        bool active;
        uint32 epoch;
    }

    /// @notice An owner's spend under their current grant: open holds plus captures less refunds, and its windows.
    struct Usage {
        uint64 committed;
        uint32 day;
        uint32 month;
        uint64 daySpent;
        uint64 monthSpent;
    }

    /// @notice A card's windows and what it committed over its life, under an optional lifetime cap.
    struct Window {
        uint32 day;
        uint32 month;
        uint96 daySpent;
        uint96 monthSpent;
        /// @dev Zero means no lifetime cap.
        uint64 cap;
        uint64 committed;
    }

    struct Mandate {
        bool revoked;
        /// @dev Zero means no monthly limit for the merchant.
        uint96 monthlyLimit;
        uint32 month;
        uint96 spent;
    }

    /// @notice A limit refused a purchase: 0 per purchase, 1 daily, 2 monthly, 3 the owner's lifetime limit, 4 the card's cap.
    error LimitExceeded(uint8 which);
    error MerchantRevoked();
    error MerchantLimitExceeded();

    /// @notice Counts `amount` toward the owner's usage and the card's window today, checking every limit (the
    ///         per-purchase ones on the purchase's `total`) when `enforce`. Returns today's day and month numbers.
    function spend(
        Grant storage g,
        Usage storage u,
        Window storage w,
        uint256[3] calldata cardLimits,
        uint256 total,
        uint256 amount,
        bool enforce
    ) external returns (uint32 day, uint32 month) {
        Terms memory t = g.terms;
        if (enforce && (total > cardLimits[0] || (t.perPurchase != 0 && total > t.perPurchase))) {
            revert LimitExceeded(0);
        }
        (day, month) = calendar(t.utcOffset);
        uint256 committed = u.committed + amount;
        uint256 daySpent = (u.day == day ? u.daySpent : 0) + amount;
        uint256 monthSpent = (u.month == month ? u.monthSpent : 0) + amount;
        uint256 cardCommitted = w.committed + amount;
        uint256 cardDay = (w.day == day ? w.daySpent : 0) + amount;
        uint256 cardMonth = (w.month == month ? w.monthSpent : 0) + amount;
        if (enforce) {
            if (cardDay > cardLimits[1] || (t.daily != 0 && daySpent > t.daily)) revert LimitExceeded(1);
            if (cardMonth > cardLimits[2] || (t.monthly != 0 && monthSpent > t.monthly)) revert LimitExceeded(2);
            if (t.limit != 0 && committed > t.limit) revert LimitExceeded(3);
            if (w.cap != 0 && cardCommitted > w.cap) revert LimitExceeded(4);
        }
        // Purchases are at most 64 bits; these totals are bounded by limits of the same width.
        // forge-lint: disable-start(unsafe-typecast)
        (u.committed, u.day, u.month, u.daySpent, u.monthSpent) =
        (uint64(committed), day, month, uint64(daySpent), uint64(monthSpent));
        (w.committed, w.day, w.month, w.daySpent, w.monthSpent) =
        (uint64(cardCommitted), day, month, uint96(cardDay), uint96(cardMonth));
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice Gives `amount` back to the owner's and card's totals, and to the windows of `day` and `month` while
    ///         they are current. Spend counted under an earlier grant (`epoch`) gives back only to the card.
    function giveBack(
        Grant storage g,
        Usage storage u,
        Window storage w,
        uint32 epoch,
        uint32 day,
        uint32 month,
        uint256 amount
    ) external {
        // Each result is at most its first operand, which fits the field it came from.
        // forge-lint: disable-start(unsafe-typecast)
        if (g.epoch == epoch) {
            u.committed = uint64(_less(u.committed, amount));
            if (u.day == day) u.daySpent = uint64(_less(u.daySpent, amount));
            if (u.month == month) u.monthSpent = uint64(_less(u.monthSpent, amount));
        }
        w.committed = uint64(_less(w.committed, amount));
        if (w.day == day) w.daySpent = uint96(_less(w.daySpent, amount));
        if (w.month == month) w.monthSpent = uint96(_less(w.monthSpent, amount));
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice Checks a merchant mandate and counts `amount` toward its monthly limit.
    function useMandate(Mandate storage m, int32 utcOffset, uint256 amount) external {
        if (m.revoked) revert MerchantRevoked();
        uint96 limit = m.monthlyLimit;
        if (limit == 0) return;
        (, uint32 month) = calendar(utcOffset);
        uint256 spent = (m.month == month ? m.spent : 0) + amount;
        if (spent > limit) revert MerchantLimitExceeded();
        m.month = month;
        // Bounded by the 96-bit limit just checked.
        // forge-lint: disable-next-line(unsafe-typecast)
        m.spent = uint96(spent);
    }

    /// @notice Today's day number (days since 1970) and month number (year * 12 + month - 1) at `utcOffset`.
    function calendar(int32 utcOffset) public view returns (uint32 day, uint32 month) {
        // Block timestamps and offsets are far from the int256 bounds; day numbers fit 32 bits.
        // forge-lint: disable-start(unsafe-typecast)
        int256 local = int256(block.timestamp) + int256(utcOffset);
        day = uint32(uint256(local) / 1 days);
        // forge-lint: disable-end(unsafe-typecast)
        month = _month(day);
    }

    /// @dev The civil month of `day`, after Howard Hinnant's civil_from_days. Its divisions floor on purpose.
    // forge-lint: disable-start(divide-before-multiply)
    function _month(uint32 day) private pure returns (uint32) {
        uint256 z = uint256(day) + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        uint256 y = yoe + era * 400 + (m <= 2 ? 1 : 0);
        // Years stay far below 2^32 / 12.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(y * 12 + m - 1);
    }
    // forge-lint: disable-end(divide-before-multiply)

    function _less(uint256 a, uint256 b) private pure returns (uint256) {
        return b >= a ? 0 : a - b;
    }
}
