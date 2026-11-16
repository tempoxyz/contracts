// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

import { CardAdjust } from "./CardAdjust.sol";
import { CardFunding } from "./CardFunding.sol";
import { CardLimits } from "./CardLimits.sol";
import { CreditLine } from "./CreditLine.sol";
import { SavingsFacility } from "./SavingsFacility.sol";
import { IReservationCore, RESERVATION_CORE_ADDRESS } from "./interfaces/IReservationCore.sol";

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

    address public immutable ISSUER;
    address public immutable SETTLEMENT_TOKEN;
    address public immutable SETTLEMENT_ACCOUNT;

    mapping(bytes32 card => Card) internal _cards;
    mapping(address owner => mapping(address merchant => CardLimits.Mandate)) public mandates;
    mapping(address owner => CardLimits.Grant) public grants;
    mapping(address owner => CardLimits.Usage) public usageOf;
    /// @notice Keys the issuer lets act on purchases besides itself.
    mapping(address key => bool) public operators;
    mapping(address owner => address) public fundingOf;
    mapping(bytes32 purchaseRef => Purchase) internal _purchases;
    /// @notice Settlement units per unit of a token other than the settlement token, scaled by 1e18.
    mapping(address token => uint256) public rateOf;
    /// @notice Savings facilities and credit line contracts the issuer accepts as funding sources.
    mapping(address source => bool) public approvedSource;
    Ledger public ledger;

    bool private transient _locked;

    event CardIssued(bytes32 indexed card, address indexed owner, uint40 expiry, Limits limits, uint8 legs);
    event CardExpirySet(bytes32 indexed card, uint40 expiry);
    event CardReplaced(bytes32 indexed oldCard, bytes32 indexed newCard, uint40 expiry);
    event CardStatusSet(bytes32 indexed card, Status status);
    event LimitsSet(bytes32 indexed card, Limits limits, Limits ceiling);
    event MandateSet(address indexed owner, address indexed merchant, bool revoked, uint96 monthlyLimit);
    event RateSet(address indexed token, uint256 rate);
    event SourceSet(address indexed source, bool approved);
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
    event SettlementAcknowledged(uint64 throughSeq, uint64 previous);
    event Granted(address indexed owner, CardLimits.Terms terms, uint32 epoch);
    event Revoked(address indexed owner);
    event OperatorSet(address indexed key, bool allowed);
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

    error CaptureExceedsHolds(uint256 excess);
    error CardExists();
    error CardExpired();
    error CardNotActive();
    error InsufficientFunds(uint256 shortfall);
    error InvalidAmount();
    error InvalidCard();
    error InvalidCursor();
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
    error RefundExceedsCapture(uint256 excess);
    error SourceNotApproved(address source);
    error TokenNotAccepted(address token);
    error UnknownPurchase();
    error ZeroAddress();

    modifier onlyIssuer() {
        if (msg.sender != ISSUER) revert NotIssuer();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != ISSUER && !operators[msg.sender]) revert NotIssuer();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address issuer, address settlementToken, address settlementAccount) {
        if (issuer == address(0) || settlementToken == address(0) || settlementAccount == address(0)) {
            revert ZeroAddress();
        }
        ISSUER = issuer;
        SETTLEMENT_TOKEN = settlementToken;
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
        Card storage c = _cards[card];
        if (c.status != Status.None) revert CardExists();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (owner == address(0) || expiry <= block.timestamp || legs == 0 || legs > (CASH | SAVINGS | CREDIT)) {
            revert InvalidCard();
        }
        c.owner = owner;
        c.expiry = expiry;
        c.status = Status.Active;
        c.legs = legs;
        c.limits = limits;
        c.ceiling = limits;
        emit CardIssued(card, owner, expiry, limits, legs);
    }

    /// @notice Replaces `oldCard` with `newCard` (a lost card or a new expiry): same owner, limits, legs and
    ///         windows; the old card closes.
    function replaceCard(bytes32 oldCard, bytes32 newCard, uint40 expiry) external onlyIssuer {
        Card storage old = _cards[oldCard];
        if (old.status != Status.Active && old.status != Status.Frozen) revert CardNotActive();
        Card storage c = _cards[newCard];
        if (c.status != Status.None) revert CardExists();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (expiry <= block.timestamp) revert InvalidCard();
        _cards[newCard] = old;
        c.expiry = expiry;
        old.status = Status.Closed;
        emit CardReplaced(oldCard, newCard, expiry);
        emit CardStatusSet(oldCard, Status.Closed);
    }

    /// @notice Sets `card`'s limits, each at most what its owner allows.
    function raiseLimits(bytes32 card, Limits calldata limits) external onlyIssuer {
        Card storage c = _cards[card];
        if (c.status == Status.None || c.status == Status.Closed) revert CardNotActive();
        Limits memory ceiling = c.ceiling;
        if (
            limits.perPurchase > ceiling.perPurchase || limits.daily > ceiling.daily || limits.monthly > ceiling.monthly
        ) revert LimitAboveCeiling();
        c.limits = limits;
        emit LimitsSet(card, limits, ceiling);
    }

    /// @notice Lets `key` act on purchases (authorize, adjust, capture, release, charge, refund), or stops it.
    function setOperator(address key, bool allowed) external onlyIssuer {
        operators[key] = allowed;
        emit OperatorSet(key, allowed);
    }

    /// @notice Caps what `card` commits over its life (open holds plus captures less refunds). Zero removes the cap.
    function setCardCap(bytes32 card, uint64 cap) external onlyIssuer {
        Card storage c = _cards[card];
        if (c.status == Status.None) revert InvalidCard();
        c.window.cap = cap;
        emit CardCapSet(card, cap);
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

    /// @notice Records the rate for `token`: settlement units per token unit, scaled by 1e18. Zero stops it.
    function setRate(address token, uint256 rate) external onlyIssuer {
        if (token == SETTLEMENT_TOKEN) revert TokenNotAccepted(token);
        rateOf[token] = rate;
        emit RateSet(token, rate);
    }

    /// @notice Accepts or stops a savings facility or credit line contract as a funding source.
    function setSource(address source, bool approved) external onlyIssuer {
        approvedSource[source] = approved;
        emit SourceSet(source, approved);
    }

    /// @notice Limits the kinds of source (cash 1, savings 2, credit 4) purchases may draw on; zero allows every kind.
    function setAssets(uint8 kinds) external onlyIssuer {
        CardFunding.setAssets(kinds);
    }

    /// @notice Sets the contract that values the sponsor's collateral; purchases then stay within it. Zero removes it.
    function setCollateral(address collateral) external onlyIssuer {
        CardFunding.setCollateral(collateral);
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
    function lowerLimits(bytes32 card, Limits calldata limits) external {
        Card storage c = _ownedCard(card);
        Limits memory current = c.limits;
        if (
            limits.perPurchase > current.perPurchase || limits.daily > current.daily || limits.monthly > current.monthly
        ) revert LimitAboveCeiling();
        c.limits = limits;
        Limits memory ceiling = c.ceiling;
        ceiling.perPurchase = _min80(ceiling.perPurchase, limits.perPurchase);
        ceiling.daily = _min80(ceiling.daily, limits.daily);
        ceiling.monthly = _min80(ceiling.monthly, limits.monthly);
        c.ceiling = ceiling;
        emit LimitsSet(card, limits, ceiling);
    }

    /// @notice Sets how far the issuer may raise `card`'s limits; limits above it come down to it.
    function allowLimits(bytes32 card, Limits calldata ceiling) external {
        Card storage c = _ownedCard(card);
        c.ceiling = ceiling;
        Limits memory limits = c.limits;
        limits.perPurchase = _min80(limits.perPurchase, ceiling.perPurchase);
        limits.daily = _min80(limits.daily, ceiling.daily);
        limits.monthly = _min80(limits.monthly, ceiling.monthly);
        c.limits = limits;
        emit LimitsSet(card, limits, ceiling);
    }

    /// @notice Revokes or restores `merchant` for all the caller's cards, with an optional monthly limit.
    function setMandate(address merchant, bool revoked, uint96 monthlyLimit) external {
        CardLimits.Mandate storage m = mandates[msg.sender][merchant];
        m.revoked = revoked;
        m.monthlyLimit = monthlyLimit;
        emit MandateSet(msg.sender, merchant, revoked, monthlyLimit);
    }

    /// @notice Sets the caller's funding order. Zero skips a leg.
    function setFunding(address cashToken, CardFunding.Source[] calldata order) external {
        fundingOf[msg.sender] = cashToken;
        CardFunding.setOrder(msg.sender, cashToken, order);
    }

    /// @notice Grants this program the caller's terms for all their cards, and starts their usage afresh.
    function grant(CardLimits.Terms calldata terms) external {
        CardLimits.Grant storage g = grants[msg.sender];
        g.terms = terms;
        g.active = true;
        uint32 epoch = ++g.epoch;
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
    ) external nonReentrant onlyOperator returns (uint256 approved) {
        if (amount == 0 || amount > type(uint64).max) revert InvalidAmount();
        Purchase storage p = _purchases[purchaseRef];
        if (p.owner != address(0)) revert PurchaseExists();
        Card storage c = _cards[card];
        address owner = c.owner;
        bool standIn = flags & STAND_IN != 0;
        if (c.status == Status.None) revert InvalidCard();
        CardLimits.Grant storage g = grants[owner];
        if (standIn) {
            if (c.status == Status.Closed) revert CardNotActive();
        } else {
            if (c.status != Status.Active) revert CardNotActive();
            // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
            // forge-lint: disable-next-line(block-timestamp)
            if (c.expiry <= block.timestamp) revert CardExpired();
            if (!g.active) revert NoTerms();
        }

        uint256[3] memory legAmounts;
        (approved, legAmounts) = CardFunding.place(p, purchaseRef, owner, amount, c.legs, expiresAt, flags);
        if (!standIn) CardLimits.useMandate(mandates[owner][merchant], g.terms.utcOffset, approved);
        (p.day, p.month) = _spend(c, owner, approved, approved, !standIn);

        p.card = card;
        p.owner = owner;
        p.expiresAt = expiresAt;
        p.epoch = g.epoch;
        // forge-lint: disable-next-line(unsafe-typecast)
        p.amount = uint64(approved);
        // forge-lint: disable-next-line(unsafe-typecast)
        p.held = uint64(approved);
        p.open = true;
        p.standIn = standIn;
        uint64 seq = ++ledger.seq;
        emit PurchaseAuthorized(
            purchaseRef, card, merchant, approved, legAmounts[0], legAmounts[1], legAmounts[2], standIn, expiresAt, seq
        );
    }

    /// @notice Moves an open purchase to `amount` settlement units (an incremental authorization or a partial
    ///         reversal). An increase checks the card, grant and limits on the new total and reserves the difference
    ///         on the purchase's cash leg; a decrease gives back what the cash leg still holds of it.
    function adjust(bytes32 purchaseRef, uint128 amount) external nonReentrant onlyOperator {
        Purchase storage p = _purchases[purchaseRef];
        address owner = p.owner;
        address token = fundingOf[owner];
        uint256 cash = CardAdjust.adjust(
            CORE,
            p,
            _cards[p.card],
            grants[owner],
            usageOf[owner],
            token,
            _rate(token),
            _legId(purchaseRef, CASH),
            amount
        );
        uint64 seq = ++ledger.seq;
        emit PurchaseAdjusted(purchaseRef, p.card, amount, cash, seq);
    }

    /// @notice Captures `amount` settlement units of a purchase across its legs in funding order (cash, savings,
    ///         credit), and pays the settlement account in the same call. An amount above what the legs hold (a tip)
    ///         is captured on the cash leg within the owner's tolerance on the core. `isFinal` releases the rest.
    function capture(bytes32 purchaseRef, uint128 amount, bool isFinal) external nonReentrant onlyOperator {
        Purchase storage p = _purchases[purchaseRef];
        if (!p.open) revert PurchaseNotOpen();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.expiresAt) revert PurchaseExpired();
        if (amount == 0 && !isFinal) revert InvalidAmount();
        Card storage c = _cards[p.card];
        (uint256[3] memory tokens,, uint256 absorbed) =
            CardFunding.capture(p, purchaseRef, amount, isFinal, c.legs, fundingOf[p.owner]);

        // The held part of the capture already counts; what it takes past the holds counts now, and a final capture
        // gives back what it leaves held.
        uint256 counted = p.held;
        uint256 fromHeld = amount < counted ? amount : counted;
        uint256 freed = isFinal ? counted : fromHeld;
        // forge-lint: disable-next-line(unsafe-typecast)
        p.held = uint64(counted - freed);
        if (amount > fromHeld) _spend(c, p.owner, 0, amount - fromHeld, false);
        if (freed > fromHeld) _giveBack(c, p.owner, p.epoch, p.day, p.month, freed - fromHeld);

        if (amount != 0) p.captured = true;
        if (isFinal) p.open = false;
        Ledger storage ledger_ = ledger;
        uint64 seq = ++ledger_.seq;
        uint128 net = ledger_.net + amount;
        ledger_.net = net;
        emit PurchaseCaptured(purchaseRef, p.card, amount, tokens[0], tokens[1], tokens[2], absorbed, isFinal, seq, net);
    }

    /// @notice Charges `amount` settlement units for a purchase presented without a live hold (a late presentment
    ///         or a force post), as one core charge on the owner's cash token: available balance first, then debt
    ///         within the cap the owner set for this program. The issuer absorbs what neither covers; the event
    ///         reports it. An expired open purchase is released first.
    function charge(bytes32 card, bytes32 purchaseRef, uint128 amount, address merchant)
        external
        nonReentrant
        onlyOperator
    {
        if (amount == 0 || amount > type(uint64).max) revert InvalidAmount();
        Purchase storage p = _purchases[purchaseRef];
        if (p.owner == address(0)) {
            Card storage c = _cards[card];
            if (c.status == Status.None) revert InvalidCard();
            p.card = card;
            p.owner = c.owner;
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
        address token = fundingOf[owner];
        (uint256 tokens, uint256 absorbed) = CardAdjust.charge(
            CORE,
            p,
            _cards[p.card],
            grants[owner],
            usageOf[owner],
            token,
            _rate(token),
            _legId(purchaseRef, CHARGED),
            amount
        );
        _forward(token);

        Ledger storage ledger_ = ledger;
        uint64 seq = ++ledger_.seq;
        uint128 net = ledger_.net + amount;
        ledger_.net = net;
        emit PurchaseCharged(purchaseRef, p.card, merchant, amount, tokens, absorbed, seq, net);
    }

    /// @notice Releases every open leg of a purchase and gives back what it still held.
    function release(bytes32 purchaseRef) external nonReentrant onlyOperator {
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
    function refund(bytes32 purchaseRef, uint128 amount) external nonReentrant onlyOperator {
        Purchase storage p = _purchases[purchaseRef];
        if (p.owner == address(0)) revert UnknownPurchase();
        if (amount == 0) revert InvalidAmount();
        uint256[3] memory tokens = CardFunding.refund(p, purchaseRef, amount, fundingOf[p.owner]);
        _giveBackNow(_cards[p.card], p.owner, p.epoch, amount);

        Ledger storage ledger_ = ledger;
        uint64 seq = ++ledger_.seq;
        uint128 net = ledger_.net > amount ? ledger_.net - amount : 0;
        ledger_.net = net;
        emit PurchaseRefunded(purchaseRef, p.card, amount, tokens[0], tokens[1], tokens[2], seq, net);
    }

    /// @notice Sends what the program holds of `token` (debt an owner repaid to it) to the settlement account.
    function forward(address token) external nonReentrant {
        _forward(token);
    }

    // Views.

    function cardOf(bytes32 card) external view returns (Card memory) {
        return _cards[card];
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








    function _end(bytes32 purchaseRef, bool expired) private {
        Purchase storage p = _purchases[purchaseRef];
        if (!p.open) revert PurchaseNotOpen();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (expired && block.timestamp < p.expiresAt) revert PurchaseNotExpired();
        uint256[3] memory released = CardFunding.end(p, purchaseRef, expired);
        p.open = false;
        uint256 held = p.held;
        p.held = 0;
        _giveBack(_cards[p.card], p.owner, p.epoch, p.day, p.month, held);
        uint64 seq = ++ledger.seq;
        emit PurchaseReleased(purchaseRef, p.card, released[0], released[1], released[2], expired, seq);
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

    /// @dev Gives `amount` back in today's windows (a refund).
    function _giveBackNow(Card storage c, address owner, uint32 epoch, uint256 amount) private {
        (uint32 day, uint32 month) = CardLimits.calendar(grants[owner].terms.utcOffset);
        _giveBack(c, owner, epoch, day, month, amount);
    }


    function _forward(address token) private {
        uint256 balance = IERC20Like(token).balanceOf(address(this));
        if (balance != 0) SafeTransferLib.safeTransfer(token, SETTLEMENT_ACCOUNT, balance);
    }

    function _ownedCard(bytes32 card) private view returns (Card storage c) {
        c = _cards[card];
        if (c.owner != msg.sender || c.status == Status.None) revert NotCardOwner();
    }

    function _legId(bytes32 purchaseRef, uint8 leg) private view returns (bytes32) {
        return keccak256(abi.encode(address(this), purchaseRef, leg));
    }

    function _rate(address token) private view returns (uint256 rate) {
        if (token == SETTLEMENT_TOKEN) return RATE_ONE;
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

    function _min80(uint80 a, uint80 b) private pure returns (uint80) {
        return a < b ? a : b;
    }
    // forge-lint: disable-end(reentrancy-no-eth)
}

