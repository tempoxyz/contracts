// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20Like } from "tempo-earn/interfaces/external/IERC20Like.sol";

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
///      Windows are fixed: a day is 86,400 seconds and a month 30 days. The core's holder allowance is the owner's
///      chain-level cap over everything this program holds.
contract CardProgram {
    using FixedPointMathLib for uint256;

    IReservationCore internal constant CORE = IReservationCore(RESERVATION_CORE_ADDRESS);
    uint256 private constant RATE_ONE = 1e18;
    uint256 private constant MONTH = 30 days;

    /// @notice Funding legs, as a card's allowed set and a purchase's placed set.
    uint8 public constant CASH = 1;
    uint8 public constant SAVINGS = 2;
    uint8 public constant CREDIT = 4;

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
        uint32 day;
        uint32 month;
        uint96 daySpent;
        uint96 monthSpent;
    }

    struct Mandate {
        bool revoked;
        /// @dev Zero means no monthly limit for the merchant.
        uint96 monthlyLimit;
        uint32 month;
        uint96 spent;
    }

    /// @notice An owner's funding order: cash token, then savings through a facility, then a credit line.
    struct Funding {
        address cashToken;
        address facility;
        address creditLine;
        uint64 lineId;
    }

    struct Purchase {
        bytes32 card;
        address owner;
        uint64 expiresAt;
        uint32 day;
        address creditLine;
        uint64 amount;
        uint8 legs;
        bool open;
        bool standIn;
        bool captured;
    }

    /// @notice Purchase steps so far, the last one the issuer settled, and net captured settlement units.
    struct Ledger {
        uint64 seq;
        uint64 settledThrough;
        uint128 net;
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
    mapping(address owner => mapping(address merchant => Mandate)) public mandates;
    mapping(address owner => Funding) public fundingOf;
    mapping(bytes32 purchaseRef => Purchase) internal _purchases;
    /// @notice Settlement units per unit of a token other than the settlement token, scaled by 1e18.
    mapping(address token => uint256) public rateOf;
    /// @notice Savings facilities and credit line contracts the issuer accepts as funding sources.
    mapping(address source => bool) public approvedSource;
    Ledger public ledger;

    bool private transient _locked;

    event CardIssued(bytes32 indexed card, address indexed owner, uint40 expiry, Limits limits, uint8 legs);
    event CardReplaced(bytes32 indexed oldCard, bytes32 indexed newCard, uint40 expiry);
    event CardStatusSet(bytes32 indexed card, Status status);
    event LimitsSet(bytes32 indexed card, Limits limits, Limits ceiling);
    event MandateSet(address indexed owner, address indexed merchant, bool revoked, uint96 monthlyLimit);
    event FundingSet(address indexed owner, address cashToken, address facility, address creditLine, uint64 lineId);
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

    /// @notice Moves the settled-through cursor to purchase step `throughSeq`.
    function acknowledgeSettlement(uint64 throughSeq) external onlyIssuer {
        Ledger storage l = ledger;
        uint64 previous = l.settledThrough;
        if (throughSeq <= previous || throughSeq > l.seq) revert InvalidCursor();
        l.settledThrough = throughSeq;
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
        Mandate storage m = mandates[msg.sender][merchant];
        m.revoked = revoked;
        m.monthlyLimit = monthlyLimit;
        emit MandateSet(msg.sender, merchant, revoked, monthlyLimit);
    }

    /// @notice Sets the caller's funding order. Zero skips a leg.
    function setFunding(address cashToken, address facility, address creditLine, uint64 lineId) external {
        fundingOf[msg.sender] =
            Funding({ cashToken: cashToken, facility: facility, creditLine: creditLine, lineId: lineId });
        emit FundingSet(msg.sender, cashToken, facility, creditLine, lineId);
    }

    // Purchases.

    /// @notice Authorizes a purchase of `amount` settlement units on `card` at `merchant`: checks the card, its
    ///         limits and the merchant mandate on the whole amount, then places the owner's legs in funding order in
    ///         this one call. A stand-in records an offline approval as one cash stand-in hold, past the card's
    ///         freeze, limits and mandates, which the network already decided.
    function authorize(
        bytes32 card,
        bytes32 purchaseRef,
        uint128 amount,
        address merchant,
        uint64 expiresAt,
        bool standIn
    ) external nonReentrant onlyIssuer {
        if (amount == 0 || amount > type(uint64).max) revert InvalidAmount();
        Purchase storage p = _purchases[purchaseRef];
        if (p.owner != address(0)) revert PurchaseExists();
        Card storage c = _cards[card];
        address owner = c.owner;
        if (c.status == Status.None) revert InvalidCard();
        if (standIn) {
            if (c.status == Status.Closed) revert CardNotActive();
        } else {
            if (c.status != Status.Active) revert CardNotActive();
            // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
            // forge-lint: disable-next-line(block-timestamp)
            if (c.expiry <= block.timestamp) revert CardExpired();
            if (amount > c.limits.perPurchase) revert LimitExceeded(0);
            _useMandate(owner, merchant, amount);
        }
        _useWindows(c, amount, !standIn);

        Funding memory f = fundingOf[owner];
        uint256[3] memory legAmounts;
        uint8 legs;
        if (standIn) {
            if (c.legs & CASH == 0 || f.cashToken == address(0)) revert InsufficientFunds(amount);
            uint256 tokens = _toTokenUp(amount, _rate(f.cashToken));
            _holdFrom(owner, f.cashToken, _legId(purchaseRef, CASH), tokens, expiresAt, address(this), true);
            legAmounts[0] = tokens;
            legs = CASH;
        } else {
            (legs, legAmounts) = _placeLegs(c.legs, owner, f, purchaseRef, amount, expiresAt);
            if (legs & CREDIT != 0) p.creditLine = f.creditLine;
        }

        p.card = card;
        p.owner = owner;
        p.expiresAt = expiresAt;
        p.day = c.day;
        // forge-lint: disable-next-line(unsafe-typecast)
        p.amount = uint64(amount);
        p.legs = legs;
        p.open = true;
        p.standIn = standIn;
        uint64 seq = ++ledger.seq;
        emit PurchaseAuthorized(
            purchaseRef, card, merchant, amount, legAmounts[0], legAmounts[1], legAmounts[2], standIn, expiresAt, seq
        );
    }

    /// @notice Captures `amount` settlement units of a purchase across its legs in funding order (cash, savings,
    ///         credit), and pays the settlement account in the same call. An amount above what the legs hold (a tip)
    ///         is captured on the cash leg within the owner's tolerance on the core. `isFinal` releases the rest.
    function capture(bytes32 purchaseRef, uint128 amount, bool isFinal) external nonReentrant onlyIssuer {
        Purchase storage p = _purchases[purchaseRef];
        if (!p.open) revert PurchaseNotOpen();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= p.expiresAt) revert PurchaseExpired();
        if (amount == 0 && !isFinal) revert InvalidAmount();
        uint8 legs = p.legs;
        Leg[3] memory l = _readLegs(p, purchaseRef, false);

        // Waterfall: each leg pays what it can of the rest, in funding order.
        uint256 rest = amount;
        uint256[3] memory take;
        for (uint256 i; i < 3; ++i) {
            take[i] = rest < l[i].value ? rest : l[i].value;
            rest -= take[i];
        }
        if (rest != 0 && legs & CASH == 0) revert CaptureExceedsHolds(rest);

        uint256[3] memory tokens;
        tokens[0] = _legTokens(l[0], take[0]) + (rest == 0 ? 0 : _toTokenUp(rest, l[0].rate));
        if (take[1] != 0) tokens[1] = _shareTokens(l[1], take[1]);
        tokens[2] = _legTokens(l[2], take[2]);

        if (legs & CASH != 0) _captureLeg(l[0], tokens[0], isFinal);
        if (legs & SAVINGS != 0) {
            if (tokens[1] != 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                SavingsFacility(_facility(l[1])).capture(l[1].holdOwner, l[1].id, uint128(tokens[1]), isFinal);
            } else if (isFinal && !l[1].settled) {
                CORE.release(l[1].holdOwner, l[1].id);
            }
        }
        if (legs & CREDIT != 0) {
            _captureLeg(l[2], tokens[2], isFinal);
            CreditLine(p.creditLine).sync(l[2].id);
        }
        if (legs & CASH != 0) _forward(l[0].token);
        if (legs & CREDIT != 0) _forward(l[2].token);

        if (amount != 0) p.captured = true;
        if (isFinal) p.open = false;
        Ledger storage ledger_ = ledger;
        uint64 seq = ++ledger_.seq;
        uint128 net = ledger_.net + amount;
        ledger_.net = net;
        emit PurchaseCaptured(purchaseRef, p.card, amount, tokens[0], tokens[1], tokens[2], isFinal, seq, net);
    }

    /// @notice Releases every open leg of a purchase. A purchase with nothing captured gives its amount back to the
    ///         card's windows when they have not rolled over.
    function release(bytes32 purchaseRef) external nonReentrant onlyIssuer {
        _end(purchaseRef, false);
    }

    /// @notice Releases an expired purchase's legs. Anyone may call it once the purchase expired.
    function expire(bytes32 purchaseRef) external nonReentrant {
        _end(purchaseRef, true);
    }

    /// @notice Refunds `amount` settlement units of what a purchase captured, in reverse funding order (credit,
    ///         savings, cash). The issuer funds it: the program pulls each leg's token from the issuer (the savings
    ///         leg's base asset, which the facility deposits for shares) and refunds the leg as its payee.
    function refund(bytes32 purchaseRef, uint128 amount) external nonReentrant onlyIssuer {
        Purchase storage p = _purchases[purchaseRef];
        if (p.owner == address(0)) revert UnknownPurchase();
        if (amount == 0) revert InvalidAmount();
        Leg[3] memory l = _readLegs(p, purchaseRef, true);

        uint256 rest = amount;
        uint256[3] memory take;
        for (uint256 i = 3; i > 0; --i) {
            take[i - 1] = rest < l[i - 1].value ? rest : l[i - 1].value;
            rest -= take[i - 1];
        }
        if (rest != 0) revert RefundExceedsCapture(rest);

        uint256[3] memory tokens;
        if (take[2] != 0) {
            tokens[2] = _refundTokens(l[2], take[2]);
            SafeTransferLib.safeTransferFrom(l[2].token, msg.sender, address(this), tokens[2]);
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.refund(l[2].holdOwner, l[2].id, uint128(tokens[2]));
            CreditLine(p.creditLine).sync(l[2].id);
        }
        if (take[1] != 0) {
            SavingsFacility facility = SavingsFacility(_facility(l[1]));
            uint256 assets = _toTokenUp(take[1], l[1].rate);
            SafeTransferLib.safeTransferFrom(facility.ASSET(), msg.sender, address(this), assets);
            SafeTransferLib.safeApprove(facility.ASSET(), address(facility), assets);
            tokens[1] = facility.refund(l[1].holdOwner, l[1].id, assets);
        }
        if (take[0] != 0) {
            tokens[0] = _refundTokens(l[0], take[0]);
            SafeTransferLib.safeTransferFrom(l[0].token, msg.sender, address(this), tokens[0]);
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.refund(l[0].holdOwner, l[0].id, uint128(tokens[0]));
        }

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

    /// @notice The core hold id of a purchase's cash or savings leg on the owner's account.
    function legId(bytes32 purchaseRef, uint8 leg) external view returns (bytes32) {
        return _legId(purchaseRef, leg);
    }

    // Internals.

    function _placeLegs(
        uint8 allowed,
        address owner,
        Funding memory f,
        bytes32 purchaseRef,
        uint256 amount,
        uint64 expiresAt
    ) private returns (uint8 legs, uint256[3] memory legAmounts) {
        uint256 rest = amount;
        if (allowed & CASH != 0 && f.cashToken != address(0)) {
            uint256 rate = _rate(f.cashToken);
            uint256 take = _min(rest, _toSettlement(CORE.available(owner, f.cashToken), rate));
            if (take != 0) {
                legAmounts[0] = _toTokenUp(take, rate);
                _holdFrom(owner, f.cashToken, _legId(purchaseRef, CASH), legAmounts[0], expiresAt, address(this), false);
                legs |= CASH;
                rest -= take;
            }
        }
        if (rest != 0 && allowed & SAVINGS != 0 && f.facility != address(0)) {
            if (!approvedSource[f.facility]) revert SourceNotApproved(f.facility);
            SavingsFacility facility = SavingsFacility(f.facility);
            address share = facility.SHARE();
            uint256 rate = _rate(facility.ASSET());
            uint256 sharesAvailable = CORE.available(owner, share);
            uint256 take = _min(rest, _toSettlement(facility.VAULT().previewRedeem(sharesAvailable), rate));
            if (take != 0) {
                legAmounts[1] = _min(facility.VAULT().previewWithdraw(_toTokenUp(take, rate)), sharesAvailable);
                _holdFrom(owner, share, _legId(purchaseRef, SAVINGS), legAmounts[1], expiresAt, f.facility, false);
                legs |= SAVINGS;
                rest -= take;
            }
        }
        if (rest != 0 && allowed & CREDIT != 0 && f.creditLine != address(0)) {
            if (!approvedSource[f.creditLine]) revert SourceNotApproved(f.creditLine);
            CreditLine line = CreditLine(f.creditLine);
            legAmounts[2] = _toTokenUp(rest, _rate(line.tokenOf(f.lineId)));
            // forge-lint: disable-next-line(unsafe-typecast)
            line.draw(f.lineId, owner, purchaseRef, uint128(legAmounts[2]), expiresAt);
            legs |= CREDIT;
            rest = 0;
        }
        if (rest != 0) revert InsufficientFunds(rest);
    }

    /// @dev Reads each placed leg's hold. `forRefund` values what is refundable rather than what is still held.
    function _readLegs(Purchase storage p, bytes32 purchaseRef, bool forRefund) private view returns (Leg[3] memory l) {
        uint8 legs = p.legs;
        address owner = p.owner;
        if (legs & CASH != 0) l[0] = _readLeg(owner, _legId(purchaseRef, CASH), false, forRefund);
        if (legs & SAVINGS != 0) l[1] = _readLeg(owner, _legId(purchaseRef, SAVINGS), true, forRefund);
        if (legs & CREDIT != 0) {
            CreditLine line = CreditLine(p.creditLine);
            bytes32 id = line.holdIdOf(address(this), purchaseRef);
            (address lender,) = line.drawOf(id);
            l[2] = _readLeg(lender, id, false, forRefund);
        }
    }

    function _readLeg(address holdOwner, bytes32 id, bool savings, bool forRefund)
        private
        view
        returns (Leg memory leg)
    {
        IReservationCore.HoldRecord memory h = CORE.getHold(holdOwner, id);
        leg.holdOwner = holdOwner;
        leg.id = id;
        leg.token = h.token;
        leg.held = h.settled ? 0 : h.held;
        leg.refundable = h.captured - h.refunded;
        leg.settled = h.settled;
        uint256 units = forRefund ? leg.refundable : leg.held;
        if (savings) {
            SavingsFacility facility = SavingsFacility(h.payee);
            leg.rate = _rate(facility.ASSET());
            leg.value = _toSettlement(facility.VAULT().previewRedeem(units), leg.rate);
        } else {
            leg.rate = _rate(h.token);
            leg.value = _toSettlement(units, leg.rate);
        }
    }

    function _captureLeg(Leg memory leg, uint256 tokens, bool isFinal) private {
        if (tokens != 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            CORE.capture(leg.holdOwner, leg.id, uint128(tokens), isFinal);
        } else if (isFinal && !leg.settled) {
            CORE.release(leg.holdOwner, leg.id);
        }
    }

    /// @dev Token units for `take` settlement units of a cash or credit leg: all it holds when it takes its value.
    function _legTokens(Leg memory leg, uint256 take) private pure returns (uint256) {
        if (take == 0) return 0;
        if (take == leg.value) return leg.held;
        return _min(_toTokenUp(take, leg.rate), leg.held);
    }

    function _shareTokens(Leg memory leg, uint256 take) private view returns (uint256) {
        if (take == leg.value) return leg.held;
        SavingsFacility facility = SavingsFacility(_facility(leg));
        return _min(facility.VAULT().previewWithdraw(_toTokenUp(take, leg.rate)), leg.held);
    }

    function _refundTokens(Leg memory leg, uint256 take) private pure returns (uint256) {
        if (take == leg.value) return leg.refundable;
        return _min(_toTokenUp(take, leg.rate), leg.refundable);
    }

    function _facility(Leg memory leg) private view returns (address) {
        return CORE.getHold(leg.holdOwner, leg.id).payee;
    }

    function _end(bytes32 purchaseRef, bool expired) private {
        Purchase storage p = _purchases[purchaseRef];
        if (!p.open) revert PurchaseNotOpen();
        // Expiries and due dates are timestamps by design; a few seconds of validator skew does not change them.
        // forge-lint: disable-next-line(block-timestamp)
        if (expired && block.timestamp < p.expiresAt) revert PurchaseNotExpired();
        Leg[3] memory l = _readLegs(p, purchaseRef, false);
        _releaseLeg(l[0], expired);
        _releaseLeg(l[1], expired);
        _releaseLeg(l[2], expired);
        if (p.legs & CREDIT != 0) CreditLine(p.creditLine).sync(l[2].id);
        p.open = false;
        if (!p.captured) _restoreWindows(_cards[p.card], p.day, p.amount);
        uint64 seq = ++ledger.seq;
        emit PurchaseReleased(purchaseRef, p.card, l[0].held, l[1].held, l[2].held, expired, seq);
    }

    function _releaseLeg(Leg memory leg, bool expired) private {
        if (leg.holdOwner == address(0) || leg.settled) return;
        if (expired) CORE.releaseExpired(leg.holdOwner, leg.id);
        else CORE.release(leg.holdOwner, leg.id);
    }

    function _useWindows(Card storage c, uint256 amount, bool enforce) private {
        // Day and month numbers fit in 32 bits for millions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 day = uint32(block.timestamp / 1 days);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 month = uint32(block.timestamp / MONTH);
        uint256 daySpent = c.day == day ? c.daySpent : 0;
        uint256 monthSpent = c.month == month ? c.monthSpent : 0;
        daySpent += amount;
        monthSpent += amount;
        if (enforce) {
            if (daySpent > c.limits.daily) revert LimitExceeded(1);
            if (monthSpent > c.limits.monthly) revert LimitExceeded(2);
        }
        c.day = day;
        c.month = month;
        // Purchases are at most 64 bits, so 96-bit windows hold billions of them.
        // forge-lint: disable-next-line(unsafe-typecast)
        (c.daySpent, c.monthSpent) = (uint96(daySpent), uint96(monthSpent));
    }

    function _restoreWindows(Card storage c, uint32 day, uint64 amount) private {
        if (c.day == day) c.daySpent = c.daySpent > amount ? c.daySpent - amount : 0;
        if (c.month == day / 30) c.monthSpent = c.monthSpent > amount ? c.monthSpent - amount : 0;
    }

    function _useMandate(address owner, address merchant, uint256 amount) private {
        Mandate storage m = mandates[owner][merchant];
        if (m.revoked) revert MerchantRevoked();
        uint96 limit = m.monthlyLimit;
        if (limit == 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 month = uint32(block.timestamp / MONTH);
        uint256 spent = (m.month == month ? m.spent : 0) + amount;
        if (spent > limit) revert MerchantLimitExceeded();
        m.month = month;
        // Bounded by the 96-bit limit just checked.
        // forge-lint: disable-next-line(unsafe-typecast)
        m.spent = uint96(spent);
    }

    function _holdFrom(
        address owner,
        address token,
        bytes32 id,
        uint256 amount,
        uint64 expiresAt,
        address payee,
        bool standIn
    ) private {
        CORE.holdFrom(
            owner,
            IReservationCore.HoldRequest({
                token: token,
                id: id,
                // Leg amounts derive from 64-bit purchases at recorded rates.
                // forge-lint: disable-next-line(unsafe-typecast)
                amount: uint128(amount),
                expiresAt: expiresAt,
                payee: payee,
                standIn: standIn
            })
        );
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
