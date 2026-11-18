// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

import { AccountKeys } from "./AccountKeys.sol";
import { AccountLifecycle } from "./AccountLifecycle.sol";
import { CardAdjust } from "./CardAdjust.sol";
import { CardConvert } from "./CardConvert.sol";
import { CardFunding } from "./CardFunding.sol";
import { CardLimits } from "./CardLimits.sol";
import { Conversion } from "./Conversion.sol";
import { CreditLine } from "./CreditLine.sol";
import { IdentityRules } from "./IdentityRules.sol";
import { SavingsFacility } from "./SavingsFacility.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";
import { ISettlementTokenGuard } from "./interfaces/ISettlementTokenGuard.sol";

/// @title CardProgram
/// @notice An issuer's card program, and the holder its cardholders approve on the reservation core. It keeps the
///         card records (owner, status, expiry, limits, funding legs), merchant mandates and each owner's funding
///         order, and turns one card purchase into one to three holds placed in one call: cash first, then Tempo
///         Earn shares through a `SavingsFacility`, then a `CreditLine` draw on a lender. Captures run a waterfall
///         across the legs in the same order and refunds unwind them in reverse. Every purchase step emits one event
///         with the purchase reference, the card, each leg's amount and the amount in settlement units, numbered in
///         sequence, so obligations rebuild from events against the issuer's settled-through cursor.
///         Specified in docs/cards/design.md (Card programs).
/// @dev Amounts on a purchase are in units of `SETTLEMENT_TOKEN`. A leg in another token converts at the rate the
///      issuer recorded for it (`rateOf`, settlement units per token unit, scaled by 1e18); legs round up in token
///      units, so the owner never reserves less than the purchase. The program is the payee of cash and credit legs
///      and forwards what they capture to `SETTLEMENT_ACCOUNT` in the same call; the facility pays for savings legs.
///      Windows are calendar days and months at the UTC offset the owner granted. The owner's terms (a lifetime
///      limit, per-purchase, daily and monthly limits) bound all the owner's cards with this issuer, and each card
///      adds its own limits and an optional lifetime cap. A purchase counts from authorization; captures past its
///      holds and late charges count when they land; releases and refunds give their amount back. The core's holder
///      allowance is the owner's chain-level cap over everything this program holds.
contract CardProgram {
    using FixedPointMathLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint8 internal constant IN_USE_HOLDS = 1;
    uint8 internal constant IN_USE_UNSETTLED = 2;
    uint8 internal constant IN_USE_DEBT = 3;
    uint8 internal constant IN_USE_COLLATERAL = 5;
    uint8 internal constant IN_USE_HELD = 6;
    /// @dev The networks' longest dispute window, which bounds a dispute reserve.
    uint64 internal constant MAX_DISPUTE_RESERVE = 120 days;
    uint256 private constant RATE_ONE = 1e18;

    /// @notice Funding legs, as a card's allowed set and a purchase's placed set.
    uint8 public constant CASH = 1;
    uint8 public constant SAVINGS = 2;
    uint8 public constant CREDIT = 4;
    /// @notice A late charge's leg: a core charge on the owner's cash token, made after the purchase's holds ended.
    uint8 public constant CHARGED = 8;

    /// @notice Authorization flags: an offline approval the network already made, and a partial approval.
    uint8 public constant STAND_IN = 1;
    uint8 public constant PARTIAL = 2;

    enum Status {
        None,
        Active,
        Frozen,
        Closed
    }

    /// @notice An operator key may authorize, adjust, capture, release and charge purchases.
    uint8 public constant ROLE_AUTHORIZE = 1;
    /// @notice An operator key may refund, credit back, record reserve settlements and convert to settlement.
    uint8 public constant ROLE_SETTLE = 2;
    /// @notice An operator key may pay out, place, release and collect reserves, and redraw credit lines.
    uint8 public constant ROLE_TREASURY = 4;

    /// @dev An operator key's roles, its cap and what it has used, both in SETTLEMENT_TOKEN units.
    struct KeyCap {
        uint8 roles;
        uint120 cap;
        uint128 used;
    }

    /// @notice An owner's consent to reserves outside disputes, in one token's units.
    struct ReserveConsent {
        uint128 cap;
        uint128 collected;
        bytes32 purpose;
    }

    /// @notice Spending limits in settlement units. Zero allows nothing.

    struct Limits {
        uint80 perPurchase;
        uint80 daily;
        uint80 monthly;
    }

    struct Card {
        address owner;
        uint40 expiry;
        Status status;
        uint8 legs;
        Limits limits;
        /// @dev What the owner allows the issuer to raise the limits to.
        Limits ceiling;
        /// @dev The card's windows and lifetime total.
        CardLimits.Window window;
    }

    struct Purchase {
        bytes32 card;
        address owner;
        uint64 expiresAt;
        uint32 day;
        uint32 version;
        uint64 amount;
        uint8 legs;
        bool open;
        bool standIn;
        bool captured;
        uint32 month;
        /// @dev The owner's grant the purchase counts under.
        uint32 epoch;
        /// @dev Settlement units the purchase still counts as held.
        uint64 held;
    }

    /// @notice Purchase steps so far, the last one the issuer settled, net captured settlement units, and the net at
    ///         the last acknowledgement that reached the latest step (so `net - settledNet` never understates what
    ///         is unsettled).
    struct Ledger {
        uint64 seq;
        uint64 settledThrough;
        uint128 net;
        uint128 settledNet;
    }

    /// @dev What a purchase captured (charges included) and refunded, in the token it was booked in. Refunds never pass
    ///      what it captured: legs refund at today's rate, which can leave a converted leg more than the purchase.
    struct Booked {
        uint128 captured;
        uint128 refunded;
    }

    /// @dev One leg's hold as a purchase step reads it.
    struct Leg {
        address holdOwner;
        bytes32 id;
        address token;
        uint256 rate;
        uint128 held;
        uint128 refundable;
        bool settled;
        /// @dev Settlement-unit value of what the step can use from the leg.
        uint256 value;
    }

    /// @notice How long a setting that moves money waits between the issuer proposing it and applying it, once any
    ///         owner has granted the program.
    uint64 public constant SETTINGS_DELAY = 2 days;
    /// @notice The most a rate may move from the last nonzero rate in one change, in basis points.
    uint256 public constant MAX_RATE_STEP_BPS = 1000;

    address public immutable SETTLEMENT_TOKEN;
    address public immutable SETTLEMENT_ACCOUNT;

    mapping(bytes32 card => Card) internal _cards;
    mapping(address owner => mapping(address merchant => CardLimits.Mandate)) public mandates;
    mapping(address owner => CardLimits.Grant) public grants;
    mapping(address owner => CardLimits.Usage) public usageOf;
    /// @dev Each operator key's roles, cap and use, in SETTLEMENT_TOKEN units so a settlement token change rescales
    ///      the cap and use alike.
    mapping(address key => KeyCap) internal _keyCaps;
    /// @dev The issuer: it runs the program and holds every operator role without a cap.
    address internal _issuer;
    /// @notice The address the issuer offered its role to, which takes it with acceptIssuer.
    address public pendingIssuer;
    /// @notice How many owners have ever granted the program; while none has, settings apply at once.
    uint64 public grantedOwners;
    /// @notice When each proposed setting (keyed by the hash of its call) may be applied; zero when none is pending.
    mapping(bytes32 id => uint64 eta) public pendingSetting;
    mapping(address owner => address) public fundingOf;
    mapping(bytes32 purchaseRef => Purchase) internal _purchases;
    /// @notice Settlement units per unit of a token other than the settlement token, scaled by 1e18.
    mapping(address token => uint256) public rateOf;
    /// @notice The last nonzero rate recorded for each token, which a rate set after stopping it steps from.
    mapping(address token => uint256) public lastNonzeroRate;
    /// @notice Savings facilities and credit line contracts the issuer accepts as funding sources.
    mapping(address source => bool) public approvedSource;
    Ledger public ledger;
    /// @notice The registry of the keys that sign cardholder card actions; zero lets only the owner's own key sign.
    address public accountKeys;
    /// @notice The identity rules new authorizations must satisfy; zero checks none.
    address public identityRules;
    /// @notice The venue legs in other stablecoins convert through at capture; zero converts none.
    address public conversion;
    /// @dev The token purchases settle in now; zero for SETTLEMENT_TOKEN.
    address internal _settlementToken;
    /// @dev Units of SETTLEMENT_TOKEN one unit of a later settlement token was worth when the program moved to it,
    ///      scaled by 1e18 (zero means one). Limits and spend count in SETTLEMENT_TOKEN units, so they keep their value
    ///      across a change, and each purchase counts at the scale of the token it was authorized in.
    mapping(address token => uint256) internal _scales;
    /// @dev Purchases still open, which keep the settlement token from changing.
    uint256 internal _openPurchases;
    /// @notice Contracts a settlement token change asks first.
    address[] public tokenGuards;
    /// @dev The token a purchase was authorized in, where that was not SETTLEMENT_TOKEN.
    mapping(bytes32 purchaseRef => address) internal _purchaseTokens;
    /// @notice The increment an owner's holds and increases round up to, in settlement units; zero holds exact amounts.
    mapping(address owner => uint64) public holdRounding;

    bool private transient _locked;
    /// @notice The account lifecycle the program reads at authorization and reports activity to; zero for none.
    address public lifecycle;
    /// @notice The card that replaced a card. An open purchase follows its card's replacements.
    mapping(bytes32 card => bytes32) public replacedBy;
    /// @notice Whether an owner lets this program place dispute reserves on its balance, past the card-hold limit.
    mapping(address owner => bool) public disputeReserves;
    /// @notice What an owner lets this program reserve and collect of a token outside disputes: a lifetime cap on
    ///         collections, what it has collected and the purpose each reserve must name. A zero cap allows nothing.
    mapping(address owner => mapping(address token => ReserveConsent)) public reserveConsent;
    /// @dev Reserves placed under an owner's reserveConsent, whose collections count against it.
    mapping(bytes32 id => bool) internal _consented;
    /// @dev Reserves this program may still hold, so a settlement token change waits for them.
    bytes32[] internal _reserves;
    mapping(bytes32 purchaseRef => Booked) internal _booked;

    event CardIssued(bytes32 indexed card, address indexed owner, uint40 expiry, Limits limits, uint8 legs);
    event CardExpirySet(bytes32 indexed card, uint40 expiry);
    event CardReplaced(bytes32 indexed oldCard, bytes32 indexed newCard, uint40 expiry);
    event CardStatusSet(bytes32 indexed card, Status status);
    event LimitsSet(bytes32 indexed card, Limits limits, Limits ceiling);
    event MandateSet(address indexed owner, address indexed merchant, bool revoked, uint96 monthlyLimit);
    event RateSet(address indexed token, uint256 rate);
    event ConversionSet(address conversion);
    event HoldRoundingSet(address indexed owner, uint64 increment);
    event DisputeReservesSet(address indexed owner, bool allowed);
    event ReservesAllowed(address indexed owner, address indexed token, uint128 cap, bytes32 purpose);
    event ReservePlaced(bytes32 indexed id, address indexed owner, address token, uint128 amount, uint64 expiresAt);
    event DisputeReserved(
        bytes32 indexed purchaseRef,
        address indexed merchant,
        address token,
        uint128[2] tokens,
        uint128[2] covers,
        uint64 expiresAt
    );
    event ReserveCollected(bytes32 indexed id, address indexed to, uint128 amount);
    /// @notice New purchases settle in token; limits sized in previous rescale at step, previous units per token unit
    ///         scaled by 1e18.
    event SettlementTokenSet(address token, address previous, uint256 step);
    event SourceSet(address indexed source, bool approved);
    event CompanionsSet(address accountKeys, address identityRules);
    event LifecycleSet(address lifecycle);
    event UsageCarried(address indexed owner);
    event PurchaseAuthorized(
        bytes32 indexed purchaseRef,
        bytes32 indexed card,
        address indexed merchant,
        uint256 amount,
        uint256 cash,
        uint256 shares,
        uint256 credit,
        bool standIn,
        uint64 expiresAt,
        uint64 seq
    );
    event PurchaseCaptured(
        bytes32 indexed purchaseRef,
        bytes32 indexed card,
        uint256 amount,
        uint256 cash,
        uint256 shares,
        uint256 credit,
        uint256 absorbed,
        bool isFinal,
        uint64 seq,
        uint128 net
    );
    event PurchaseReleased(
        bytes32 indexed purchaseRef,
        bytes32 indexed card,
        uint256 cash,
        uint256 shares,
        uint256 credit,
        bool expired,
        uint64 seq
    );
    event PurchaseRefunded(
        bytes32 indexed purchaseRef,
        bytes32 indexed card,
        uint256 amount,
        uint256 cash,
        uint256 shares,
        uint256 credit,
        uint64 seq,
        uint128 net
    );
    /// @notice Of a purchase's refund, `amount` the merchant's reserves already paid the issuer, which the network
    ///         therefore does not return through settlement.
    event ReserveSettled(bytes32 indexed purchaseRef, uint256 amount, uint64 seq, uint128 net);
    event SettlementAcknowledged(uint64 throughSeq, uint64 previous);
    event Granted(address indexed owner, CardLimits.Terms terms, uint32 epoch);
    event Revoked(address indexed owner);
    event OperatorSet(address indexed key, uint8 roles, uint256 cap);
    event IssuerOffered(address indexed issuer, address indexed next);
    event IssuerTransferred(address indexed previous, address indexed next);
    event SettingProposed(bytes32 indexed id, bytes data, uint64 eta);
    event SettingCancelled(bytes32 indexed id);
    event CardCapSet(bytes32 indexed card, uint64 cap);
    event PurchaseAdjusted(bytes32 indexed purchaseRef, bytes32 indexed card, uint256 amount, uint256 cash, uint64 seq);
    event PurchaseCharged(
        bytes32 indexed purchaseRef,
        bytes32 indexed card,
        address indexed merchant,
        uint256 amount,
        uint256 cash,
        uint256 absorbed,
        uint64 seq,
        uint128 net
    );

    /// @notice The owner's account is dormant: it declines new holds until the owner reactivates it.
    error AccountInactive();
    error CaptureExceedsHolds(uint256 excess);
    /// @notice The owner's account is closed or an estate, which closes or freezes every card on it.
    error CardsClosed();
    error CardExists();
    error CardExpired();
    error CardNotActive();
    error InsufficientFunds(uint256 shortfall);
    error InvalidAmount();
    error KeyCapExceeded(uint256 room);
    error InvalidCard();
    error InvalidCursor();
    /// @notice The settlement token still sizes something: 1 open holds, 2 unsettled captures, 3 debt owed to the
    ///         issuer, 4 open disputes, 5 posted collateral, 6 a held or liened balance, 7 open credit lines, 8 debt the
    ///         settlement account owes the program that it cannot owe in the new token.
    error SettlementTokenInUse(uint8 reason);
    error LimitAboveCeiling();
    error LimitExceeded(uint8 which);
    error MerchantLimitExceeded();
    error MerchantRevoked();
    error NoTerms();
    error PurchaseOpen();
    error NotCardOwner();
    error NotIssuer();
    error PurchaseExists();
    error PurchaseExpired();
    error PurchaseNotExpired();
    error PurchaseNotOpen();
    error Reentrancy();
    error RateStep();
    error RefundExceedsCapture(uint256 excess);
    error SettingPending(uint64 eta);
    error ReserveNotAllowed();
    error ReserveTooLong();
    error SourceNotApproved(address source);
    error TokenNotAccepted(address token);
    error UnknownPurchase();
    error ZeroAddress();

    modifier onlyIssuer() {
        if (msg.sender != _issuer) revert NotIssuer();
        _;
    }

    modifier onlyRole(uint8 role) {
        _onlyRole(role);
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address issuer, address settlementToken_, address settlementAccount) {
        if (issuer == address(0) || settlementToken_ == address(0) || settlementAccount == address(0)) {
            revert ZeroAddress();
        }
        _issuer = issuer;
        SETTLEMENT_TOKEN = settlementToken_;
        SETTLEMENT_ACCOUNT = settlementAccount;
    }

    // Every entry point that changes state holds the transient lock for its whole call, and the core, facilities
    // and credit lines it calls are fixed or issuer-approved.
    // forge-lint: disable-start(reentrancy-no-eth)

    // Issuer: cards and program settings.

    /// @notice Issues `card` to `owner`. The owner's ceiling starts at the issued limits.
    function issueCard(bytes32 card, address owner, uint40 expiry, Limits calldata limits, uint8 legs)
        external
        onlyIssuer
    {
        CardAdjust.issueCard(_cards[card], card, owner, expiry, _baseLimits(limits), legs);
    }

    /// @notice Replaces `oldCard` with `newCard` (a lost card or a new expiry): same owner, limits, legs and
    ///         windows; the old card closes.
    function replaceCard(bytes32 oldCard, bytes32 newCard, uint40 expiry) external onlyIssuer {
        CardAdjust.replaceCard(_cards[oldCard], _cards[newCard], oldCard, newCard, expiry);
        replacedBy[oldCard] = newCard;
    }

    /// @notice Sets `card`'s limits, each at most what its owner allows.
    function raiseLimits(bytes32 card, Limits calldata given) external onlyIssuer {
        Card storage c = _cards[card];
        if (c.status == Status.None || c.status == Status.Closed) revert CardNotActive();
        CardAdjust.raiseLimits(c, card, _baseLimits(given));
    }

    /// @notice Gives `key` the `roles` (a mask of the ROLE_ constants) while the cardholder money it moves stays within
    ///         `cap` settlement units over its life, restarting its use; zero roles remove the key. A settlement token
    ///         change rescales the cap and use at that day's rate: the cap rounds down and its use up.
    function setOperator(address key, uint8 roles, uint256 cap) external onlyIssuer {
        uint256 base;
        if (roles != 0) {
            uint256 scale = _scaleOf(settlementToken());
            base = scale == RATE_ONE ? cap : cap.mulDiv(scale, RATE_ONE);
            if (roles > 7 || base == 0 || base > type(uint120).max) revert InvalidAmount();
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _keyCaps[key] = KeyCap(roles, uint120(base), 0);
        emit OperatorSet(key, roles, cap);
    }

    /// @notice The roles `key` holds.
    function rolesOf(address key) external view returns (uint8) {
        return _keyCaps[key].roles;
    }

    /// @notice Whether `key` holds any role.
    function operators(address key) external view returns (bool) {
        return _keyCaps[key].roles != 0;
    }

    /// @notice `key`'s cap and what it has used in the current settlement token, zero cap meaning none.
    function operatorCap(address key) external view returns (uint256 cap, uint256 used) {
        KeyCap storage k = _keyCaps[key];
        if (k.cap == 0) return (0, 0);
        uint256 scale = _scaleOf(settlementToken());
        if (scale == RATE_ONE) return (k.cap, k.used);
        return (uint256(k.cap).mulDiv(RATE_ONE, scale), uint256(k.used).mulDivUp(RATE_ONE, scale));
    }

    /// @notice Caps what `card` commits over its life (open holds plus captures less refunds). Zero removes the cap.
    function setCardCap(bytes32 card, uint64 cap) external onlyIssuer {
        Card storage c = _cards[card];
        if (c.status == Status.None) revert InvalidCard();
        // forge-lint: disable-next-line(unsafe-typecast)
        cap = uint64(_base(cap, type(uint64).max));
        c.window.cap = cap;
        emit CardCapSet(card, cap);
    }

    /// @notice Carries what an owner's spend already counted on another instance of this program (the same issuer's
    ///         program on another chain the owner moved from) into its usage, cards' windows and merchant mandates
    ///         here, so the same limits keep counting it. Counts only rise; the cards must be the owner's.
    function carryUsage(
        address owner,
        CardLimits.Usage calldata usage,
        bytes32[] calldata cards,
        CardLimits.Window[] calldata windows,
        address[] calldata merchants,
        CardLimits.Mandate[] calldata spent
    ) external onlyIssuer {
        CardAdjust.carryUsage(_cards, mandates[owner], usageOf[owner], owner, usage, cards, windows, merchants, spent);
        emit UsageCarried(owner);
    }

    /// @notice Moves `card`'s expiry, such as a short-lived virtual card's; past it the card authorizes nothing.
    ///         An unissued card needs no check: issueCard sets its own expiry.
    function setExpiry(bytes32 card, uint40 expiry) external onlyIssuer {
        _cards[card].expiry = expiry;
        emit CardExpirySet(card, expiry);
    }

    /// @notice Freezes, unfreezes or closes `card` for the issuer (a fraud stop, a lost card). A closed card stays closed.
    function setStatus(bytes32 card, Status status) external onlyIssuer {
        Card storage c = _cards[card];
        if (c.status == Status.None || c.status == Status.Closed || status == Status.None) revert CardNotActive();
        c.status = status;
        emit CardStatusSet(card, status);
    }

    /// @notice Sets the account key registry cardholder card actions check and the identity rules authorizations check.
    // Zero is meaningful for both: no registry means owners sign as themselves, no rules means no identity check.
    // forge-lint: disable-next-line(missing-zero-check)
    function setCompanions(address accountKeys_, address identityRules_) external onlyIssuer {
        if (!_settle(false)) return;
        accountKeys = accountKeys_;
        identityRules = identityRules_;
        emit CompanionsSet(accountKeys_, identityRules_);
    }

    /// @notice Follows the account lifecycle at the given address; zero stops reading one.
    // Zero is how the issuer stops following a lifecycle.
    // forge-lint: disable-next-line(missing-zero-check)
    function setLifecycle(address lifecycle_) external onlyIssuer {
        if (!_settle(false)) return;
        lifecycle = lifecycle_;
        emit LifecycleSet(lifecycle_);
    }

    /// @notice Records the rate for `token`: settlement units per token unit, scaled by 1e18. Zero stops it at once; a
    ///         nonzero rate moves at most MAX_RATE_STEP_BPS from the last nonzero one, even after a stop, and waits
    ///         SETTINGS_DELAY.
    function setRate(address token, uint256 rate) external onlyIssuer {
        if (token == settlementToken()) revert TokenNotAccepted(token);
        uint256 last = lastNonzeroRate[token];
        if (rate != 0 && last != 0) {
            uint256 step = last.mulDiv(MAX_RATE_STEP_BPS, 10_000);
            if (rate > last + step || rate < last - step) revert RateStep();
        }
        if (!_settle(rate == 0)) return;
        rateOf[token] = rate;
        if (rate != 0) lastNonzeroRate[token] = rate;
        emit RateSet(token, rate);
    }

    /// @notice Contracts sizing money in the settlement token that a change must wait for (an issuer desk, credit lines).
    ///         Appending guards to the current list applies at once, since a guard can only hold a token change back.
    function setTokenGuards(address[] calldata guards) external onlyIssuer {
        address[] storage current = tokenGuards;
        uint256 n = current.length;
        bool appends = guards.length >= n;
        for (uint256 i; appends && i < n; ++i) {
            appends = guards[i] == current[i];
        }
        if (!_settle(appends)) return;
        tokenGuards = guards;
    }

    /// @notice Settles new purchases in token from now on. Refused while anything is still sized in the old token (an
    ///         open or unsettled purchase, debt owed, posted collateral, a held or liened settlement balance, or what a
    ///         token guard reports), so every purchase settles in the token it was authorized in.
    function setSettlementToken(address token) external onlyIssuer {
        Ledger storage l = ledger;
        if (_openPurchases != 0) revert SettlementTokenInUse(IN_USE_HOLDS);
        if (l.settledThrough != l.seq || l.net != l.settledNet) revert SettlementTokenInUse(IN_USE_UNSETTLED);
        (, uint256 debt, uint256 posted,) = CardFunding.exposure(0);
        if (debt != 0) revert SettlementTokenInUse(IN_USE_DEBT);
        if (posted != 0) revert SettlementTokenInUse(IN_USE_COLLATERAL);
        _checkReserves();
        address current = settlementToken();
        CardConvert.checkUnused(tokenGuards, SETTLEMENT_ACCOUNT, current);
        if (token == address(0) || token == current || rateOf[token] != 0) revert TokenNotAccepted(token);
        // The new token's scale follows from the old one's at today's reference rate, without conversion cost.
        uint256 step = Conversion(conversion).mid(token, current);
        // Every check above runs again when the change applies.
        if (!_settle(false)) return;
        CardConvert.carryIssuerDebt(current, token);
        _scales[token] = _scaleOf(current).mulDiv(step, RATE_ONE);
        _settlementToken = token;
        emit SettlementTokenSet(token, current, step);
    }

    /// @notice Adds `amount` of `token` from the caller to the program's funds for advancing payouts.
    function fundIssuerDebt(address token, uint256 amount) external nonReentrant {
        CardConvert.fundIssuerDebt(token, amount);
    }

    /// @notice Pays `amount` of the program's own `token` funds to the settlement account, within what it retains
    ///         less what they stand behind (`committedIssuerFunds`).
    function withdrawIssuerFunds(address token, uint256 amount) external nonReentrant onlyIssuer {
        CardConvert.withdrawIssuerFunds(token, amount, committedIssuerFunds(token));
    }

    /// @notice What the program's own `token` funds stand behind and stay for: in the settlement token, open stand-in
    ///         approvals and cardholders' capped debt to the program while captures are unsettled; nothing in another.
    function committedIssuerFunds(address token) public view returns (uint256) {
        if (token != settlementToken()) return 0;
        Ledger memory l = ledger;
        return CardFunding.committed(l.net > l.settledNet ? l.net - l.settledNet : 0);
    }

    /// @notice What the program holds of `token` for advancing payouts.
    function issuerFunds(address token) external view returns (uint256) {
        return CardConvert.retained(token);
    }

    /// @notice Pays `amount` from the settlement account to `to` with `memo`, the program advancing what the account
    ///         lacks as debt the account owes it. The settlement account, the issuer or a treasury key calls it.
    function payOut(address to, uint256 amount, bytes32 memo) external nonReentrant returns (uint256 advanced) {
        if (msg.sender != SETTLEMENT_ACCOUNT) {
            _onlyRole(ROLE_TREASURY);
            _useKey(_base(amount, type(uint256).max));
        }
        return CardConvert.payOut(to, amount, memo);
    }

    /// @notice Repays what the owner owes in the settlement token from its cash in another token, through the venue.
    function repayConverted(address owner) external nonReentrant returns (uint256) {
        return CardConvert.repay(owner);
    }

    /// @notice Sets the venue legs in other stablecoins convert through at capture (for tokens without an issuer rate).
    // Zero turns conversion off: legs then convert only at an issuer rate.
    // forge-lint: disable-next-item(missing-zero-check)
    function setConversion(address conversion_) external onlyIssuer {
        if (!_settle(false)) return;
        conversion = conversion_;
        emit ConversionSet(conversion_);
    }

    /// @notice Accepts or stops a savings facility or credit line contract as a funding source.
    function setSource(address source, bool approved) external onlyIssuer {
        if (!_settle(!approved)) return;
        approvedSource[source] = approved;
        emit SourceSet(source, approved);
    }

    /// @notice Limits the kinds of source (cash 1, savings 2, credit 4) purchases may draw on; zero allows every kind.
    function setAssets(uint8 kinds) external onlyIssuer {
        CardFunding.setAssets(kinds);
    }

    /// @notice Sets the contract that values the sponsor's collateral; purchases then stay within it. Zero removes it.
    function setCollateral(address collateral) external onlyIssuer {
        if (!_settle(false)) return;
        CardFunding.setCollateral(collateral);
    }

    /// @notice Drops the pending setting `id`.
    function cancelSetting(bytes32 id) external onlyIssuer {
        delete pendingSetting[id];
        emit SettingCancelled(id);
    }

    /// @notice Offers the issuer role to `next`, which takes it with acceptIssuer; zero withdraws the offer.
    // Zero is how the issuer withdraws an offer.
    // forge-lint: disable-next-line(missing-zero-check)
    function transferIssuer(address next) external onlyIssuer {
        // IssuerOffered reports the change.
        // forge-lint: disable-next-line(missing-events-access-control)
        pendingIssuer = next;
        emit IssuerOffered(msg.sender, next);
    }

    /// @notice Takes the issuer role offered to the caller; the previous issuer loses it.
    function acceptIssuer() external {
        if (msg.sender != pendingIssuer) revert NotIssuer();
        emit IssuerTransferred(_issuer, msg.sender);
        _issuer = msg.sender;
        // IssuerTransferred reports the change.
        // forge-lint: disable-next-line(missing-events-access-control)
        delete pendingIssuer;
    }

    /// @notice The issuer, which runs the program.
    function ISSUER() external view returns (address) {
        return _issuer;
    }

    /// @notice Moves the settled-through cursor to purchase step `throughSeq`.
    function acknowledgeSettlement(uint64 throughSeq) external onlyIssuer {
        Ledger storage l = ledger;
        uint64 previous = l.settledThrough;
        if (throughSeq <= previous || throughSeq > l.seq) revert InvalidCursor();
        l.settledThrough = throughSeq;
        if (throughSeq == l.seq) l.settledNet = l.net;
        emit SettlementAcknowledged(throughSeq, previous);
    }

    // Cardholder.

    function freeze(bytes32 card) external {
        Card storage c = _ownedCard(card);
        if (c.status != Status.Active) revert CardNotActive();
        c.status = Status.Frozen;
        emit CardStatusSet(card, Status.Frozen);
    }

    function unfreeze(bytes32 card) external {
        Card storage c = _ownedCard(card);
        if (c.status != Status.Frozen) revert CardNotActive();
        c.status = Status.Active;
        emit CardStatusSet(card, Status.Active);
    }

    function close(bytes32 card) external {
        Card storage c = _ownedCard(card);
        if (c.status == Status.Closed) revert CardNotActive();
        c.status = Status.Closed;
        emit CardStatusSet(card, Status.Closed);
    }

    /// @notice Lowers `card`'s limits; the ceiling drops with them, so the issuer cannot raise them back.
    function lowerLimits(bytes32 card, Limits calldata given) external {
        CardAdjust.lowerLimits(_ownedCard(card), card, _baseLimits(given));
    }

    /// @notice Sets how far the issuer may raise `card`'s limits; limits above it come down to it.
    function allowLimits(bytes32 card, Limits calldata given) external {
        CardAdjust.allowLimits(_ownedCard(card), card, _baseLimits(given));
    }

    /// @notice Revokes or restores `merchant` for all the caller's cards, with an optional monthly limit.
    function setMandate(address merchant, bool revoked, uint96 monthlyLimit) external {
        CardLimits.Mandate storage m = mandates[msg.sender][merchant];
        m.revoked = revoked;
        // forge-lint: disable-next-line(unsafe-typecast)
        monthlyLimit = uint96(_base(monthlyLimit, type(uint96).max));
        m.monthlyLimit = monthlyLimit;
        emit MandateSet(msg.sender, merchant, revoked, monthlyLimit);
    }

    /// @notice Sets the caller's funding order. Zero skips a leg.
    function setFunding(address cashToken, CardFunding.Source[] calldata order) external {
        fundingOf[msg.sender] = cashToken;
        CardFunding.setOrder(msg.sender, cashToken, order);
    }

    /// @notice Rounds the caller's holds and increases up to `increment`, so hold amounts don't reveal what was bought.
    ///         Captures stay exact, and a hold whose rounded amount isn't free holds the exact amount instead.
    function setHoldRounding(uint64 increment) external {
        holdRounding[msg.sender] = increment;
        emit HoldRoundingSet(msg.sender, increment);
    }

    /// @notice Grants this program the caller's terms for all their cards, and starts their usage afresh.
    function grant(CardLimits.Terms calldata given) external {
        CardLimits.Grant storage g = grants[msg.sender];
        CardLimits.Terms memory terms = given;
        uint256 most = type(uint64).max;
        // forge-lint: disable-start(unsafe-typecast)
        (terms.limit, terms.perPurchase, terms.daily, terms.monthly) =
        (
            uint64(_base(terms.limit, most)),
            uint64(_base(terms.perPurchase, most)),
            uint64(_base(terms.daily, most)),
            uint64(_base(terms.monthly, most))
        );
        // forge-lint: disable-end(unsafe-typecast)
        g.terms = terms;
        g.active = true;
        uint32 epoch = ++g.epoch;
        if (epoch == 1) ++grantedOwners;
        delete usageOf[msg.sender];
        emit Granted(msg.sender, terms, epoch);
    }

    /// @notice Stops new purchases on all the caller's cards. Open purchases still capture, release and refund.
    function revoke() external {
        grants[msg.sender].active = false;
        emit Revoked(msg.sender);
    }

    // Purchases.

    /// @notice Authorizes a purchase of `amount` settlement units on `card` at `merchant`: checks the card, the
    ///         owner's grant, limits and the merchant mandate, then places the owner's legs in funding order in this
    ///         one call. `PARTIAL` approves what the legs can fund when that is less. `STAND_IN` records an offline
    ///         approval as one cash stand-in hold, past the card's freeze, limits and mandates, which the network
    ///         already decided; it still counts toward them.
    /// @return approved The settlement units the purchase holds.
    function authorize(
        bytes32 card,
        bytes32 purchaseRef,
        uint128 amount,
        address merchant,
        uint64 expiresAt,
        uint8 flags
    ) external nonReentrant onlyRole(ROLE_AUTHORIZE) returns (uint256 approved) {
        if (amount == 0 || amount > type(uint64).max) revert InvalidAmount();
        Purchase storage p = _purchases[purchaseRef];
        if (p.owner != address(0)) revert PurchaseExists();
        Card storage c = _cards[card];
        address owner = c.owner;
        bool standIn = flags & STAND_IN != 0;
        if (c.status == Status.None) revert InvalidCard();
        CardLimits.Grant storage g = grants[owner];
        // A stand-in approval is decided when it lands: a card frozen or closed meanwhile declines it.
        if (c.status != Status.Active) revert CardNotActive();
        _admit(owner);
        if (!standIn) {
            // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
            // forge-lint: disable-next-line(block-timestamp)
            if (c.expiry <= block.timestamp) revert CardExpired();
            if (!g.active) revert NoTerms();
            // Reverts IdentityRequired unless the owner holds a live attestation the program's policy accepts.
            address rules = identityRules;
            if (rules != address(0)) IdentityRules(rules).admit(owner);
        }

        uint256[3] memory legAmounts;
        // A partial or stand-in approval holds what the network asked for, unrounded.
        uint256 want = flags & (STAND_IN | PARTIAL) != 0 ? amount : _rounded(owner, amount);
        if (want > type(uint64).max) revert InvalidAmount();
        (approved, legAmounts) =
            CardFunding.place(p, purchaseRef, owner, want, c.legs, expiresAt, want == amount ? flags : flags | PARTIAL);
        if (approved < want && want != amount) {
            // The rounded hold isn't free: hold the exact amount, or what a partial approval covers.
            if (approved < amount) {
                if (flags & PARTIAL == 0) revert InsufficientFunds(amount - approved);
            } else {
                p.owner = owner;
                legAmounts[0] = CardFunding.resize(p, purchaseRef, approved, amount);
                approved = amount;
            }
        }
        uint256 counted = _base(approved, type(uint256).max);
        _useKey(counted);
        if (!standIn) CardLimits.useMandate(mandates[owner][merchant], g.terms.utcOffset, counted);
        (p.day, p.month) = _spend(c, owner, counted, counted, !standIn);

        p.card = card;
        p.owner = owner;
        p.expiresAt = expiresAt;
        p.epoch = g.epoch;
        // forge-lint: disable-next-line(unsafe-typecast)
        p.amount = uint64(approved);
        // forge-lint: disable-next-line(unsafe-typecast)
        p.held = uint64(approved);
        p.open = true;
        ++_openPurchases;
        // A purchase settles in the token it was authorized in; only a moved settlement token costs the extra slot.
        address token = settlementToken();
        if (token != SETTLEMENT_TOKEN) _purchaseTokens[purchaseRef] = token;
        p.standIn = standIn;
        uint64 seq = ++ledger.seq;
        emit PurchaseAuthorized(
            purchaseRef, card, merchant, approved, legAmounts[0], legAmounts[1], legAmounts[2], standIn, expiresAt, seq
        );
    }

    /// @notice Moves an open purchase to `amount` settlement units (an incremental authorization or a partial
    ///         reversal). An increase checks the card, grant and limits on the new total and places the difference
    ///         on the owner's funding order; a decrease frees cash first, then the other legs.
    function adjust(bytes32 purchaseRef, uint128 amount) external nonReentrant onlyRole(ROLE_AUTHORIZE) {
        Purchase storage p = _purchases[purchaseRef];
        address owner = p.owner;
        uint256 previous = p.amount;
        if (!p.standIn) {
            uint256 rounded = _rounded(owner, amount);
            // A decrease never grows the hold to round it.
            if (amount < previous && rounded > previous) rounded = amount;
            // A change within the rounded hold changes nothing on chain, so it doesn't reveal the new amount.
            // forge-lint: disable-next-line(block-timestamp)
            if (rounded == previous && p.open && block.timestamp < p.expiresAt) return;
            if (rounded > type(uint64).max) revert InvalidAmount();
            // forge-lint: disable-next-line(unsafe-typecast)
            amount = uint128(rounded);
        }
        Card storage c = _follow(p);
        if (amount > previous) {
            _admit(owner);
            _useKey(_counted(purchaseRef, amount - previous));
        }
        CardAdjust.adjust(p, c, grants[owner], usageOf[owner], amount);
        uint256 cash = CardFunding.resize(p, purchaseRef, previous, amount);
        uint64 seq = ++ledger.seq;
        emit PurchaseAdjusted(purchaseRef, p.card, amount, cash, seq);
    }

    /// @notice Captures `amount` settlement units of a purchase across its legs in funding order (cash, savings,
    ///         credit), and pays the settlement account in the same call. An amount above what the legs hold (a tip)
    ///         is captured on the cash leg within the owner's tolerance on the core. `isFinal` releases the rest.
    function capture(bytes32 purchaseRef, uint128 amount, bool isFinal) external nonReentrant onlyRole(ROLE_AUTHORIZE) {
        Purchase storage p = _purchases[purchaseRef];
        if (!p.open) revert PurchaseNotOpen();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.expiresAt) revert PurchaseExpired();
        if (amount == 0 && !isFinal) revert InvalidAmount();
        Card storage c = _follow(p);
        (uint256[3] memory tokens,, uint256 absorbed) =
            CardFunding.capture(p, purchaseRef, amount, isFinal, c.legs, fundingOf[p.owner]);

        // The held part of the capture already counts; what it takes past the holds counts now, and a final capture
        // gives back what it leaves held.
        uint256 counted = p.held;
        uint256 fromHeld = amount < counted ? amount : counted;
        uint256 freed = isFinal ? counted : fromHeld;
        // forge-lint: disable-next-line(unsafe-typecast)
        p.held = uint64(counted - freed);
        if (amount > fromHeld) _spend(c, p.owner, 0, _counted(purchaseRef, amount - fromHeld), false);
        if (freed > fromHeld) {
            _giveBack(c, p.owner, p.epoch, p.day, p.month, _counted(purchaseRef, freed - fromHeld));
        }

        if (amount != 0) {
            p.captured = true;
            _booked[purchaseRef].captured += amount;
        }
        Ledger storage ledger_ = ledger;
        if (isFinal) {
            p.open = false;
            --_openPurchases;
        }
        uint64 seq = ++ledger_.seq;
        uint128 net = ledger_.net + amount;
        ledger_.net = net;
        emit PurchaseCaptured(purchaseRef, p.card, amount, tokens[0], tokens[1], tokens[2], absorbed, isFinal, seq, net);
    }

    /// @notice Charges `amount` settlement units for a purchase presented without a live hold (a late presentment
    ///         or a force post), as one core charge on the owner's cash token: available balance first, then debt
    ///         within the cap the owner set for this program. The issuer absorbs what neither covers; the event
    ///         reports it. An expired open purchase is released first. The charge must fit the owner's terms, the
    ///         card's limits and the merchant's mandate, as an authorization must.
    function charge(bytes32 card, bytes32 purchaseRef, uint128 amount, address merchant)
        external
        nonReentrant
        onlyRole(ROLE_AUTHORIZE)
    {
        if (amount == 0 || amount > type(uint64).max) revert InvalidAmount();
        Purchase storage p = _purchases[purchaseRef];
        if (p.owner == address(0)) {
            Card storage c = _cards[card];
            if (c.status == Status.None) revert InvalidCard();
            p.card = card;
            p.owner = c.owner;
            // A force post books in today's settlement token, as an authorization does.
            address today = settlementToken();
            if (today != SETTLEMENT_TOKEN) _purchaseTokens[purchaseRef] = today;
        } else {
            if (p.legs & (CHARGED | 16) != 0) revert PurchaseExists();
            if (p.open) {
                // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
                // forge-lint: disable-next-line(block-timestamp)
                if (block.timestamp < p.expiresAt) revert PurchaseOpen();
                _end(purchaseRef, true);
            }
        }
        address owner = p.owner;
        uint256 counted = _counted(purchaseRef, amount);
        _useKey(counted);
        CardLimits.useMandate(mandates[owner][merchant], grants[owner].terms.utcOffset, counted);
        // A late charge is owed like capture debt: in the settlement token where the owner's cash converts into it.
        address token = CardConvert.debtToken(fundingOf[owner]);
        Card storage card_ = _follow(p);
        _noteActivity(owner, false);
        (uint256 tokens, uint256 absorbed) = CardAdjust.charge(
            CORE,
            p,
            card_,
            grants[owner],
            usageOf[owner],
            token,
            _rate(token),
            _legId(purchaseRef, CHARGED),
            amount,
            counted,
            purchaseRef
        );
        _forward(token);
        if (absorbed != 0) CardFunding.noteAbsorbed(purchaseRef, absorbed);
        // Debt the charge left counts in the program's exposure, like a capture's.
        (address creditor, uint128 owed) = CORE.debtOf(owner, token);
        if (creditor == address(this) && owed != 0) CardFunding.noteDebtor(owner);
        _booked[purchaseRef].captured += amount;

        Ledger storage ledger_ = ledger;
        uint64 seq = ++ledger_.seq;
        uint128 net = ledger_.net + amount;
        ledger_.net = net;
        emit PurchaseCharged(purchaseRef, p.card, merchant, amount, tokens, absorbed, seq, net);
    }

    /// @notice Releases every open leg of a purchase and gives back what it still held.
    function release(bytes32 purchaseRef) external nonReentrant onlyRole(ROLE_AUTHORIZE) {
        _end(purchaseRef, false);
    }

    /// @notice Releases an expired purchase's legs. Anyone may call it once the purchase expired.
    function expire(bytes32 purchaseRef) external nonReentrant {
        _end(purchaseRef, true);
    }

    /// @notice Refunds `amount` settlement units of what a purchase captured or charged, in reverse funding order
    ///         (a late charge, credit, savings, cash), and gives the amount back to the owner's limits. The caller
    ///         funds it: the program pulls each leg's token from the caller (the savings leg's base asset, which the
    ///         facility deposits for shares) and refunds the leg as its payee.
    function refund(bytes32 purchaseRef, uint128 amount) external nonReentrant onlyRole(ROLE_SETTLE) {
        Purchase storage p = _purchases[purchaseRef];
        if (p.owner == address(0)) revert UnknownPurchase();
        if (amount == 0) revert InvalidAmount();
        Booked storage b = _booked[purchaseRef];
        uint256 left = b.captured > b.refunded ? b.captured - b.refunded : 0;
        if (amount > left) revert RefundExceedsCapture(amount - left);
        b.refunded += amount;
        _useKey(_counted(purchaseRef, amount));
        // A purchase booked in an earlier settlement token refunds in its units: rates read in that token meanwhile.
        address booked = _purchaseTokens[purchaseRef];
        if (booked == address(0)) booked = SETTLEMENT_TOKEN;
        if (booked == settlementToken()) booked = address(0);
        bytes32 slot = CardConvert.BOOKED_SLOT;
        assembly {
            tstore(slot, booked)
        }
        uint256[3] memory tokens = CardFunding.refund(p, purchaseRef, amount, fundingOf[p.owner]);
        assembly {
            tstore(slot, 0)
        }
        _giveBackNow(_follow(p), p.owner, p.epoch, _counted(purchaseRef, amount));

        Ledger storage ledger_ = ledger;
        uint64 seq = ++ledger_.seq;
        uint128 net = ledger_.net > amount ? ledger_.net - amount : 0;
        ledger_.net = net;
        emit PurchaseRefunded(purchaseRef, p.card, amount, tokens[0], tokens[1], tokens[2], seq, net);
    }

    /// @notice Converts `amount` of an earlier settlement token from the caller into today's at the reference rate, paid
    ///         to `to`, such as split shares or rewards a refund takes back.
    function convertToSettlement(address token, uint256 amount, address to)
        external
        nonReentrant
        onlyRole(ROLE_SETTLE)
        returns (uint256)
    {
        return CardConvert.convertToSettlement(msg.sender, token, amount, to);
    }

    /// @notice Records that merchant reserves paid the issuer `amount` of a purchase's refund, which settlement then
    ///         leaves out of what the network returns. Moves no money.
    function reserveSettled(bytes32 purchaseRef, uint128 amount) external nonReentrant onlyRole(ROLE_SETTLE) {
        if (_purchases[purchaseRef].owner == address(0)) revert UnknownPurchase();
        if (amount == 0) revert InvalidAmount();
        Ledger storage ledger_ = ledger;
        uint64 seq = ++ledger_.seq;
        uint128 net = ledger_.net + amount;
        ledger_.net = net;
        emit ReserveSettled(purchaseRef, amount, seq, net);
    }

    /// @notice Records `usage` of a purchase as given back to its card's limits and `net` as returned to the network,
    ///         moving no money: dispute credit the cardholder already holds, which a win or a later refund settles.
    function creditBack(bytes32 purchaseRef, uint128 usage, uint128 net) external nonReentrant onlyRole(ROLE_SETTLE) {
        Purchase storage p = _purchases[purchaseRef];
        if (p.owner == address(0)) revert UnknownPurchase();
        if (usage == 0 && net == 0) revert InvalidAmount();
        _booked[purchaseRef].refunded += net;
        // Usage counted in an earlier settlement token gives back at the rate it was counted, as a refund does.
        _giveBackNow(_follow(p), p.owner, p.epoch, _counted(purchaseRef, usage));
        Ledger storage ledger_ = ledger;
        uint64 seq = ++ledger_.seq;
        uint128 left = ledger_.net > net ? ledger_.net - net : 0;
        ledger_.net = left;
        emit PurchaseRefunded(purchaseRef, p.card, net, 0, 0, 0, seq, left);
    }

    /// @notice An owner's funding order on this program, which issuer services walk to take money back.
    function fundingOrderOf(address owner) external view returns (uint32 version, CardFunding.Source[] memory order) {
        return CardFunding.orderOf(owner);
    }

    /// @notice Sends what the program holds of `token` (debt an owner repaid to it) to the settlement account.
    function forward(address token) external nonReentrant {
        _forward(token);
    }

    // Reserves.

    /// @notice Lets this program, the caller's acquirer, place dispute reserves on the caller's balance.
    function setDisputeReserves(bool allowed) external {
        disputeReserves[msg.sender] = allowed;
        emit DisputeReservesSet(msg.sender, allowed);
    }

    /// @notice Lets this program reserve the caller's `token` for `purpose` and collect up to `cap` of it over the
    ///         consent's life, counting what it already collected. A zero cap withdraws the consent.
    function allowReserves(address token, uint128 cap, bytes32 purpose) external {
        ReserveConsent storage c = reserveConsent[msg.sender][token];
        (c.cap, c.purpose) = (cap, purpose);
        emit ReservesAllowed(msg.sender, token, cap, purpose);
    }

    /// @notice Holds back `amount` of `owner`'s `token` until `expiresAt`, as a pledge within the allowance the owner
    ///         approved this program for. An owner other than the settlement account needs an active grant and its
    ///         reserveConsent for `purpose`, with room for `amount` left under its cap.
    function reserve(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt, bytes32 purpose)
        external
        nonReentrant
        onlyRole(ROLE_TREASURY)
    {
        if (owner != SETTLEMENT_ACCOUNT) {
            if (!grants[owner].active) revert NoTerms();
            ReserveConsent storage c = reserveConsent[owner][token];
            if (c.purpose != purpose || uint256(amount) + c.collected > c.cap) revert ReserveNotAllowed();
            _useKey(_valueOf(token, amount));
            _consented[id] = true;
        }
        _reserve(owner, token, id, amount, expiresAt);
    }

    /// @notice Reserves a disputed purchase for at most the networks' dispute window: `tokens[0]` on the merchant's
    ///         balance, under a mandate that allows dispute reserves, and `tokens[1]` on the settlement account.
    ///         `covers` records what each part covers in the purchase's units.
    function reserveDispute(
        address merchant,
        address token,
        bytes32 purchaseRef,
        uint128[2] calldata tokens,
        uint128[2] calldata covers,
        uint64 expiresAt
    ) external nonReentrant onlyRole(ROLE_TREASURY) {
        if (!grants[merchant].active) revert NoTerms();
        if (!disputeReserves[merchant]) revert ReserveNotAllowed();
        // forge-lint: disable-next-line(block-timestamp)
        if (expiresAt > block.timestamp + MAX_DISPUTE_RESERVE) revert ReserveTooLong();
        if (tokens[0] != 0) {
            _useKey(_valueOf(token, tokens[0]));
            bytes32 id = reserveId(purchaseRef, merchant);
            delete _consented[id];
            _reserve(merchant, token, id, tokens[0], expiresAt);
        }
        if (tokens[1] != 0) {
            _reserve(SETTLEMENT_ACCOUNT, token, reserveId(purchaseRef, SETTLEMENT_ACCOUNT), tokens[1], expiresAt);
        }
        emit DisputeReserved(purchaseRef, merchant, token, tokens, covers, expiresAt);
    }

    /// @notice Releases a reserve before it expires.
    function releaseReserve(bytes32 id) external nonReentrant onlyRole(ROLE_TREASURY) {
        CORE.releaseLien(id);
    }

    /// @notice Takes `amount` of a reserve and pays it to the settlement account, releasing the rest. A reserve placed
    ///         under an owner's reserveConsent counts against its cap, and the owner may have withdrawn it since.
    function collectReserve(bytes32 id, uint128 amount) external nonReentrant onlyRole(ROLE_TREASURY) {
        (address owner, address token, uint128 held,,) = CORE.lienOf(address(this), id);
        if (_consented[id]) {
            ReserveConsent storage c = reserveConsent[owner][token];
            uint256 collected = uint256(c.collected) + amount;
            if (collected > c.cap) revert ReserveNotAllowed();
            // Bounded by the 128-bit cap just checked.
            // forge-lint: disable-next-line(unsafe-typecast)
            c.collected = uint128(collected);
        }
        if (owner != SETTLEMENT_ACCOUNT) _useKey(_valueOf(token, amount));
        if (amount != 0) CORE.seizeLien(id, amount);
        if (held > amount) CORE.releaseLien(id);
        if (amount != 0) SafeTransferLib.safeTransfer(token, SETTLEMENT_ACCOUNT, amount);
        emit ReserveCollected(id, SETTLEMENT_ACCOUNT, amount);
    }

    /// @notice Draws up to `amount` on line `lineId` of the approved credit source `line` again for `ref`, which pays
    ///         the settlement account, within what the line received as repayment for `ref`. What it drew counts
    ///         against the caller's cap. Returns what it drew.
    function redrawLine(address line, uint64 lineId, uint128 amount, bytes32 ref)
        external
        nonReentrant
        onlyRole(ROLE_TREASURY)
        returns (uint128 drawn)
    {
        if (!approvedSource[line]) revert SourceNotApproved(line);
        drawn = CreditLine(line).redraw(lineId, amount, ref);
        _useKey(_valueOf(CreditLine(line).tokenOf(lineId), drawn));
    }

    // Views.

    /// @notice The lien ID of the reserve a dispute placed on `owner`.
    function reserveId(bytes32 purchaseRef, address owner) public pure returns (bytes32) {
        return keccak256(abi.encode(purchaseRef, owner));
    }

    /// @notice The token purchases settle in now.
    function settlementToken() public view returns (address) {
        address token = _settlementToken;
        return token == address(0) ? SETTLEMENT_TOKEN : token;
    }

    /// @notice The settlement token a purchase was authorized in, which its refunds, corrections and disputes use.
    function purchaseToken(bytes32 purchaseRef) external view returns (address) {
        address token = _purchaseTokens[purchaseRef];
        return token == address(0) ? SETTLEMENT_TOKEN : token;
    }

    /// @notice The rate a converted leg locked, settlement units per token unit scaled by 1e18; zero for none.
    function lockedRate(bytes32 legId) external view returns (uint256) {
        return CardConvert.lockOf(legId);
    }

    /// @notice A card's record, with the status its account's lifecycle gives it: closed once the account closed,
    ///         frozen while the account is an estate.
    function cardOf(bytes32 card) external view returns (Card memory c) {
        c = _cards[card];
        address lc = lifecycle;
        if (lc == address(0) || c.status == Status.None || c.status == Status.Closed) return c;
        AccountLifecycle.Status account = AccountLifecycle(lc).statusOf(c.owner);
        if (account == AccountLifecycle.Status.Closed) c.status = Status.Closed;
        else if (account == AccountLifecycle.Status.Estate) c.status = Status.Frozen;
    }

    /// @notice The owner's funding order at `version`, the one a purchase authorized at that version draws on.
    function orderAt(address owner, uint32 version) external view returns (CardFunding.Source[] memory) {
        return CardFunding.orderAt(owner, version);
    }

    function purchaseOf(bytes32 purchaseRef) external view returns (Purchase memory) {
        return _purchases[purchaseRef];
    }

    /// @notice What the program's open purchases hold and its cardholders' capped debt to it, in settlement units, and
    ///         how many cardholders owe it.
    function outstanding() external view returns (uint256 held, uint256 debt, uint256 debtors) {
        return CardFunding.outstanding();
    }

    /// @notice The program's live exposure in settlement units: open holds, cardholders' capped debt to it and captures
    ///         net of refunds past the settled cursor, against the value of its sponsor's collateral.
    function exposure()
        external
        view
        returns (uint256 holds, uint256 debt, uint256 unsettled, uint256 collateral, uint256 total)
    {
        Ledger memory l = ledger;
        unsettled = l.net > l.settledNet ? l.net - l.settledNet : 0;
        (holds, debt, collateral, total) = CardFunding.exposure(unsettled);
    }

    /// @notice The core hold id of a purchase's cash or savings leg on the owner's account.
    function legId(bytes32 purchaseRef, uint8 leg) external view returns (bytes32) {
        return _legId(purchaseRef, leg);
    }

    // Internals.

    function _reserve(address owner, address token, bytes32 id, uint128 amount, uint64 expiresAt) private {
        CORE.pledgeFrom(owner, token, id, amount, expiresAt);
        _reserves.push(id);
        emit ReservePlaced(id, owner, token, amount, expiresAt);
    }

    /// @dev Reverts while a reserve is still held, dropping the ones that ended.
    function _checkReserves() private {
        uint256 i = _reserves.length;
        while (i != 0) {
            --i;
            // Each reserve the program placed is one core read; the list only holds reserves still to end.
            // forge-lint: disable-next-line(calls-loop)
            (,, uint128 amount,,) = CORE.lienOf(address(this), _reserves[i]);
            if (amount != 0) revert SettlementTokenInUse(IN_USE_HOLDS);
            _reserves[i] = _reserves[_reserves.length - 1];
            _reserves.pop();
        }
    }

    function _end(bytes32 purchaseRef, bool expired) private {
        Purchase storage p = _purchases[purchaseRef];
        if (!p.open) revert PurchaseNotOpen();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (expired && block.timestamp < p.expiresAt) revert PurchaseNotExpired();
        uint256[3] memory released = CardFunding.end(p, purchaseRef, expired);
        p.open = false;
        --_openPurchases;
        uint256 held = p.held;
        p.held = 0;
        _giveBack(_follow(p), p.owner, p.epoch, p.day, p.month, _counted(purchaseRef, held));
        uint64 seq = ++ledger.seq;
        emit PurchaseReleased(purchaseRef, p.card, released[0], released[1], released[2], expired, seq);
    }

    /// @dev Reports activity on the owner's account to the lifecycle and declines unless the account takes new holds.
    function _admit(address owner) private {
        _noteActivity(owner, true);
    }

    /// @dev Reports activity on the owner's account to the lifecycle, declining when admit unless it takes new holds.
    function _noteActivity(address owner, bool admit) private {
        address lc = lifecycle;
        if (lc != address(0)) CardAdjust.noteActivity(lc, owner, admit);
    }

    /// @dev The purchase's card after following its replacements, which the purchase moves to.
    function _follow(Purchase storage p) private returns (Card storage) {
        bytes32 card = p.card;
        bytes32 next = replacedBy[card];
        if (next == bytes32(0)) return _cards[card];
        while (next != bytes32(0)) {
            card = next;
            next = replacedBy[card];
        }
        p.card = card;
        return _cards[card];
    }

    /// @dev Counts `amount` toward the owner's terms and the card in today's windows, checking them when
    ///      `enforce`, and returns today's calendar day and month.
    function _spend(Card storage c, address owner, uint256 total, uint256 amount, bool enforce)
        private
        returns (uint32 day, uint32 month)
    {
        Limits memory l = c.limits;
        return CardLimits.spend(
            grants[owner],
            usageOf[owner],
            c.window,
            [uint256(l.perPurchase), l.daily, l.monthly],
            total,
            amount,
            enforce
        );
    }

    /// @dev Gives `amount` back to the owner's and card's totals, and to the windows of `day` and `month` while they
    ///      are still current.
    function _giveBack(Card storage c, address owner, uint32 epoch, uint32 day, uint32 month, uint256 amount) private {
        if (amount != 0) CardLimits.giveBack(grants[owner], usageOf[owner], c.window, epoch, day, month, amount);
    }

    /// @dev `amount` rounded up to the owner's hold increment.
    function _rounded(address owner, uint256 amount) private view returns (uint256) {
        uint256 increment = holdRounding[owner];
        // Dividing first is the rounding: up to the next whole increment.
        // forge-lint: disable-next-line(divide-before-multiply)
        return increment == 0 ? amount : (amount + increment - 1) / increment * increment;
    }

    /// @dev Whether the issuer's setting call applies now: at once when `immediate` or no owner has granted the
    ///      program, else on the same call SETTINGS_DELAY after the first, which records it and returns false.
    function _settle(bool immediate) private returns (bool) {
        if (immediate || grantedOwners == 0) return true;
        bytes32 id = keccak256(msg.data);
        uint64 eta = pendingSetting[id];
        if (eta == 0) {
            // Timestamps fit 64 bits for billions of years.
            // forge-lint: disable-next-line(unsafe-typecast)
            eta = uint64(block.timestamp) + SETTINGS_DELAY;
            pendingSetting[id] = eta;
            emit SettingProposed(id, msg.data, eta);
            return false;
        }
        // Setting delays are days long; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < eta) revert SettingPending(eta);
        delete pendingSetting[id];
        return true;
    }

    /// @dev Reverts unless the caller is the issuer or a key holding `role`.
    function _onlyRole(uint8 role) private view {
        if (msg.sender != _issuer && _keyCaps[msg.sender].roles & role == 0) revert NotIssuer();
    }

    /// @dev Counts `counted` SETTLEMENT_TOKEN units against the calling key's cap; the issuer has none.
    function _useKey(uint256 counted) private {
        if (msg.sender == _issuer) return;
        KeyCap storage k = _keyCaps[msg.sender];
        uint256 cap = k.cap;
        uint256 used = k.used + counted;
        if (used > cap) revert KeyCapExceeded(cap > k.used ? cap - k.used : 0);
        // Bounded by the 128-bit cap just checked.
        // forge-lint: disable-next-line(unsafe-typecast)
        k.used = uint128(used);
    }

    /// @dev SETTLEMENT_TOKEN units of `amount` of `token`: at the issuer's rate where it set one, else unit for unit.
    function _valueOf(address token, uint256 amount) private view returns (uint256) {
        uint256 rate = rateOf[token];
        return _base(rate == 0 ? amount : amount.mulDivUp(rate, RATE_ONE), type(uint256).max);
    }

    function _scaleOf(address token) private view returns (uint256 scale) {
        scale = _scales[token];
        if (scale == 0) scale = RATE_ONE;
    }

    /// @dev SETTLEMENT_TOKEN units of amount in the current settlement token, rounded up and capped at most.
    function _base(uint256 amount, uint256 most) private view returns (uint256) {
        uint256 scale = _scaleOf(settlementToken());
        if (scale == RATE_ONE) return amount;
        uint256 base = amount.mulDivUp(scale, RATE_ONE);
        return base > most ? most : base;
    }

    function _baseLimits(Limits calldata limits) private view returns (Limits memory) {
        uint256 most = type(uint80).max;
        // Each is capped at type(uint80).max, so the casts keep every value.
        // forge-lint: disable-start(unsafe-typecast)
        return Limits(
            uint80(_base(limits.perPurchase, most)),
            uint80(_base(limits.daily, most)),
            uint80(_base(limits.monthly, most))
        );
        // forge-lint: disable-end(unsafe-typecast)
    }

    /// @dev SETTLEMENT_TOKEN units of amount in the token a purchase was authorized in, rounded up.
    function _counted(bytes32 purchaseRef, uint256 amount) private view returns (uint256) {
        address token = _purchaseTokens[purchaseRef];
        uint256 scale = _scaleOf(token == address(0) ? SETTLEMENT_TOKEN : token);
        return scale == RATE_ONE ? amount : amount.mulDivUp(scale, RATE_ONE);
    }

    /// @dev Gives `amount` back in today's windows (a refund).
    function _giveBackNow(Card storage c, address owner, uint32 epoch, uint256 amount) private {
        (uint32 day, uint32 month) = CardLimits.calendar(grants[owner].terms.utcOffset);
        _giveBack(c, owner, epoch, day, month, amount);
    }

    function _forward(address token) private {
        // The program's own funds for advancing payouts stay.
        uint256 balance = CardConvert.sweepable(token);
        if (balance != 0) SafeTransferLib.safeTransfer(token, SETTLEMENT_ACCOUNT, balance);
    }

    /// @dev The card's owner acts through its own key, or through the keys it listed in the account key registry.
    function _ownedCard(bytes32 card) private view returns (Card storage c) {
        c = _cards[card];
        address owner = c.owner;
        address keys = accountKeys;
        bool signs = keys == address(0) ? owner == msg.sender : AccountKeys(keys).signsFor(owner, msg.sender);
        if (!signs || c.status == Status.None) revert NotCardOwner();
    }

    function _legId(bytes32 purchaseRef, uint8 leg) private view returns (bytes32) {
        return keccak256(abi.encode(address(this), purchaseRef, leg));
    }

    function _rate(address token) private view returns (uint256 rate) {
        if (token == settlementToken()) return RATE_ONE;
        rate = rateOf[token];
        if (rate == 0) revert TokenNotAccepted(token);
    }

    function _toSettlement(uint256 tokens, uint256 rate) private pure returns (uint256) {
        return rate == RATE_ONE ? tokens : tokens.mulDiv(rate, RATE_ONE);
    }

    function _toTokenUp(uint256 units, uint256 rate) private pure returns (uint256) {
        return rate == RATE_ONE ? units : units.mulDivUp(RATE_ONE, rate);
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    // forge-lint: disable-end(reentrancy-no-eth)
}

