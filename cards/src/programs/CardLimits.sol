// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { AccountLifecycle } from "./AccountLifecycle.sol";
import { IdentityRules } from "./IdentityRules.sol";

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
    /// @dev Everything a purchase updates shares one slot, so a card's first purchase creates one slot, not two.
    struct Window {
        uint32 day;
        uint32 month;
        uint64 daySpent;
        uint64 monthSpent;
        uint64 committed;
        /// @dev Zero means no lifetime cap.
        uint64 cap;
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

    /// @notice A card's state.
    enum Status {
        None,
        Active,
        Frozen,
        Closed
    }

    /// @notice A card's own limits, in base units. The program's owner terms apply on top.
    struct Limits {
        uint80 perPurchase;
        uint80 daily;
        uint80 monthly;
    }

    /// @notice A card: its owner, state, the source kinds it may draw on, its limits and the ceiling the owner lets
    ///         the issuer raise them to, and its windows.
    struct Card {
        address owner;
        uint40 expiry;
        Status status;
        /// @dev Source kinds the card may draw on: cash 1, savings 2, credit 4.
        uint8 kinds;
        /// @dev The card's number in the program, which purchases record instead of its id.
        uint32 index;
        /// @dev Who holds the card frozen: the issuer 1, the owner 2. It is active only once neither does.
        uint8 frozen;
        Limits limits;
        Limits ceiling;
        Window window;
    }

    /// @dev Bits of Card.frozen.
    uint8 internal constant ISSUER_FROZE = 1;
    uint8 internal constant OWNER_FROZE = 2;

    event CardIssued(bytes32 indexed card, address indexed owner, uint40 expiry, Limits limits, uint8 kinds);
    event CardReplaced(bytes32 indexed oldCard, bytes32 indexed newCard, uint40 expiry);
    event CardStatusSet(bytes32 indexed card, Status status);
    event LimitsSet(bytes32 indexed card, Limits limits, Limits ceiling);

    event Granted(address indexed owner, Terms terms, uint32 epoch);
    event MandateSet(address indexed owner, address indexed merchant, bool revoked, uint96 monthlyLimit);
    event CardCapSet(bytes32 indexed card, uint64 cap);
    event CardExpirySet(bytes32 indexed card, uint40 expiry);
    event UsageCarried(address indexed owner);

    error AccountInactive();
    error CardExists();
    error CardExpired();
    error CardsClosed();
    error NoTerms();
    error CardNotActive();
    error InvalidCard();
    error LimitAboveCeiling();

    /// @notice Issues card `card` to `owner` with number `index`.
    function issue(
        Card storage c,
        bytes32 card,
        address owner,
        uint40 expiry,
        Limits calldata given,
        uint8 kinds,
        uint32 index,
        uint256 scale
    ) external {
        Limits memory limits = _baseLimits(given, scale);
        if (c.status != Status.None) revert CardExists();
        // Expiries are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (owner == address(0) || expiry <= block.timestamp || kinds == 0 || kinds > 7) revert InvalidCard();
        (c.owner, c.expiry, c.status, c.kinds, c.index) = (owner, expiry, Status.Active, kinds, index);
        (c.limits, c.ceiling) = (limits, limits);
        // Starting the window here makes issuance, not the card's first swipe, create its slot. A window counts only
        // on the day and month it names, so naming the UTC ones with nothing spent changes no limit.
        (c.window.day, c.window.month) = calendar(0);
        emit CardIssued(card, owner, expiry, limits, kinds);
    }

    /// @notice Replaces card `old` with `c` (number `index`): the new card takes its owner, state, limits and
    ///         windows, and the old one closes.
    function replace(Card storage old, Card storage c, bytes32 oldCard, bytes32 newCard, uint40 expiry, uint32 index)
        external
    {
        if (old.status != Status.Active && old.status != Status.Frozen) revert CardNotActive();
        if (c.status != Status.None) revert CardExists();
        // forge-lint: disable-next-line(block-timestamp)
        if (expiry <= block.timestamp) revert InvalidCard();
        (c.owner, c.status, c.kinds, c.index, c.expiry) = (old.owner, old.status, old.kinds, index, expiry);
        c.frozen = old.frozen;
        (c.limits, c.ceiling, c.window) = (old.limits, old.ceiling, old.window);
        old.status = Status.Closed;
        emit CardReplaced(oldCard, newCard, expiry);
        emit CardStatusSet(oldCard, Status.Closed);
    }

    /// @notice Sets a card's limits: 0 the issuer raises them within the ceiling, 1 the owner lowers them (and the
    ///         ceiling with them), 2 the owner sets the ceiling (lowering limits above it).
    function setLimits(Card storage c, bytes32 card, Limits calldata limitsGiven, uint8 how, uint256 scale) external {
        Limits memory given = _baseLimits(limitsGiven, scale);
        if (c.status == Status.None || (how == 0 && c.status == Status.Closed)) revert CardNotActive();
        Limits memory limits = c.limits;
        Limits memory ceiling = c.ceiling;
        if (how == 2) {
            ceiling = given;
            limits = _lower(limits, given);
        } else {
            Limits memory bound = how == 0 ? ceiling : limits;
            if (given.perPurchase > bound.perPurchase || given.daily > bound.daily || given.monthly > bound.monthly) {
                revert LimitAboveCeiling();
            }
            limits = given;
            if (how == 1) ceiling = _lower(ceiling, given);
        }
        (c.limits, c.ceiling) = (limits, ceiling);
        emit LimitsSet(card, limits, ceiling);
    }

    /// @notice Carries an owner's usage, some of their cards' windows and merchant mandates counted on another
    ///         instance of the program into this one, as carryUsage, carryWindow and carryMandate do. Days and months
    ///         later than the owner's today (at utcOffset) are refused, so carrying never empties today's counts; a
    ///         card window's later day or month with nothing counted in it carries nothing.
    function carry(
        mapping(bytes32 => Card) storage cards,
        mapping(address => Mandate) storage ownerMandates,
        Usage storage u,
        address owner,
        int32 utcOffset,
        bytes calldata data
    ) external {
        (
            Usage memory usage,
            bytes32[] memory cardIds,
            Window[] memory windows,
            address[] memory merchants,
            Mandate[] memory spent
        ) = abi.decode(data, (Usage, bytes32[], Window[], address[], Mandate[]));
        if (cardIds.length != windows.length || merchants.length != spent.length) revert InvalidCard();
        (uint32 day, uint32 month) = calendar(utcOffset);
        if (usage.day > day || usage.month > month) revert InvalidCard();
        _carryUsage(u, usage);
        for (uint256 i; i < cardIds.length; ++i) {
            Card storage c = cards[cardIds[i]];
            Window memory w = windows[i];
            if (c.owner != owner) revert InvalidCard();
            // Issuance names the UTC day and month, which can be after the owner's; with nothing counted they say nothing.
            if (w.day > day) {
                if (w.daySpent != 0) revert InvalidCard();
                w.day = 0;
            }
            if (w.month > month) {
                if (w.monthSpent != 0) revert InvalidCard();
                w.month = 0;
            }
            _carryWindow(c.window, w);
        }
        for (uint256 i; i < merchants.length; ++i) {
            if (spent[i].month > month) revert InvalidCard();
            _carryMandate(ownerMandates[merchants[i]], spent[i]);
        }
        emit UsageCarried(owner);
    }

    /// @notice Grants `given` terms, in today's units worth `scale` per base unit (18 decimals), starting usage afresh.
    ///         Returns whether it is the owner's first grant.
    function grant(Grant storage g, Usage storage u, Terms calldata given, uint256 scale) external returns (bool) {
        Terms memory t = given;
        // _toBase reverts above 64 bits, so these casts keep every bit.
        // forge-lint: disable-start(unsafe-typecast)
        (t.limit, t.perPurchase, t.daily, t.monthly) =
        (
            uint64(_toBase(t.limit, scale)),
            uint64(_toBase(t.perPurchase, scale)),
            uint64(_toBase(t.daily, scale)),
            uint64(_toBase(t.monthly, scale))
        );
        // forge-lint: disable-end(unsafe-typecast)
        (g.terms, g.active) = (t, true);
        uint32 epoch = ++g.epoch;
        // Today's windows with nothing spent count like empty ones, and keep the slot, so the first swipe creates none.
        (uint32 day, uint32 month) = calendar(t.utcOffset);
        (u.committed, u.day, u.month, u.daySpent, u.monthSpent) = (0, day, month, 0, 0);
        emit Granted(msg.sender, t, epoch);
        return epoch == 1;
    }

    /// @notice The ABI encoding of card `c` with the status its account's lifecycle gives it: closed once the account
    ///         closed, frozen while the account is an estate.
    function cardView(Card storage c, address lifecycle) external view returns (bytes memory) {
        Card memory card = c;
        if (lifecycle != address(0) && card.status != Status.None && card.status != Status.Closed) {
            AccountLifecycle.Status account = AccountLifecycle(lifecycle).statusOf(card.owner);
            if (account == AccountLifecycle.Status.Closed) card.status = Status.Closed;
            else if (account == AccountLifecycle.Status.Estate) card.status = Status.Frozen;
        }
        return abi.encode(card);
    }

    function _toBase(uint256 amount, uint256 scale) private pure returns (uint256 base) {
        base = scale == 1e18 ? amount : amount * 1e18 / scale;
        if (base > type(uint64).max) revert InvalidCard();
    }

    /// @notice Counts `amount` toward the owner's usage and card `c`'s windows (checking every limit on `total` when
    ///         `enforce`), and toward merchant `merchant`'s mandate `m` unless it is zero. Returns the owner's local
    ///         day and the grant's epoch (low 8 bits).
    function use(
        Card storage c,
        Grant storage g,
        Usage storage u,
        Mandate storage m,
        address merchant,
        uint256 total,
        uint256 amount,
        bool enforce
    ) external returns (uint32 day, uint8 epoch) {
        Limits memory l = c.limits;
        (day,) = _spend(g, u, c.window, [uint256(l.perPurchase), l.daily, l.monthly], total, amount, enforce);
        if (merchant != address(0)) _useMandate(m, g.terms.utcOffset, amount, enforce, total != 0);
        // Purchases record the low 8 bits of the epoch and compare them only to it.
        // forge-lint: disable-next-line(unsafe-typecast)
        epoch = uint8(g.epoch);
    }

    /// @notice giveBack for spend counted on local day `day` (its month follows from it), and to the merchant
    ///         mandate `m` the purchase counted toward, when it counted in that month.
    function giveBackOn(
        Grant storage g,
        Usage storage u,
        Window storage w,
        Mandate storage m,
        uint32 epoch,
        uint32 day,
        uint256 amount
    ) external {
        uint32 month = _month(day);
        _giveBack(g, u, w, epoch, day, month, amount);
        // Bounded by the 96-bit count it came from.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (m.month == month) m.spent = uint96(_less(m.spent, amount));
    }

    /// @notice Sets a card's spending cap (`what` 0, in units worth `scale` per base unit), expiry (1) or status (2).
    function set(Card storage c, bytes32 card, uint8 what, uint256 value, uint256 scale) external {
        Status was = c.status;
        if (was == Status.None) revert InvalidCard();
        if (what == 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            c.window.cap = uint64(_toBase(value, scale));
            emit CardCapSet(card, c.window.cap);
        } else if (what == 1) {
            if (value > type(uint40).max) revert InvalidCard();
            // Checked to fit just above.
            // forge-lint: disable-start(unsafe-typecast)
            c.expiry = uint40(value);
            emit CardExpirySet(card, uint40(value));
            // forge-lint: disable-end(unsafe-typecast)
        } else {
            if (was == Status.Closed || value == 0 || value > uint8(Status.Closed)) revert CardNotActive();
            // Active lifts only the issuer's freeze; a card the owner froze stays frozen.
            uint8 frozen = value == uint8(Status.Frozen) ? c.frozen | ISSUER_FROZE : c.frozen & ~ISSUER_FROZE;
            _setStatus(c, card, value == uint8(Status.Closed), frozen);
        }
    }

    /// @notice The owner freezes (`how` 1), lifts its own freeze (2) or closes (3) a card. Lifting leaves an issuer's
    ///         freeze in place.
    function setOwnStatus(Card storage c, bytes32 card, uint8 how) external {
        Status was = c.status;
        uint8 frozen = c.frozen;
        bool owned = frozen & OWNER_FROZE != 0;
        bool ok = was != Status.Closed && (how == 1 ? !owned : how == 2 ? owned : how == 3);
        if (!ok) revert CardNotActive();
        _setStatus(c, card, how == 3, how == 1 ? frozen | OWNER_FROZE : frozen & ~OWNER_FROZE);
    }

    function _setStatus(Card storage c, bytes32 card, bool closes, uint8 frozen) private {
        Status to = closes ? Status.Closed : frozen != 0 ? Status.Frozen : Status.Active;
        (c.status, c.frozen) = (to, frozen);
        emit CardStatusSet(card, to);
    }

    /// @notice Checks card `c` can start a purchase under grant `g`, reporting activity to the account lifecycle
    ///         and checking the identity rules when set.
    function admit(Card storage c, Grant storage g, address lifecycle, address identityRules) external {
        if (c.status != Status.Active) revert CardNotActive();
        // Expiries are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= c.expiry) revert CardExpired();
        if (!g.active) revert NoTerms();
        address owner = c.owner;
        if (lifecycle != address(0)) {
            AccountLifecycle.Status account = AccountLifecycle(lifecycle).noteActivity(owner);
            if (account == AccountLifecycle.Status.Dormant) revert AccountInactive();
            if (account == AccountLifecycle.Status.Closed || account == AccountLifecycle.Status.Estate) {
                revert CardsClosed();
            }
        }
        if (identityRules != address(0)) IdentityRules(identityRules).admit(owner);
    }

    /// @notice Sets the caller's mandate `m` for `merchant`: revoked, or a monthly limit in units worth `scale`
    ///         per base unit.
    function setMandate(Mandate storage m, address merchant, bool revoked, uint256 monthlyLimit, uint256 scale)
        external
    {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 limit = uint96(_toBase(monthlyLimit, scale));
        (m.revoked, m.monthlyLimit) = (revoked, limit);
        emit MandateSet(msg.sender, merchant, revoked, limit);
    }

    function _baseLimits(Limits calldata l, uint256 scale) private pure returns (Limits memory) {
        // forge-lint: disable-next-item(unsafe-typecast)
        return Limits(
            uint80(_limitToBase(l.perPurchase, scale)),
            uint80(_limitToBase(l.daily, scale)),
            uint80(_limitToBase(l.monthly, scale))
        );
    }

    // A limit past what base units hold limits nothing, so it saturates rather than refusing a settlement token whose
    // units are worth less than a dollar.
    function _limitToBase(uint256 amount, uint256 scale) private pure returns (uint256 base) {
        base = scale == 1e18 ? amount : amount * 1e18 / scale;
        if (base > type(uint64).max) base = type(uint64).max;
    }

    function _lower(Limits memory a, Limits memory b) private pure returns (Limits memory) {
        return Limits(
            a.perPurchase < b.perPurchase ? a.perPurchase : b.perPurchase,
            a.daily < b.daily ? a.daily : b.daily,
            a.monthly < b.monthly ? a.monthly : b.monthly
        );
    }

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
        return _spend(g, u, w, cardLimits, total, amount, enforce);
    }

    function _spend(
        Grant storage g,
        Usage storage u,
        Window storage w,
        uint256[3] memory cardLimits,
        uint256 total,
        uint256 amount,
        bool enforce
    ) private returns (uint32 day, uint32 month) {
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
        (uint64(cardCommitted), day, month, uint64(cardDay), uint64(cardMonth));
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
        _giveBack(g, u, w, epoch, day, month, amount);
    }

    function _giveBack(
        Grant storage g,
        Usage storage u,
        Window storage w,
        uint32 epoch,
        uint32 day,
        uint32 month,
        uint256 amount
    ) private {
        // Each result is at most its first operand, which fits the field it came from.
        // forge-lint: disable-start(unsafe-typecast)
        if (g.epoch == epoch) {
            u.committed = uint64(_less(u.committed, amount));
            if (u.day == day) u.daySpent = uint64(_less(u.daySpent, amount));
            if (u.month == month) u.monthSpent = uint64(_less(u.monthSpent, amount));
        }
        w.committed = uint64(_less(w.committed, amount));
        if (w.day == day) w.daySpent = uint64(_less(w.daySpent, amount));
        if (w.month == month) w.monthSpent = uint64(_less(w.monthSpent, amount));
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @notice Checks a merchant mandate and counts `amount` toward its monthly limit.
    function useMandate(Mandate storage m, int32 utcOffset, uint256 amount) external {
        _useMandate(m, utcOffset, amount, true, true);
    }

    /// @dev Without enforce (a tip or late charge the network already took) it counts in full without refusing, so
    ///      giving it back later returns exactly what was counted. A mandate that has counted once keeps counting
    ///      after its limit is lifted, so a limit set again starts from what is still spent.
    function _useMandate(Mandate storage m, int32 utcOffset, uint256 amount, bool enforce, bool charges) private {
        if (charges && m.revoked) revert MerchantRevoked();
        uint96 limit = m.monthlyLimit;
        uint32 last = m.month;
        if (limit == 0 && last == 0) return;
        (, uint32 month) = calendar(utcOffset);
        uint256 spent = (last == month ? m.spent : 0) + amount;
        if (enforce && limit != 0 && spent > limit) revert MerchantLimitExceeded();
        m.month = month;
        // Saturates at the field's bound, far past any limit it holds.
        // forge-lint: disable-next-line(unsafe-typecast)
        m.spent = spent > type(uint96).max ? type(uint96).max : uint96(spent);
    }

    /// @notice Carries an owner's usage counted on another instance of the program into this one. Counts only rise:
    ///         a later window replaces an earlier one, the same window keeps the larger count, and totals keep the
    ///         larger. Carrying the same usage twice changes nothing.
    function carryUsage(Usage storage u, Usage calldata from) external {
        _carryUsage(u, from);
    }

    function _carryUsage(Usage storage u, Usage memory from) private {
        u.committed = _more64(u.committed, from.committed);
        if (from.day > u.day) (u.day, u.daySpent) = (from.day, from.daySpent);
        else if (from.day == u.day) u.daySpent = _more64(u.daySpent, from.daySpent);
        if (from.month > u.month) (u.month, u.monthSpent) = (from.month, from.monthSpent);
        else if (from.month == u.month) u.monthSpent = _more64(u.monthSpent, from.monthSpent);
    }

    /// @notice Carries a card's window counted elsewhere, as carryUsage does. The card's cap stays its own.
    function carryWindow(Window storage w, Window calldata from) external {
        _carryWindow(w, from);
    }

    function _carryWindow(Window storage w, Window memory from) private {
        w.committed = _more64(w.committed, from.committed);
        if (from.day > w.day) (w.day, w.daySpent) = (from.day, from.daySpent);
        else if (from.day == w.day && from.daySpent > w.daySpent) w.daySpent = from.daySpent;
        if (from.month > w.month) (w.month, w.monthSpent) = (from.month, from.monthSpent);
        else if (from.month == w.month && from.monthSpent > w.monthSpent) w.monthSpent = from.monthSpent;
    }

    /// @notice Carries a merchant mandate's monthly spend counted elsewhere. Its limit and revocation stay its own.
    function carryMandate(Mandate storage m, Mandate calldata from) external {
        _carryMandate(m, from);
    }

    function _carryMandate(Mandate storage m, Mandate memory from) private {
        if (from.month > m.month) (m.month, m.spent) = (from.month, from.spent);
        else if (from.month == m.month && from.spent > m.spent) m.spent = from.spent;
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

    function _more64(uint64 a, uint64 b) private pure returns (uint64) {
        return b > a ? b : a;
    }

    function _less(uint256 a, uint256 b) private pure returns (uint256) {
        return b >= a ? 0 : a - b;
    }
}
